#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "hosted-release-preflight"
require "rbconfig"
require "yaml"

def assert(value, message)
  raise message unless value
end

def rejects(message)
  begin
    yield
  rescue StandardError => error
    raise "Wrong failure for #{message}: #{error.message}" unless error.message.include?(message)
    return
  end
  raise "Expected rejection: #{message}"
end

def command!(*command, chdir:)
  output, error, status = Open3.capture3(*command, chdir: chdir)
  raise "Fixture command failed #{command.inspect}: #{output} #{error}" unless status.success?
  output
end

def pack_shards(source, destination)
  Dir.children(source).each do |name|
    archive = File.join(destination, name, "evidence.tar.gz")
    ReleaseEvidenceArchive.pack(File.join(source, name), archive)
    File.chmod(0o644, archive) # Emulate GitHub ZIP's permission normalization.
  end
end

class RuntimeProvisioningFixture < HostedReleasePreflight
  attr_accessor :available
  attr_reader :calls, :identifiers

  def initialize(root, responses, success, failure)
    super(root)
    @responses, @success, @failure = responses, success, failure
    @available = false
    @calls, @identifiers = [], []
  end

  def runtime_available?(identifier)
    @identifiers << identifier
    @available
  end

  def run_provisioning(*command)
    @calls << command
    response = @responses.shift or raise "Unexpected provisioning command: #{command.inspect}"
    response.fetch(:output, "").each_line { |line| yield line if block_given? }
    return @failure if response[:failure]
    if command.include?("-downloadPlatform")
      image = File.join(command.last, "fixture.simruntime.dmg")
      case response[:image]
      when :missing then nil
      when :symlink then File.symlink("missing-target", image)
      when :directory then Dir.mkdir(image)
      else
        File.write(image, "fixture")
        File.write(File.join(command.last, "extra.dmg"), "fixture") if response[:image] == :multiple
      end
    elsif command.include?("-importPlatform")
      @available = response.fetch(:available, true)
    end
    @success
  end
end

source = File.expand_path("..", __dir__)
matrix = HostedReleasePreflight.new(source).matrix.fetch("include")
assert(matrix.length == 32 && matrix.map { |row| row.fetch("check") }.uniq.length == 32, "Missing required matrix check")
assert(matrix.count { |row| row["runner"] == "macos-26" && row["swift"] == "6.3" && row["xcode"] == "26.6" } == 2, "Wrong minimum toolchain jobs")
assert(matrix.count { |row| row["runner"] == "xcode-27" && row["swift"] == "6.4" && row["xcode"] == "27.0" } == 30, "Wrong current toolchain jobs")
workflow = YAML.safe_load(File.read(File.join(source, ".github/workflows/release-preflight.yml")))
diagnostics = workflow.fetch("jobs").fetch("preflight").fetch("steps").find do |step|
  step["name"] == "Preserve failed or cancelled diagnostics separately"
end
assert(diagnostics.fetch("if") == "${{ failure() || cancelled() }}", "Lost failure/cancellation diagnostics")
assert(diagnostics.fetch("with").fetch("path").lines.map(&:strip) ==
  ["${{ steps.evidence.outputs.root }}", "${{ steps.evidence.outputs.root }}-provisioning"], "Early provisioning logs are not uploaded")

