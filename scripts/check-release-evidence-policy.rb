#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "digest"
require "open3"
require "tmpdir"

begin
  root = ARGV.fetch(0, File.expand_path("..", __dir__))
  policy_path = File.join(root, "docs/contracts/release-evidence-policy.json")
  source_path = File.join(root, "Tests/InnoFlowTests/CompileContractTests.swift")
  policy = JSON.parse(File.read(policy_path))
  expected_ids_by_stage = {
    "local-preflight" => %w[
      static-format static-innoflow-diff static-principle doc-swift-syntax doc-copyable-examples coverage full-principle
      tsan-focused asan-focused external-macro-consumer migration-consumer catalyst-macro-consumer
      swift-6.3-toolchain sample-swift-6.3 swift-6.4-toolchain sdk-macos sdk-ios sdk-tvos
      sdk-watchos sdk-visionos runtime-ios-18.5 runtime-ios-27.0
      runtime-tvos-18.5 runtime-tvos-27.0 runtime-watchos-11.5
      runtime-watchos-27.0 runtime-visionos-2.5 runtime-visionos-27.0
    ],
    "pre-publication" => %w[remote-ci tag-api-baseline release-approval],
    "post-publication" => %w[public-package-install],
  }
  actual_ids_by_stage = policy.fetch("checks").group_by { |entry| entry.fetch("stage") }
    .transform_values { |entries| entries.map { |entry| entry.fetch("id") } }
  abort "[release-evidence-policy] framework-only check inventory changed" unless actual_ids_by_stage == expected_ids_by_stage
  abort "[release-evidence-policy] framework-only policy must not contain product matrices" unless policy.fetch("matrices", []).empty?
  abort "[release-evidence-policy] retired product dependency remains" if File.read(policy_path).match?(/mulbyul/i)
  migration = policy.fetch("checks").find { |entry| entry["id"] == "migration-consumer" }
  abort "[release-evidence-policy] migration consumer command changed" unless
    migration&.dig("commandContract") == { "executable" => "scripts/check-migration-consumer.sh", "exactArguments" => [] } &&
    migration["profile"] == "command"
  doc_syntax = policy.fetch("checks").find { |entry| entry["id"] == "doc-swift-syntax" }
  abort "[release-evidence-policy] documentation syntax contract changed" unless
    doc_syntax&.dig("commandContract") == { "executable" => "scripts/check-doc-swift-syntax.rb", "exactArguments" => [] } &&
    doc_syntax["profile"] == "command" && File.executable?(File.join(root, "scripts/check-doc-swift-syntax.rb"))
  doc_copyable = policy.fetch("checks").find { |entry| entry["id"] == "doc-copyable-examples" }
  abort "[release-evidence-policy] copyable documentation contract changed" unless
    doc_copyable&.dig("commandContract") == { "executable" => "scripts/check-doc-copyable-examples.rb", "exactArguments" => [] } &&
    doc_copyable["profile"] == "command" && File.executable?(File.join(root, "scripts/check-doc-copyable-examples.rb"))
  sample = policy.fetch("checks").find { |entry| entry["id"] == "sample-swift-6.3" }
  abort "[release-evidence-policy] Swift 6.3 sample contract changed" unless
    sample&.dig("commandContract") == {
      "executable" => "scripts/check-sample-swift63.sh", "requiredArguments" => ["--scratch-path"]
    } && sample["minimumTestCount"] == 43 && sample["maximumTestCount"] == 43 &&
    sample["expectedTestRunCount"] == 1 &&
    sample["expectedResultSuites"] == ["InnoFlowSampleAppFeature tests"] &&
    sample.dig("environment", "swift") == "6.3"
  sample_script = File.join(root, "scripts/check-sample-swift63.sh")
  abort "[release-evidence-policy] Swift 6.3 sample runner is missing" unless
    File.executable?(sample_script) && File.read(sample_script).include?("-DINNOFLOW_DISABLE_PREVIEWS")
  runner = File.join(root, "scripts/run-release-preflight.sh")
  abort "[release-evidence-policy] preflight runner must be executable" unless File.executable?(runner)
  plan, error, status = Open3.capture3(runner, "plan", "--evidence-root", File.join(Dir.tmpdir, "innoflow-preflight-plan"))
  abort "[release-evidence-policy] preflight catalog failed: #{error.strip}" unless status.success?
  planned_ids = plan.lines.map { |line| line.split("\t", 2).first }
  abort "[release-evidence-policy] preflight catalog does not cover every local check" unless
    planned_ids == expected_ids_by_stage.fetch("local-preflight")
  check = policy.fetch("checks").find { |entry| entry.fetch("id") == "external-macro-consumer" }
  abort "[release-evidence-policy] external-macro-consumer is missing" unless check

  names = Array(check["expectedTestNames"])
  abort "[release-evidence-policy] external macro test inventory is empty" if names.empty?
  abort "[release-evidence-policy] external macro test inventory contains blank names" if names.any? { |name| !name.is_a?(String) || name.empty? }
  abort "[release-evidence-policy] external macro test inventory contains duplicates" unless names.uniq.length == names.length
  abort "[release-evidence-policy] external macro suite contract changed" unless check["expectedResultSuites"] == ["Compile Contract Tests"]
  abort "[release-evidence-policy] external macro test minimum does not match inventory" unless check["minimumTestCount"] == names.length
  abort "[release-evidence-policy] external macro test maximum does not match inventory" unless check["maximumTestCount"] == names.length
  abort "[release-evidence-policy] external macro run count must be one" unless check["expectedTestRunCount"] == 1

  # Swift 6.3 aggregates the Core and macro suites into one run, while the
  # Xcode 27 Swift 6.4 runner emits two. These counts were measured from the
  # complete 784-test outputs, not inferred from the number of test targets.
  { "swift-6.3-toolchain" => 1, "swift-6.4-toolchain" => 2 }.each do |id, expected_runs|
    toolchain_check = policy.fetch("checks").find { |entry| entry.fetch("id") == id }
    abort "[release-evidence-policy] #{id} is missing" unless toolchain_check
    abort "[release-evidence-policy] #{id} run count changed" unless
      toolchain_check["expectedTestRunCount"] == expected_runs
  end

  contract = check.fetch("commandContract")
  abort "[release-evidence-policy] external macro command must be swift" unless contract["executable"] == "swift"
  abort "[release-evidence-policy] external macro command must require swift test" unless Array(contract["requiredArguments"]).include?("test")
  abort "[release-evidence-policy] external macro command must select the full suite" unless contract.dig("exclusiveOptionValues", "--filter") == "CompileContractTests"
  abort "[release-evidence-policy] external macro command must reject skip options" unless Array(contract["forbiddenArgumentPrefixes"]).include?("--skip")
  abort "[release-evidence-policy] external macro command must reject package redirection" unless Array(contract["forbiddenArgumentPrefixes"]).include?("--package-path")

  sdk_checks = policy.fetch("checks").select { |entry| entry.fetch("id").start_with?("sdk-") }
  abort "[release-evidence-policy] five SDK checks are required" unless sdk_checks.length == 5
  build_profile = policy.fetch("profiles").fetch("build")
  abort "[release-evidence-policy] SDK build profile must require raw structured results" unless
    build_profile["resultFormat"] == "xcresult-build-results" &&
    build_profile["requiresRawArtifact"] == true &&
    build_profile["artifactContent"] == "non-empty"
  sdk_checks.each do |sdk_check|
    sdk_contract = sdk_check.fetch("commandContract")
    abort "[release-evidence-policy] #{sdk_check.fetch("id")} must preserve raw build results" unless sdk_check["profile"] == "build"
    abort "[release-evidence-policy] #{sdk_check.fetch("id")} can redirect or skip the build" unless
      sdk_contract["executable"] == "scripts/run-sdk-platform-build.sh" &&
      Array(sdk_contract["requiredArguments"]) == %w[--platform --derived-data --result-bundle] &&
      sdk_contract.dig("exclusiveOptionValues", "--platform") == sdk_check.dig("environment", "platform")
  end

  runtime_checks = policy.fetch("checks").select { |entry| entry.fetch("id").start_with?("runtime-") }
  abort "[release-evidence-policy] eight runtime checks are required" unless runtime_checks.length == 8
  inventory_relative = "docs/contracts/runtime-test-inventory.json"
  inventory_path = File.join(root, inventory_relative)
  inventory = JSON.parse(File.read(inventory_path))
  expected_suites = %w[
    CollectionScopeCacheTests DispatchDiagnosticsTests EffectRunSchedulerTests
    FlowScopeTests OutputCasePathTests SingleScopeCacheTests StoreScopeSelectionTests
  ]
  identifiers = inventory.fetch("expectedTestIdentifiers")
  abort "[release-evidence-policy] runtime inventory suites changed" unless inventory.fetch("suites") == expected_suites
  abort "[release-evidence-policy] runtime inventory is empty, duplicated, or unsorted" unless
    identifiers.is_a?(Array) && !identifiers.empty? && identifiers == identifiers.uniq.sort
  abort "[release-evidence-policy] runtime inventory suite mismatch" unless
    identifiers.map { |identifier| identifier.split("/", 2).first }.uniq.sort == expected_suites
  inventory_sha = Digest::SHA256.file(inventory_path).hexdigest
  runtime_checks.each do |runtime_check|
    abort "[release-evidence-policy] #{runtime_check.fetch("id")} has no pinned runtime inventory" unless
      runtime_check["testIdentifierInventory"] == inventory_relative &&
      runtime_check["testIdentifierInventorySha256"] == inventory_sha &&
      !runtime_check.key?("expectedTestIdentifiers")
  end
  runner = File.read(File.join(root, "scripts/run-focused-platform-runtime-tests.sh"))
  expected_suites.each do |suite|
    abort "[release-evidence-policy] runtime runner omits #{suite}" unless
      runner.include?("-only-testing:InnoFlowTests/#{suite}")
  end

  source = File.read(source_path)
  source_names = source.scan(/^\s+@Test\s*\(\s*"((?:[^"\\]|\\.)*)"/).flatten.map do |escaped_name|
    JSON.parse(%Q{"#{escaped_name}"})
  end
  abort "[release-evidence-policy] source test display names contain duplicates" unless source_names.uniq.length == source_names.length
  unless source_names.sort == names.sort
    missing = names - source_names
    unexpected = source_names - names
    abort "[release-evidence-policy] source inventory mismatch missing=#{missing.inspect} unexpected=#{unexpected.inspect}"
  end

  puts "[release-evidence-policy] External macro inventory and command contract passed (#{names.length} tests)"
rescue JSON::ParserError, KeyError => error
  abort "[release-evidence-policy] Invalid policy: #{error.message}"
end
