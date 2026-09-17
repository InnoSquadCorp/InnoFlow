#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "time"

STAGES = %w[local-preflight pre-publication post-publication].freeze

def fail!(message, status = 1)
  warn message
  exit status
end

def sha256_file(path)
  Digest::SHA256.file(path).hexdigest
end

def artifact_manifest(path)
  if File.file?(path) && !File.symlink?(path)
    [{ "path" => File.basename(path), "sha256" => sha256_file(path), "size" => File.size(path) }]
  elsif File.directory?(path) && !File.symlink?(path)
    root = File.realpath(path)
    entries = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.filter_map do |entry|
      next if [".", ".."].include?(File.basename(entry)) || File.directory?(entry)
      fail!("Evidence artifact contains a symlink: #{entry}") if File.symlink?(entry)
      relative = Pathname.new(entry).relative_path_from(Pathname.new(root)).to_s
      { "path" => relative, "sha256" => sha256_file(entry), "size" => File.size(entry) }
    end
    fail!("Evidence artifact directory is empty: #{path}") if entries.empty?
    entries
  else
    fail!("Evidence artifact is missing or a symlink: #{path}")
  end
end

def artifact_digest(entries)
  Digest::SHA256.hexdigest(entries.map { |entry| JSON.generate(entry) }.join("\n") + "\n")
end

def cartesian(axes)
  axes.keys.sort.reduce([{}]) do |rows, key|
    rows.flat_map { |row| axes.fetch(key).map { |value| row.merge(key => value) } }
  end
end

def resolved_policy(path)
  raw = JSON.parse(File.read(path))
  fail!("Unsupported release evidence policy schema") unless raw["schema"] == "inno-flow-release-evidence-policy-v3"
  profiles = raw.fetch("profiles")
  checks = raw.fetch("checks").map do |check|
    profiles.fetch(check.fetch("profile")).merge(check)
  end
  raw.fetch("matrices", []).each do |matrix|
    cartesian(matrix.fetch("axes")).each do |values|
      check = matrix.reject do |key, _|
        %w[idTemplate axes testIdentifierAxes testIdentifierMap].include?(key)
      end
      identifier = matrix.fetch("idTemplate").dup
      values.each { |key, value| identifier = identifier.gsub("{#{key}}", value) }
      check = profiles.fetch(check.fetch("profile")).merge(check).merge("id" => identifier)
      check["environment"] = check.fetch("environment", {}).merge(values)
      if matrix["testIdentifierMap"]
        identity_key = matrix.fetch("testIdentifierAxes").map { |axis| values.fetch(axis) }.join("-")
        check["expectedTestIdentifier"] = matrix.fetch("testIdentifierMap").fetch(identity_key)
      end
      checks << check
    end
  end
  identifiers = checks.map { |check| check.fetch("id") }
  fail!("Duplicate release evidence check IDs") unless identifiers.uniq.length == identifiers.length
  checks.each do |check|
    fail!("Invalid stage for #{check.fetch("id")}") unless STAGES.include?(check.fetch("stage"))
    fail!("Invalid requirement for #{check.fetch("id")}") unless %w[required optional].include?(check.fetch("requirement"))
    fail!("Invalid evidence kind for #{check.fetch("id")}") unless %w[automated manual-attestation].include?(check.fetch("evidenceKind"))
    if check.fetch("evidenceKind") == "automated"
      fail!("Automated check is missing a component: #{check.fetch("id")}") if check["component"].to_s.empty?
      fail!("Automated check is missing a command contract: #{check.fetch("id")}") unless check["commandContract"].is_a?(Hash)
      fail!("Automated check has an invalid result format: #{check.fetch("id")}") unless %w[command-exit xcresult-summary swift-test-output].include?(check["resultFormat"])
    elsif check["resultFormat"] != "manual-observation"
      fail!("Manual check has an invalid result format: #{check.fetch("id")}")
    end
  end
  [raw, checks]
rescue JSON::ParserError, KeyError => error
  fail!("Invalid release evidence policy: #{error.message}")
end

def policy_digest(raw)
  Digest::SHA256.hexdigest(JSON.generate(raw))
end

def check_for(checks, identifier)
  checks.find { |check| check.fetch("id") == identifier } || fail!("Unknown evidence check ID: #{identifier}", 64)
end

def option_parser(arguments)
  options = {}
  command = []
  until arguments.empty?
    key = arguments.shift
    if key == "--"
      command = arguments
      break
    end
    fail!("Unexpected argument: #{key}", 64) unless key.start_with?("--")
    value = arguments.shift
    fail!("Missing value for #{key}", 64) if value.nil?
    options[key.delete_prefix("--")] = value
  end
  [options, command]
end

def required_option(options, key)
  value = options[key]
  fail!("Missing --#{key}", 64) if value.nil? || value.empty?
  value
end

def resolve_inside(root, relative, must_exist: true)
  fail!("Evidence path must be relative: #{relative}", 64) if relative.empty? || Pathname.new(relative).absolute?
  clean = Pathname.new(relative).cleanpath.to_s
  fail!("Evidence path escapes root: #{relative}", 64) if clean == ".." || clean.start_with?("../")
  root = File.realpath(root)
  candidate = File.join(root, clean)
  if must_exist
    parent = File.realpath(File.dirname(candidate))
    fail!("Evidence path escapes root: #{relative}", 64) unless parent == root || parent.start_with?(root + File::SEPARATOR)
  else
    FileUtils.mkdir_p(File.dirname(candidate)) unless File.directory?(File.dirname(candidate))
    parent = File.realpath(File.dirname(candidate))
    fail!("Evidence path escapes root: #{relative}", 64) unless parent == root || parent.start_with?(root + File::SEPARATOR)
  end
  candidate