Dir.mktmpdir("innoflow-hosted-selftest-") do |fixture|
  repo = File.join(fixture, "repo")
  FileUtils.mkdir_p(File.join(repo, "scripts"))
  FileUtils.mkdir_p(File.join(repo, "docs/contracts"))
  %w[release-candidate-snapshot.rb release-evidence-tool.rb release-evidence-output-parser.rb
    record-release-evidence.sh verify-release-evidence.sh].each do |name|
    FileUtils.cp(File.join(source, "scripts", name), File.join(repo, "scripts", name))
  end
  checks = %w[first-check second-check].map do |id|
    { "id" => id, "stage" => "local-preflight", "requirement" => "required", "profile" => "command",
      "component" => "innoflow", "allowedCommand" => "ruby -e", "commandContract" => {
        "executable" => "ruby", "exactArguments" => ["-e", "puts '#{id}'"] } }
  end
  policy = { "schema" => "inno-flow-release-evidence-policy-v3",
    "stageOrder" => %w[local-preflight pre-publication post-publication],
    "profiles" => { "command" => { "evidenceKind" => "automated", "resultFormat" => "command-exit", "artifactContent" => "non-empty" } },
    "checks" => checks, "matrices" => [] }
  policy_path = File.join(repo, "docs/contracts/release-evidence-policy.json")
  File.write(policy_path, JSON.pretty_generate(policy) + "\n")
  command!("git", "init", "-q", chdir: repo)
  command!("git", "config", "user.name", "Hosted fixture", chdir: repo)
  command!("git", "config", "user.email", "fixture@example.invalid", chdir: repo)
  command!("git", "add", "scripts", "docs", chdir: repo)
  command!("git", "commit", "-qm", "fixture", chdir: repo)
  sha = command!("git", "rev-parse", "HEAD", chdir: repo).strip
  # CI emulation is confined to this disposable fixture process and never
  # executes the production release matrix or installs a real runtime.
  ENV.update("GITHUB_ACTIONS" => "true", "RUNNER_ENVIRONMENT" => "github-hosted",
    "GITHUB_REF" => "refs/heads/main", "GITHUB_SHA" => sha, "RUNNER_TEMP" => fixture)
  runner = HostedReleasePreflight.new(repo)
  ENV["RUNNER_ENVIRONMENT"] = "self-hosted"
  rejects("CI-only") { runner.hosted! }
  ENV["RUNNER_ENVIRONMENT"] = "github-hosted"
  ENV["GITHUB_ACTIONS"] = "false"
  rejects("CI-only") { runner.hosted! }
  ENV["GITHUB_ACTIONS"] = "true"
  ENV["GITHUB_REF"] = "refs/heads/feature"
  rejects("Only exact main") { runner.hosted! }
  ENV["GITHUB_REF"] = "refs/heads/main"
  ENV["GITHUB_SHA"] = "0" * 40
  rejects("Only exact main") { runner.hosted! }
  ENV["GITHUB_SHA"] = sha

  shards = File.join(fixture, "shards")
  FileUtils.mkdir_p(shards)
  checks.each do |check|
    id = check.fetch("id")
    shard = File.join(shards, "innoflow-preflight-shard-#{sha}-#{id}")
    FileUtils.mkdir_p(shard)
    snapshot_path = File.join(shard, "candidate.json")
    snapshot = command!("scripts/release-candidate-snapshot.rb", "--repository", "innoflow=#{repo}", "--policy", policy_path, chdir: repo)
    File.write(snapshot_path, snapshot)
    old_mask = File.umask(0o077)
    command!("scripts/record-release-evidence.sh", "--check-id", id, "--candidate-hash", JSON.parse(snapshot).fetch("aggregateDigest"),
      "--candidate-snapshot", snapshot_path, "--repository", "innoflow=#{repo}", "--component-label", "innoflow",
      "--evidence-root", shard, "--manifest", "manifest.tsv", "--attempt-id", id, "--attempt-index", "attempts.tsv",
      "--artifact", "runs/#{id}/output.log", "--receipt", "runs/#{id}/receipt.json", "--toolchain", "fixture",
      "--policy", policy_path, "--", "ruby", "-e", "puts '#{id}'", chdir: repo)
    File.umask(old_mask)
  end
  archives = File.join(fixture, "archives")
  pack_shards(shards, archives)
  runner.merge(archives, File.join(fixture, "complete"))
  original = File.join(shards, "innoflow-preflight-shard-#{sha}-first-check")
  %w[receipt.json output.log].each do |name|
    assert(File.binread(File.join(original, "runs/first-check", name)) == File.binread(File.join(fixture, "complete/runs/first-check", name)), "Evidence bytes changed")
    assert((File.stat(File.join(fixture, "complete/runs/first-check", name)).mode & 0o777) == 0o600, "Evidence mode changed by transport")
  end
  rejects("already exists") { runner.merge(archives, File.join(fixture, "complete")) }
  rejects("outside checkout") { runner.merge(archives, File.join(repo, "inside")) }

  mutations = {
    "Missing or unexpected" => ->(copy) { FileUtils.remove_entry(File.join(copy, "innoflow-preflight-shard-#{sha}-second-check")) },
    "Shard snapshot mismatch" => ->(copy) { File.write(File.join(copy, File.basename(original), "candidate.json"), "{}") },
    "exactly its PASS" => ->(copy) { path = File.join(copy, File.basename(original), "manifest.tsv"); File.write(path, File.read(path).sub("\tPASS\t", "\tFAIL\t")) },
    "Unexpected shard attempts" => ->(copy) { path = File.join(copy, File.basename(original), "attempts.tsv"); File.write(path, File.read(path).sub("\tfirst-check\t", "\tsecond-check\t")) },
    "Unsafe" => ->(copy) { File.symlink("/tmp", File.join(copy, File.basename(original), "external")) },
    "Command failed" => ->(copy) { File.write(File.join(copy, File.basename(original), "runs/first-check/output.log"), "tampered") },
  }
  mutations.each_with_index do |(message, mutation), index|
    copy = File.join(fixture, "mutation-#{index}")
    FileUtils.cp_r(shards, copy)
    mutation.call(copy)
    rejects(message) do
      packed = File.join(fixture, "packed-mutation-#{index}")
      pack_shards(copy, packed)
      runner.merge(packed, File.join(fixture, "rejected-#{index}"))
    end
  end

  ["../escape", "/tmp/innoflow-escape", "nested/../../escape"].each_with_index do |name, index|
    archive = File.join(fixture, "unsafe-#{index}.tar.gz")
    Zlib::GzipWriter.open(archive) do |gzip|
      Gem::Package::TarWriter.new(gzip) do |tar|
        tar.add_file_simple(name, 0o644, 1) { |entry| entry.write("x") }
      end
    end
    rejects("Unsafe archive path") { ReleaseEvidenceArchive.unpack(archive, File.join(fixture, "unsafe-output-#{index}")) }
  end
  link_archive = File.join(fixture, "link.tar.gz")
  Zlib::GzipWriter.open(link_archive) do |gzip|
    Gem::Package::TarWriter.new(gzip) { |tar| tar.add_symlink("link", "/tmp", 0o777) }
  end
  rejects("Unsafe archive type") { ReleaseEvidenceArchive.unpack(link_archive, File.join(fixture, "link-output")) }

  # Runtime command fixtures: no actual xcodebuild download/import is called.
  success = Open3.capture3(RbConfig.ruby, "-e", "exit 0").last
  failure = Open3.capture3(RbConfig.ruby, "-e", "exit 65").last
  runtime = { "id" => "runtime-tvos-18.5", "environment" => { "os" => "18.5", "platform" => "tvOS Simulator" } }
  unavailable = { failure: true, output: "tvOS 18.5 (arm64Only) is not available for download.\n" }
  runtime_runner = RuntimeProvisioningFixture.new(repo, [{}, {}], success, failure)
  runtime_runner.provision_runtime!(runtime)
  calls = runtime_runner.calls
  assert(calls.length == 2 && calls.first.take(7) == %w[xcodebuild -downloadPlatform tvOS -buildVersion 18.5 -architectureVariant arm64], "Runtime version not pinned")
  assert(!File.exist?(calls.first.last), "Runtime download not cleaned up")
  runtime_runner.provision_runtime!(runtime)
  assert(calls.length == 2, "Installed runtime downloaded again")
  fallback = RuntimeProvisioningFixture.new(repo, [unavailable, {}, {}], success, failure)
  fallback.provision_runtime!(runtime)
  downloads = fallback.calls.select { |call| call.include?("-downloadPlatform") }
  assert(downloads.map { |call| call.take(7) } == %w[arm64 universal].map { |variant|
    ["xcodebuild", "-downloadPlatform", "tvOS", "-buildVersion", "18.5", "-architectureVariant", variant]
  }, "Fallback changed the OS version/platform or was not bounded")
  assert(downloads.map(&:last).uniq.length == 2 && downloads.none? { |call| File.exist?(call.last) }, "Fallback reused or leaked a download directory")
  assert(fallback.identifiers == ["com.apple.CoreSimulator.SimRuntime.tvOS-18-5"] * 2, "Exact runtime identifier not verified")
  # Cover every policy runtime, including Apple's visionOS download name vs
  # CoreSimulator's xrOS identifier. These are command fixtures, not OS tests.
  JSON.parse(File.read(File.join(source, "docs/contracts/release-evidence-policy.json"))).fetch("checks").each do |check|
    info = ReleaseRuntimeCatalog.runtime_info(check)
    next unless info
    platform, version = check.fetch("id").delete_prefix("runtime-").split("-", 2)
    platform = { "ios" => "iOS", "tvos" => "tvOS", "watchos" => "watchOS", "visionos" => "visionOS" }.fetch(platform)
    response = { failure: true, output: "#{platform} #{version} (arm64Only) is not available for download.\n" }
    mapped = RuntimeProvisioningFixture.new(repo, [response, {}, {}], success, failure)
    mapped.provision_runtime!(check)
    assert(mapped.calls[1].take(7) == ["xcodebuild", "-downloadPlatform", platform, "-buildVersion", version, "-architectureVariant", "universal"], "Runtime fallback mapping drifted")
    assert(mapped.identifiers == [info.first] * 2, "Runtime identifier drifted")
  end

  ["Network unavailable", "iOS 18.5 (arm64Only) is not available for download.",
    "tvOS 27.0 (arm64Only) is not available for download.",
    "tvOS 18.5 (universal) is not available for download."].each do |output|
    rejected = RuntimeProvisioningFixture.new(repo, [{ failure: true, output: output }], success, failure)
    rejects("Runtime download failed") { rejected.provision_runtime!(runtime) }
    assert(rejected.calls.length == 1 && !File.exist?(rejected.calls.first.last), "Unrelated failure retried or leaked files")
  end
  rejected = RuntimeProvisioningFixture.new(repo, [unavailable, unavailable], success, failure)
  rejects("(universal)") { rejected.provision_runtime!(runtime) }
  assert(rejected.calls.length == 2, "Unavailable universal retried again or imported")
  [{ failure: true }, { available: false }].each do |response|
    rejected = RuntimeProvisioningFixture.new(repo, [{}, response], success, failure)
    rejects(response[:failure] ? "Runtime import failed" : "Exact runtime unavailable") { rejected.provision_runtime!(runtime) }
    assert(rejected.calls.length == 2 && !File.exist?(rejected.calls.first.last), "Import failure retried or leaked download")
  end
  { missing: "exactly one", multiple: "exactly one", symlink: "symlink", directory: "Unsafe runtime image" }.each do |kind, message|
    rejected = RuntimeProvisioningFixture.new(repo, [{ image: kind }], success, failure)
    rejects(message) { rejected.provision_runtime!(runtime) }
    assert(rejected.calls.length == 1, "Unsafe image imported")
  end

  # A rejected local invocation must not write even setup diagnostics.
  early = File.join(fixture, "early-failure")
  ENV["GITHUB_ACTIONS"] = "false"
  rejects("CI-only") { runner.execute("first-check", early) }
  assert(!File.exist?("#{early}-provisioning"), "Local invocation wrote diagnostics")
  ENV["GITHUB_ACTIONS"] = "true"
  ENV["DEVELOPER_DIR"] = "deliberately-wrong-xcode"
  rejects("Unexpected selected Xcode") { runner.execute("first-check", early) }
  log = File.read("#{early}-provisioning/provisioning.log")
  assert(log.include?(sha) && log.include?("first-check") && log.include?("Unexpected selected Xcode"), "Early failure lost metadata/error")
  assert(!File.exist?(early), "Setup failure produced a success evidence directory")
  rejects("File exists") { runner.execute("first-check", early) }
  rejects("outside checkout") { runner.execute("first-check", File.join(repo, "early")) }

  # Exercise real streaming/exit status using a harmless child process; never
  # fake hosted state around production downloads or preflight execution.
  streamed = File.join(fixture, "streamed")
  ENV["INNOFLOW_FIXTURE_SECRET"] = "must-not-appear-in-log"
  rejects("stream failure") do
    runner.with_provisioning_diagnostics("first-check", streamed) do
      result = runner.run_provisioning(RbConfig.ruby, "-e", '$stdout.sync = true; puts "stdout-marker"; warn "stderr-marker"; exit 65')
      assert(!result.success? && result.exitstatus == 65, "Streaming lost child exit status")
      raise "stream failure"
    end
  end
  ENV.delete("INNOFLOW_FIXTURE_SECRET")
  log = File.read("#{streamed}-provisioning/provisioning.log")
  assert(%w[stdout-marker stderr-marker stream\ failure].all? { |text| log.include?(text) }, "Streaming failure lost diagnostics")
  assert(!log.include?("must-not-appear-in-log"), "Diagnostics dumped unrestricted environment")
  assert(!File.exist?(streamed), "Diagnostics mixed with verified receipts")
end
puts "[hosted-release-preflight-selftest] 32-check mapping, hosted/main/SHA guards, immutable receipt merge, adversarial evidence, exact-version bounded runtime fallback and durable early diagnostics passed"
