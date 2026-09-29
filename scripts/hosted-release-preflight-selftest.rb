#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "hosted-release-preflight"

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

source = File.expand_path("..", __dir__)
matrix = HostedReleasePreflight.new(source).matrix.fetch("include")
assert(matrix.length == 32 && matrix.map { |row| row.fetch("check") }.uniq.length == 32, "Missing required matrix check")
assert(matrix.count { |row| row["runner"] == "macos-26" && row["swift"] == "6.3" && row["xcode"] == "26.6" } == 2, "Wrong minimum toolchain jobs")
assert(matrix.count { |row| row["runner"] == "xcode-27" && row["swift"] == "6.4" && row["xcode"] == "27.0" } == 30, "Wrong current toolchain jobs")

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

  # Runtime command fixture: no actual xcodebuild download/import is called.
  runtime_runner = HostedReleasePreflight.new(repo)
  runtime_runner.instance_variable_set(:@available, false)
  runtime_runner.instance_variable_set(:@calls, [])
  def runtime_runner.runtime_available?(_identifier) = @available
  def runtime_runner.run!(*command)
    @calls << command
    if command.include?("-downloadPlatform")
      File.write(File.join(command.last, "fixture.simruntime.dmg"), "fixture")
    elsif command.include?("-importPlatform")
      @available = true unless @reject_import
    end
  end
  runtime = { "id" => "runtime-tvos-18.5", "environment" => { "os" => "18.5", "platform" => "tvOS Simulator" } }
  runtime_runner.provision_runtime!(runtime)
  calls = runtime_runner.instance_variable_get(:@calls)
  assert(calls.length == 2 && calls.first.take(7) == %w[xcodebuild -downloadPlatform tvOS -buildVersion 18.5 -architectureVariant arm64], "Runtime version not pinned")
  assert(!File.exist?(calls.first.last), "Runtime download not cleaned up")
  runtime_runner.provision_runtime!(runtime)
  assert(calls.length == 2, "Installed runtime downloaded again")
  runtime_runner.instance_variable_set(:@available, false)
  runtime_runner.instance_variable_set(:@reject_import, true)
  rejects("Exact runtime unavailable") { runtime_runner.provision_runtime!(runtime) }
end
puts "[hosted-release-preflight-selftest] 32-check mapping, hosted/main/SHA guards, real receipt merge, immutable bytes, missing/stale/failed/unsafe/tampered evidence, exact runtime provisioning passed"