rescue Errno::ENOENT
  fail!("Evidence path is missing: #{relative}", 66)
end

def normalized_command(command)
  command.map.with_index do |argument, index|
    next argument unless index.zero?
    argument.include?(File::SEPARATOR) ? Pathname.new(argument).cleanpath.to_s.delete_prefix("./") : File.basename(argument)
  end
end

def ordered_subsequence?(expected, actual)
  cursor = 0
  actual.each { |token| cursor += 1 if cursor < expected.length && token == expected[cursor] }
  cursor == expected.length
end

def option_values(arguments, option)
  values = []
  arguments.each_with_index do |argument, index|
    if argument == option
      values << arguments[index + 1]
    elsif argument.start_with?("#{option}=")
      values << argument.delete_prefix("#{option}=")
    end
  end
  values
end

def command_matches?(check, command)
  actual = normalized_command(command)
  contract = check.fetch("commandContract")

  return false if actual.empty?
  expected_executable = contract.fetch("executable")
  expected_executable = Pathname.new(expected_executable).cleanpath.to_s.delete_prefix("./") if expected_executable.include?(File::SEPARATOR)
  return false unless actual.first == expected_executable

  arguments = actual.drop(1)
  return arguments == contract.fetch("exactArguments") if contract.key?("exactArguments")
  return false unless Array(contract["requiredArguments"]).all? { |argument| arguments.include?(argument) }
  return false if Array(contract["forbiddenArguments"]).any? { |argument| arguments.include?(argument) }
  return false if Array(contract["forbiddenArgumentPrefixes"]).any? do |prefix|
    arguments.any? { |argument| argument.start_with?(prefix) }
  end
  return false unless Array(contract["requiredSequences"]).all? { |sequence| ordered_subsequence?(sequence, arguments) }
  contract.fetch("exclusiveOptionValues", {}).all? do |option, value|
    option_values(arguments, option) == [value]
  end
end

def validate_command!(check, command, component_label)
  fail!("Recorded command is missing", 64) if command.empty?
  expected_component = check["component"]
  if expected_component && component_label != expected_component
    fail!("Execution component mismatch for #{check.fetch("id")}: expected #{expected_component}, got #{component_label}")
  end
  fail!("Command does not match policy for #{check.fetch("id")}") unless command_matches?(check, command)
end

def validate_environment!(check, observed)
  expected = check.fetch("environment", {})
  expected.each do |key, value|
    fail!("Environment mismatch for #{check.fetch("id")}: #{key}") unless observed[key].to_s == value.to_s
  end
end

def validate_producer!(producer, trusted_context: nil)
  fail!("Trusted producer metadata is malformed") unless producer.is_a?(Hash)
  fail!("Unsupported trusted producer schema") unless producer["schema"] == "inno-flow-github-actions-producer-v1"
  %w[repository workflowPath ref headSha runId runAttempt candidateComponentLabel].each do |key|
    fail!("Trusted producer field is missing: #{key}") if producer[key].to_s.empty?
  end
  fail!("Trusted producer head SHA is invalid") unless producer["headSha"].match?(/\A[0-9a-f]{40}\z/)
  fail!("Trusted producer run ID is invalid") unless producer["runId"].to_s.match?(/\A[1-9][0-9]*\z/)
  fail!("Trusted producer run attempt is invalid") unless producer["runAttempt"].to_s.match?(/\A[1-9][0-9]*\z/)
  return producer unless trusted_context

  %w[schema repository workflowPath ref headSha runId runAttempt candidateComponentLabel].each do |key|
    fail!("Trusted producer context mismatch: #{key}") unless producer[key].to_s == trusted_context[key].to_s
  end
  producer
end

def load_trusted_context(path, snapshot)
  context = JSON.parse(File.read(path))
  validate_producer!(context)
  fail!("Trusted producer run did not succeed") unless context["conclusion"] == "success"
  fail!("Trusted producer event is not workflow_dispatch") unless context["event"] == "workflow_dispatch"
  fail!("Trusted producer artifact name is missing") if context["artifactName"].to_s.empty?
  fail!("Trusted producer artifact ID is invalid") unless context["artifactId"].to_s.match?(/\A[1-9][0-9]*\z/)
  fail!("Trusted producer artifact digest is invalid") unless context["artifactDigest"].to_s.match?(/\Asha256:[0-9a-f]{64}\z/)
  fail!("Trusted producer artifact is expired") unless context["artifactExpired"] == false
  artifact_created_at = Time.iso8601(context.fetch("artifactCreatedAt"))
  artifact_expires_at = Time.iso8601(context.fetch("artifactExpiresAt"))
  fail!("Trusted producer artifact expiration is invalid") unless artifact_expires_at > artifact_created_at
  component = snapshot.fetch("components").find do |item|
    item.fetch("label") == context.fetch("candidateComponentLabel")
  end
  fail!("Trusted producer candidate component is missing") unless component
  fail!("Trusted producer candidate component is dirty") if component.fetch("dirty")
  fail!("Trusted producer head SHA does not match candidate") unless component.fetch("headRevision") == context.fetch("headSha")
  context
rescue JSON::ParserError, KeyError, Errno::ENOENT => error
  fail!("Trusted producer context is invalid: #{error.message}")
end

def xcresult_data(path)
  summary, summary_error, summary_status = Open3.capture3(
    "xcrun", "xcresulttool", "get", "test-results", "summary", "--path", path, "--compact"
  )
  fail!("xcresult summary failed: #{summary_error.strip}") unless summary_status.success?
  tests, tests_error, tests_status = Open3.capture3(
    "xcrun", "xcresulttool", "get", "test-results", "tests", "--path", path, "--compact"
  )
  fail!("xcresult test discovery failed: #{tests_error.strip}") unless tests_status.success?
  [JSON.parse(summary), JSON.parse(tests)]
rescue JSON::ParserError => error
  fail!("xcresult JSON is malformed: #{error.message}")
end

def collect_test_cases(node, result = [])
  if node.is_a?(Hash)
    result << node if node["nodeType"] == "Test Case"
    node.each_value { |value| collect_test_cases(value, result) }
  elsif node.is_a?(Array)
    node.each { |value| collect_test_cases(value, result) }
  end
  result
end

def validate_xcresult!(check, raw_path, observed_environment)
  summary, tests = xcresult_data(raw_path)
  minimum = check.fetch("minimumTestCount", 1)
  maximum = check["maximumTestCount"]
  errors = []
  errors << "result=#{summary["result"]}" unless summary["result"] == "Passed"
  errors << "totalTestCount=#{summary["totalTestCount"]}" unless summary.fetch("totalTestCount", 0).to_i >= minimum
  errors << "totalTestCount=#{summary["totalTestCount"]}" if maximum && summary.fetch("totalTestCount", 0).to_i > maximum
  %w[failedTests skippedTests].each { |key| errors << "#{key}=#{summary[key]}" unless summary.fetch(key, 0).to_i.zero? }
  unless check.fetch("allowsExpectedFailures", false)
    errors << "expectedFailures=#{summary["expectedFailures"]}" unless summary.fetch("expectedFailures", 0).to_i.zero?
  end
  unless check.fetch("allowsRuntimeWarnings", false)
    errors << "runtimeWarnings=#{summary.fetch("runtimeWarnings", []).length}" unless summary.fetch("runtimeWarnings", []).empty?
  end
  cases = collect_test_cases(tests)
  errors << "discoveredTests=#{cases.length}" if cases.length < minimum
  errors << "discoveredTests=#{cases.length}" if maximum && cases.length > maximum
  errors << "nonPassedTestCase" unless cases.all? { |test| test["result"] == "Passed" }
  identities = cases.map { |test| test["nodeIdentifierURL"] || test["nodeIdentifier"] || test["name"] }.compact
  if let_expected = check["expectedTestIdentifier"]
    errors << "expectedTestIdentifier=#{let_expected}" unless identities.compact.any? { |identity| identity.include?(let_expected) }
  end
  Array(check["expectedTestIdentifiers"]).each do |expected|
    errors << "expectedTestIdentifier=#{expected}" unless identities.any? { |identity| identity.include?(expected) }
  end
  devices = summary.fetch("devicesAndConfigurations", []).map { |item| item.fetch("device", {}) }
  devices = tests.fetch("devices", []) if devices.empty?
  if let_expected_device = check.fetch("environment", {})["device"]
    model = devices.first && (devices.first["modelName"] || devices.first["deviceName"])
    expected_form = let_expected_device.downcase
    actual_form = if model.to_s.downcase.include?("iphone")
      "iphone"
    elsif model.to_s.downcase.include?("ipad")
      "ipad"
    elsif model.to_s.downcase.include?("mac")
      "mac"
    end
    errors << "device=#{model}" unless actual_form == expected_form
  end
  fail!("xcresult is not a complete pass for #{check.fetch("id")}: #{errors.join(", ")}") unless errors.empty?

  unless devices.empty?
    observed_environment = observed_environment.merge(
      "platform" => devices.first["platform"],
      "os" => devices.first["osVersion"],
      "deviceId" => devices.first["deviceId"]
    ).compact
    observed_environment["device"] = check.fetch("environment", {})["device"] if check.fetch("environment", {})["device"]
  end
  validate_environment!(check, observed_environment)
  {
    "summary" => summary.slice("result", "totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures"),
    "testIdentifiers" => cases.map { |test| test["nodeIdentifier"] || test["name"] }.compact.sort,
    "environment" => observed_environment,
  }
end

def validate_swift_test_output!(check, artifact_path, observed_environment)
  output = File.read(artifact_path, mode: "rb").encode("UTF-8", invalid: :replace, undef: :replace)
  output = output.gsub(/\e\[[0-9;?]*[ -\/]*[@-~]/, "")
  failures = []
  failures << "failed test run" if output.match?(/Test run with .* failed after/i)
  failures << "failed test leaf" if output.match?(/Test \".*?\" failed(?: after| with|\.)/i)
  failures << "failed XCTest suite" if output.match?(/Test Suite .* failed at/)
  failures << "skipped test" if output.match?(/(?:Test|Suite) .* skipped/i)
  failures << "unexpected signal" if output.match?(/unexpected signal|signal [0-9]+/i)

  summaries = output.scan(/Test run with ([0-9]+) tests?(?: in ([0-9]+) suites?)? passed after/i)
  failures << "missing Swift Testing pass summary" if summaries.empty?
  test_count = summaries.sum { |tests, _suites| tests.to_i }
  suite_count = summaries.sum { |_tests, suites| suites.to_i }
  leaf_count = output.scan(/Test \".*?\" passed after [0-9.]+ seconds?\./).length
  passed_suite_names = output.scan(/Suite \"(.*?)\" passed after [0-9.]+ seconds?\./).flatten
  failures << "zero discovered tests" if test_count.zero?
  failures << "summary tests=#{test_count} leaves=#{leaf_count}" unless test_count == leaf_count
  failures << "summary suites=#{suite_count} passedSuites=#{passed_suite_names.length}" unless suite_count == passed_suite_names.length

  minimum = check.fetch("minimumTestCount", 1).to_i
  maximum = check["maximumTestCount"]&.to_i
  failures << "testCount=#{test_count} minimum=#{minimum}" if test_count < minimum
  failures << "testCount=#{test_count} maximum=#{maximum}" if maximum && test_count > maximum
  if check["expectedTestRunCount"]
    failures << "testRunCount=#{summaries.length}" unless summaries.length == check.fetch("expectedTestRunCount").to_i
  end
  Array(check["expectedResultSuites"]).each do |suite|
    failures << "missingSuite=#{suite}" unless passed_suite_names.include?(suite)
  end
  fail!("Swift test output is not a complete pass for #{check.fetch("id")}: #{failures.join(", ")}") unless failures.empty?

  validate_environment!(check, observed_environment)
  {
    "environment" => observed_environment,
    "testCount" => test_count,
    "suiteCount" => suite_count,
    "testRunCount" => summaries.length,
    "passedSuites" => passed_suite_names.sort,
  }
end

def load_snapshot(path, expected_digest, expected_policy_digest)
  snapshot = JSON.parse(File.read(path))
  fail!("Unsupported candidate snapshot schema") unless snapshot["schema"] == "inno-flow-release-candidate-v2"
  components = snapshot.fetch("components")
  fail!("Candidate snapshot has no components") unless components.is_a?(Array) && !components.empty?
  labels = components.map { |component| component.fetch("label") }
  fail!("Candidate snapshot labels are duplicated or unsorted") unless labels == labels.uniq.sort
  components.each do |component|
    files = component.fetch("files")
    fail!("Candidate component has no files: #{component.fetch("label")}") unless files.is_a?(Array) && !files.empty?
    paths = files.map { |entry| entry.fetch("path") }
    fail!("Candidate file paths are duplicated or unsorted: #{component.fetch("label")}") unless paths == paths.uniq.sort
    files.each do |entry|
      fail!("Candidate file path is unsafe: #{entry.fetch("path")}") if Pathname.new(entry.fetch("path")).absolute? || entry.fetch("path").split("/").include?("..")
      fail!("Candidate file kind is invalid") unless %w[file symlink deleted].include?(entry.fetch("kind"))
    end
    digest_input = files.map { |entry| JSON.generate(entry) }.join("\n") + "\n"
    fail!("Candidate component digest mismatch: #{component.fetch("label")}") unless Digest::SHA256.hexdigest(digest_input) == component.fetch("contentDigest")
  end
  aggregate_input = components.map { |component| "#{component.fetch("label")}\t#{component.fetch("contentDigest")}" }
  aggregate_input << "policy\t#{snapshot.fetch("policyDigest")}"
  recomputed = Digest::SHA256.hexdigest(aggregate_input.join("\n") + "\n")
  fail!("Candidate snapshot aggregate is internally inconsistent") unless snapshot["aggregateDigest"] == recomputed
  fail!("Candidate snapshot digest mismatch") unless snapshot["aggregateDigest"] == expected_digest
  fail!("Candidate snapshot policy mismatch") unless snapshot["policyDigest"] == expected_policy_digest
  snapshot
rescue JSON::ParserError, KeyError, TypeError => error
  fail!("Candidate snapshot is malformed: #{error.message}")
end

command_name = ARGV.shift || fail!("Missing command", 64)
options, command = option_parser(ARGV)

case command_name
when "record-attempt"
  policy_path = required_option(options, "policy")
  raw_policy, checks = resolved_policy(policy_path)
  check = check_for(checks, required_option(options, "check-id"))
  candidate = required_option(options, "candidate")
  fail!("Attempt candidate digest is invalid", 64) unless candidate.match?(/\A[0-9a-f]{64}\z/)
  attempt_id = required_option(options, "attempt-id")
  fail!("Attempt ID is invalid", 64) unless attempt_id.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/)
  status = required_option(options, "status")
  fail!("Attempt status is invalid", 64) unless %w[PASS FAIL BLOCKED INTERRUPTED].include?(status)
  started_at = Time.iso8601(required_option(options, "started-at"))
  finished_at = Time.iso8601(required_option(options, "finished-at"))
  fail!("Attempt execution time is reversed") if finished_at < started_at
  evidence_root = File.realpath(required_option(options, "evidence-root"))
  attempt_relative = File.join("attempts", check.fetch("id"), "#{attempt_id}.json")
  attempt_path = resolve_inside(evidence_root, attempt_relative, must_exist: false)
  fail!("Attempt receipt already exists: #{attempt_relative}") if File.exist?(attempt_path) || File.symlink?(attempt_path)
  artifact_record = nil
  if options["artifact"] && !options["artifact"].empty?
    artifact_path = resolve_inside(evidence_root, options.fetch("artifact"))
    entries = artifact_manifest(artifact_path)
    artifact_record = { "path" => options.fetch("artifact"), "sha256" => artifact_digest(entries), "entries" => entries }
  end
  canonical_receipt = options["receipt"]
  resolve_inside(evidence_root, canonical_receipt) if canonical_receipt && !canonical_receipt.empty?
  detail = JSON.parse(options.fetch("detail-json", "{}"))
  fail!("Attempt detail must be a JSON object", 64) unless detail.is_a?(Hash)
  exit_code = options["exit-code"] && Integer(options.fetch("exit-code"))
  body = {
    "schema" => "inno-flow-release-evidence-attempt-v1",
    "attemptId" => attempt_id,
    "checkId" => check.fetch("id"),
    "candidateDigest" => candidate,
    "policyDigest" => policy_digest(raw_policy),
    "status" => status,
    "componentLabel" => required_option(options, "component-label"),
    "workingDirectory" => required_option(options, "working-directory"),
    "command" => normalized_command(command),
    "startedAt" => started_at.utc.iso8601,
    "finishedAt" => finished_at.utc.iso8601,
    "exitCode" => exit_code,
    "detail" => detail,
    "artifact" => artifact_record,
    "canonicalReceipt" => canonical_receipt,
  }
  temporary = "#{attempt_path}.tmp.#{$$}"
  File.write(temporary, JSON.pretty_generate(body) + "\n")
  File.rename(temporary, attempt_path)

  index_relative = required_option(options, "attempt-index")
  index_path = resolve_inside(evidence_root, index_relative, must_exist: false)
  lock_path = resolve_inside(evidence_root, "#{index_relative}.lock", must_exist: false)
  File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
    lock.flock(File::LOCK_EX)
    rows = File.file?(index_path) ? File.readlines(index_path, chomp: true) : []
    rows.shift if rows.first == "attempt_id\tcheck_id\tstatus\tcandidate_hash\tattempt_receipt_path"
    fail!("Malformed attempt index") unless rows.all? { |line| line.split("\t", -1).length == 5 }
    fail!("Duplicate attempt ID: #{attempt_id}") if rows.any? { |line| line.split("\t", 2).first == attempt_id }
    rows << [attempt_id, check.fetch("id"), status, candidate, attempt_relative].join("\t")
    index_body = +"attempt_id\tcheck_id\tstatus\tcandidate_hash\tattempt_receipt_path\n"
    index_body << rows.join("\n")
    index_body << "\n"
    index_temporary = "#{index_path}.tmp.#{$$}"
    File.write(index_temporary, index_body)
    File.rename(index_temporary, index_path)
  end
  puts [attempt_id, check.fetch("id"), status, attempt_relative].join("\t")
when "upsert-manifest"
  policy_path = required_option(options, "policy")
  raw_policy, checks = resolved_policy(policy_path)
  check = check_for(checks, required_option(options, "check-id"))
  candidate = required_option(options, "candidate")
  load_snapshot(
    required_option(options, "candidate-snapshot"),
    candidate,
    policy_digest(raw_policy)
  )
  evidence_root = File.realpath(required_option(options, "evidence-root"))
  manifest_relative = required_option(options, "manifest")
  manifest = resolve_inside(evidence_root, manifest_relative, must_exist: false)
  receipt_relative = required_option(options, "receipt")
  resolve_inside(evidence_root, receipt_relative)
  rows = if File.file?(manifest)
    File.readlines(manifest, chomp: true).reject { |line| line.empty? || line.start_with?("#", "check_id\t") }
  else
    []
  end
  parsed_rows = rows.map do |line|
    fields = line.split("\t", -1)
    fail!("Malformed evidence row: #{line}") unless fields.length == 4
    fields
  end
  identifiers = parsed_rows.map(&:first)
  fail!("Duplicate evidence row in manifest") unless identifiers.uniq.length == identifiers.length
  parsed = parsed_rows.to_h { |fields| [fields.first, fields] }
  parsed[check.fetch("id")] = [check.fetch("id"), "PASS", candidate, receipt_relative]
  policy_order = checks.map { |item| item.fetch("id") }
  ordered = parsed.values.sort_by do |fields|
    [policy_order.index(fields.first) || policy_order.length, fields.first]
  end
  body = +"check_id\tstatus\tcandidate_hash\treceipt_path\n"
  body << ordered.map { |fields| fields.join("\t") }.join("\n")
  body << "\n" unless ordered.empty?
  temporary = "#{manifest}.tmp.#{$$}"
  File.write(temporary, body)
  File.rename(temporary, manifest)
  puts [check.fetch("id"), "PASS", candidate, receipt_relative].join("\t")
when "validate-command"
  policy_path = required_option(options, "policy")
  raw_policy, checks = resolved_policy(policy_path)
  check = check_for(checks, required_option(options, "check-id"))
  fail!("Check is not automated") unless check["evidenceKind"] == "automated"
  candidate = required_option(options, "candidate")
  snapshot_path = required_option(options, "candidate-snapshot")
  load_snapshot(snapshot_path, candidate, policy_digest(raw_policy))
  validate_command!(check, command, required_option(options, "component-label"))
  puts [check.fetch("id"), "COMMAND_VALID", candidate].join("\t")
when "record-automated"
  policy_path = required_option(options, "policy")
  raw_policy, checks = resolved_policy(policy_path)
  check = check_for(checks, required_option(options, "check-id"))
  fail!("Check is not automated") unless check["evidenceKind"] == "automated"
  candidate = required_option(options, "candidate")
  snapshot_path = required_option(options, "candidate-snapshot")
  digest = policy_digest(raw_policy)
  load_snapshot(snapshot_path, candidate, digest)
  evidence_root = File.realpath(required_option(options, "evidence-root"))
  artifact_relative = required_option(options, "artifact")
  artifact = resolve_inside(evidence_root, artifact_relative)
  receipt_relative = required_option(options, "receipt")
  receipt = resolve_inside(evidence_root, receipt_relative, must_exist: false)
  exit_code = Integer(required_option(options, "exit-code"))
  fail!("Recorded command failed with exit #{exit_code}") unless exit_code.zero?
  component_label = required_option(options, "component-label")
  validate_command!(check, command, component_label)
  observed = JSON.parse(options.fetch("environment-json", "{}"))
  producer = options["producer-json"] && JSON.parse(options.fetch("producer-json"))
  validate_producer!(producer) if check["trustedProducerRequired"]
  artifact_entries = artifact_manifest(artifact)
  if check.fetch("artifactContent") == "non-empty"
    fail!("Evidence artifact is empty") if artifact_entries.sum { |entry| entry.fetch("size") }.zero?
  end
  result = { "environment" => observed }
  raw_record = nil
  if check["resultFormat"] == "xcresult-summary"
    raw_relative = required_option(options, "raw-artifact")
    raw_path = resolve_inside(evidence_root, raw_relative)
    raw_entries = artifact_manifest(raw_path)
    result = validate_xcresult!(check, raw_path, observed)
    raw_record = { "path" => raw_relative, "sha256" => artifact_digest(raw_entries), "entries" => raw_entries }
  elsif check["resultFormat"] == "swift-test-output"
    result = validate_swift_test_output!(check, artifact, observed)
  else
    validate_environment!(check, observed)
  end
  receipt_body = {
    "schema" => "inno-flow-release-evidence-receipt-v3",
    "attemptId" => required_option(options, "attempt-id"),
    "checkId" => check.fetch("id"),
    "candidateDigest" => candidate,
    "candidateSnapshotSha256" => sha256_file(snapshot_path),
    "policyDigest" => digest,
    "status" => "PASS",
    "evidenceKind" => "automated",
    "resultFormat" => check.fetch("resultFormat"),
    "command" => normalized_command(command),
    "commandSha256" => Digest::SHA256.hexdigest(normalized_command(command).join("\0")),
    "execution" => {
      "componentLabel" => component_label,
      "workingDirectory" => required_option(options, "working-directory"),
      "startedAt" => Time.iso8601(required_option(options, "started-at")).utc.iso8601,
      "finishedAt" => Time.iso8601(required_option(options, "finished-at")).utc.iso8601,
    },
    "exitCode" => exit_code,
    "toolchain" => required_option(options, "toolchain"),
    "artifact" => { "path" => artifact_relative, "sha256" => artifact_digest(artifact_entries), "entries" => artifact_entries },
    "rawArtifact" => raw_record,
    "result" => result,
    "producer" => producer,
    "createdAt" => Time.now.utc.iso8601,
  }
  temporary = "#{receipt}.tmp.#{$$}"
  File.write(temporary, JSON.pretty_generate(receipt_body) + "\n")
  File.rename(temporary, receipt)
  puts [check.fetch("id"), "PASS", candidate, receipt_relative].join("\t")
when "record-manual"
  policy_path = required_option(options, "policy")
  raw_policy, checks = resolved_policy(policy_path)
  check = check_for(checks, required_option(options, "check-id"))
  fail!("Check is not a manual attestation") unless check["evidenceKind"] == "manual-attestation"
  candidate = required_option(options, "candidate")
  snapshot_path = required_option(options, "candidate-snapshot")
  digest = policy_digest(raw_policy)
  load_snapshot(snapshot_path, candidate, digest)
  evidence_root = File.realpath(required_option(options, "evidence-root"))
  artifact_relative = required_option(options, "artifact")
  artifact = resolve_inside(evidence_root, artifact_relative)
  receipt_relative = required_option(options, "receipt")
  receipt = resolve_inside(evidence_root, receipt_relative, must_exist: false)
  entries = artifact_manifest(artifact)
  fail!("Manual evidence artifact is empty") if entries.sum { |entry| entry.fetch("size") }.zero?
  observed = JSON.parse(required_option(options, "environment-json"))
  producer = options["producer-json"] && JSON.parse(options.fetch("producer-json"))
  validate_producer!(producer) if check["trustedProducerRequired"]
  validate_environment!(check, observed)
  observed_at = Time.iso8601(required_option(options, "observed-at"))
  fail!("Manual observation timestamp must be UTC") unless observed_at.utc_offset.zero?
  body = {
    "schema" => "inno-flow-release-evidence-receipt-v3", "checkId" => check.fetch("id"),
    "attemptId" => required_option(options, "attempt-id"),
    "candidateDigest" => candidate, "candidateSnapshotSha256" => sha256_file(snapshot_path),
    "policyDigest" => digest, "status" => "PASS", "evidenceKind" => "manual-attestation",
    "resultFormat" => "manual-observation", "reviewer" => required_option(options, "reviewer"),
    "observedAt" => observed_at.utc.iso8601, "environment" => observed,
    "artifact" => { "path" => artifact_relative, "sha256" => artifact_digest(entries), "entries" => entries },
    "producer" => producer,
    "createdAt" => Time.now.utc.iso8601,
  }
  temporary = "#{receipt}.tmp.#{$$}"
  File.write(temporary, JSON.pretty_generate(body) + "\n")
  File.rename(temporary, receipt)
  puts [check.fetch("id"), "PASS", candidate, receipt_relative].join("\t")
when "verify"
  policy_path = required_option(options, "policy")
  raw_policy, checks = resolved_policy(policy_path)
  stage = required_option(options, "stage")
  fail!("Unknown release evidence stage: #{stage}", 64) unless STAGES.include?(stage)
  candidate = required_option(options, "candidate")
  snapshot_path = required_option(options, "candidate-snapshot")
  digest = policy_digest(raw_policy)
  snapshot = load_snapshot(snapshot_path, candidate, digest)
  snapshot_sha = sha256_file(snapshot_path)
  evidence_root = File.realpath(required_option(options, "evidence-root"))
  manifest = required_option(options, "manifest")
  attempt_index_relative = required_option(options, "attempt-index")
  attempt_index_path = resolve_inside(evidence_root, attempt_index_relative)
  attempt_lines = File.readlines(attempt_index_path, chomp: true)
  expected_attempt_header = "attempt_id\tcheck_id\tstatus\tcandidate_hash\tattempt_receipt_path"
  fail!("Attempt index header is invalid") unless attempt_lines.shift == expected_attempt_header
  attempt_records = {}
  attempt_lines.reject(&:empty?).each do |line|
    fields = line.split("\t", -1)
    fail!("Malformed attempt index row: #{line}") unless fields.length == 5
    attempt_id, attempt_check_id, attempt_status, attempt_candidate, attempt_relative = fields
    fail!("Duplicate attempt index row: #{attempt_id}") if attempt_records.key?(attempt_id)
    fail!("Unknown attempt check ID: #{attempt_check_id}") unless checks.any? { |item| item.fetch("id") == attempt_check_id }
    fail!("Attempt index candidate mismatch: #{attempt_id}") unless attempt_candidate == candidate
    attempt_path = resolve_inside(evidence_root, attempt_relative)
    attempt = JSON.parse(File.read(attempt_path))
    fail!("Attempt receipt schema mismatch: #{attempt_id}") unless attempt["schema"] == "inno-flow-release-evidence-attempt-v1"
    fail!("Attempt receipt ID mismatch: #{attempt_id}") unless attempt["attemptId"] == attempt_id
    fail!("Attempt receipt check mismatch: #{attempt_id}") unless attempt["checkId"] == attempt_check_id
    fail!("Attempt receipt status mismatch: #{attempt_id}") unless attempt["status"] == attempt_status
    fail!("Attempt receipt candidate mismatch: #{attempt_id}") unless attempt["candidateDigest"] == candidate
    fail!("Attempt receipt policy mismatch: #{attempt_id}") unless attempt["policyDigest"] == digest
    if attempt["artifact"]
      attempt_artifact = attempt.fetch("artifact")
      actual_entries = artifact_manifest(resolve_inside(evidence_root, attempt_artifact.fetch("path")))
      fail!("Attempt artifact digest mismatch: #{attempt_id}") unless artifact_digest(actual_entries) == attempt_artifact["sha256"]
    end
    attempt_records[attempt_id] = attempt
  end
  requested_rank = STAGES.index(stage)
  expected = checks.select { |check| STAGES.index(check.fetch("stage")) <= requested_rank }
  trusted_context = nil
  if expected.any? { |check| check["trustedProducerRequired"] }
    trusted_context = load_trusted_context(required_option(options, "trusted-producer-context"), snapshot)
  end
  expected_by_id = expected.to_h { |check| [check.fetch("id"), check] }
  fail!("Evidence manifest is missing: #{manifest}", 66) unless File.file?(manifest)
  rows = File.readlines(manifest, chomp: true).reject { |line| line.empty? || line.start_with?("#", "check_id\t") }
  seen = {}
  errors = []
  rows.each do |line|
    identifier, status, row_candidate, receipt_relative, extra = line.split("\t", 5)
    if [identifier, status, row_candidate, receipt_relative].any?(&:nil?) || extra
      errors << "Malformed evidence row: #{line}"
      next
    end
    check = expected_by_id[identifier]
    errors << "Unknown or out-of-stage evidence check ID: #{identifier}" unless check
    errors << "Duplicate evidence check ID: #{identifier}" if seen[identifier]
    seen[identifier] = true
    errors << "Evidence check is not PASS: #{identifier} (#{status})" unless status == "PASS"
    errors << "Stale candidate hash for #{identifier}" unless row_candidate == candidate
    next unless check
    begin
      receipt_path = resolve_inside(evidence_root, receipt_relative)
      fail!("Evidence receipt is a symlink") if File.symlink?(receipt_path)
      receipt = JSON.parse(File.read(receipt_path))
      errors << "Receipt schema mismatch for #{identifier}" unless receipt["schema"] == "inno-flow-release-evidence-receipt-v3"
      errors << "Receipt check ID mismatch for #{identifier}" unless receipt["checkId"] == identifier
      errors << "Receipt attempt ID is missing for #{identifier}" if receipt["attemptId"].to_s.empty?
      attempt = attempt_records[receipt["attemptId"]]
      errors << "Canonical PASS attempt is missing for #{identifier}" unless attempt
      if attempt
        errors << "Canonical attempt check mismatch for #{identifier}" unless attempt["checkId"] == identifier
        errors << "Canonical attempt is not PASS for #{identifier}" unless attempt["status"] == "PASS"
        errors << "Canonical attempt receipt mismatch for #{identifier}" unless attempt["canonicalReceipt"] == receipt_relative
      end
      errors << "Receipt candidate mismatch for #{identifier}" unless receipt["candidateDigest"] == candidate
      errors << "Receipt snapshot mismatch for #{identifier}" unless receipt["candidateSnapshotSha256"] == snapshot_sha
      errors << "Receipt policy mismatch for #{identifier}" unless receipt["policyDigest"] == digest
      errors << "Receipt status mismatch for #{identifier}" unless receipt["status"] == "PASS"
      errors << "Receipt evidence kind mismatch for #{identifier}" unless receipt["evidenceKind"] == check["evidenceKind"]
      errors << "Receipt result format mismatch for #{identifier}" unless receipt["resultFormat"] == check["resultFormat"]
      validate_producer!(receipt["producer"], trusted_context: trusted_context) if check["trustedProducerRequired"]
      if check["evidenceKind"] == "automated"
        recorded_command = receipt["command"]
        errors << "Receipt command is malformed for #{identifier}" unless recorded_command.is_a?(Array) && recorded_command.all? { |item| item.is_a?(String) }
        if recorded_command.is_a?(Array)
          errors << "Receipt command violates policy for #{identifier}" unless command_matches?(check, recorded_command)
          errors << "Receipt command digest mismatch for #{identifier}" unless receipt["commandSha256"] == Digest::SHA256.hexdigest(recorded_command.join("\0"))
        end
        execution = receipt["execution"]
        errors << "Receipt execution metadata is missing for #{identifier}" unless execution.is_a?(Hash)
        if execution.is_a?(Hash)
          errors << "Receipt execution component mismatch for #{identifier}" unless execution["componentLabel"] == check["component"] || check["component"].nil?
          errors << "Receipt working directory is missing for #{identifier}" if execution["workingDirectory"].to_s.empty?
          started_at = Time.iso8601(execution.fetch("startedAt"))
          finished_at = Time.iso8601(execution.fetch("finishedAt"))
          errors << "Receipt execution time is reversed for #{identifier}" if finished_at < started_at
        end
        errors << "Receipt exit code mismatch for #{identifier}" unless receipt["exitCode"] == 0
        errors << "Receipt toolchain is missing for #{identifier}" if receipt["toolchain"].to_s.empty?
        unless %w[xcresult-summary swift-test-output].include?(check["resultFormat"])
          validate_environment!(check, receipt.dig("result", "environment") || {})
        end
      else
        errors << "Manual reviewer is missing for #{identifier}" if receipt["reviewer"].to_s.empty?
        Time.iso8601(receipt.fetch("observedAt"))
        validate_environment!(check, receipt.fetch("environment"))
      end
      [receipt["artifact"], receipt["rawArtifact"]].compact.each do |record|
        actual_path = resolve_inside(evidence_root, record.fetch("path"))
        actual_entries = artifact_manifest(actual_path)
        errors << "Artifact digest mismatch for #{identifier}" unless artifact_digest(actual_entries) == record["sha256"]
        if check.fetch("artifactContent") == "non-empty" && actual_entries.sum { |entry| entry.fetch("size") }.zero?
          errors << "Evidence artifact is empty for #{identifier}"
        end
      end
      if check["resultFormat"] == "xcresult-summary"
        raw_record = receipt["rawArtifact"]
        if raw_record.nil?
          errors << "Raw xcresult is missing for #{identifier}"
        else
          validate_xcresult!(check, resolve_inside(evidence_root, raw_record.fetch("path")), receipt.dig("result", "environment") || {})
        end
      elsif check["resultFormat"] == "swift-test-output"
        validate_swift_test_output!(check, resolve_inside(evidence_root, receipt.fetch("artifact").fetch("path")), receipt.dig("result", "environment") || {})
      end
    rescue JSON::ParserError, KeyError, TypeError, ArgumentError, SystemExit => error
      errors << "Receipt or artifact invalid for #{identifier}: #{error.message}"
    end
  end
  expected.each do |check|
    errors << "Required evidence check is missing: #{check.fetch("id")}" if check["requirement"] == "required" && !seen[check.fetch("id")]
  end
  unless errors.empty? || rows.empty?
    errors.each { |error| warn error }
  end
  if rows.empty? || !errors.empty?
    puts "RELEASE_EVIDENCE_INCOMPLETE errors=#{errors.length} rows=#{rows.length} expected=#{expected.length} stage=#{stage}"
    exit 1
  end
  puts "RELEASE_EVIDENCE_COMPLETE candidate=#{candidate} rows=#{rows.length} expected=#{expected.length} stage=#{stage}"
else
  fail!("Unknown command: #{command_name}", 64)
end
