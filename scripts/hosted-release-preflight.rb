#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "find"
require "json"
require "open3"
require "optparse"
require "tmpdir"
require_relative "release-runtime-catalog"
require_relative "release-evidence-archive"

# Isolate each check to avoid accumulating eight runtime images and all SDK /
# sanitizer build products on one ephemeral Mac. Aggregate only unchanged bytes.
class HostedReleasePreflight
  MANIFEST_HEADER = "check_id\tstatus\tcandidate_hash\treceipt_path"
  ATTEMPT_HEADER = "attempt_id\tcheck_id\tstatus\tcandidate_hash\tattempt_receipt_path"

  def initialize(root)
    @root = File.realpath(root)
    @policy = File.join(@root, "docs/contracts/release-evidence-policy.json")
    @checks = JSON.parse(File.read(@policy)).fetch("checks").select do |check|
      check["stage"] == "local-preflight" && check["requirement"] == "required"
    end
    ids = @checks.map { |check| check.fetch("id") }
    raise "Invalid check inventory" if ids.empty? || ids.uniq != ids || ids.any? { |id| !id.match?(/\A[a-z0-9.-]+\z/) }
  end

  def matrix
    { "include" => @checks.map do |check|
      minimum = %w[swift-6.3-toolchain sample-swift-6.3].include?(check.fetch("id"))
      { "check" => check.fetch("id"), "runner" => minimum ? "macos-26" : "xcode-27",
        "xcode" => minimum ? "26.6" : "27.0", "swift" => minimum ? "6.3" : "6.4" }
    end }
  end

  def capture!(*command)
    output, error, status = Open3.capture3(*command, chdir: @root)
    raise "#{command.join(' ')} failed: #{error.strip}" unless status.success?
    output
  end

  def run!(*command)
    raise "Command failed: #{command.join(' ')}" unless system(*command, chdir: @root)
  end

  def hosted!
    raise "Execution is GitHub-hosted CI-only" unless ENV["GITHUB_ACTIONS"] == "true" && ENV["RUNNER_ENVIRONMENT"] == "github-hosted"
    raise "Only exact main candidates are accepted" unless ENV["GITHUB_REF"] == "refs/heads/main" &&
      ENV["GITHUB_SHA"] == capture!("git", "rev-parse", "HEAD").strip
    raise "Candidate must be clean" unless capture!("git", "status", "--porcelain=v1", "--untracked-files=all").empty?
  end

  def runtime_available?(identifier)
    JSON.parse(capture!("xcrun", "simctl", "list", "runtimes", "-j")).fetch("runtimes").any? do |runtime|
      runtime["identifier"] == identifier && runtime["isAvailable"] == true
    end
  end

  def provision_runtime!(check)
    info = ReleaseRuntimeCatalog.runtime_info(check)
    return unless info
    identifier = info.first
    return if runtime_available?(identifier)
    platform, version = check.fetch("id").delete_prefix("runtime-").split("-", 2)
    platform = { "ios" => "iOS", "tvos" => "tvOS", "watchos" => "watchOS", "visionos" => "visionOS" }.fetch(platform)
    # Apple supplies the exact version, never an unpinned latest runtime. Only
    # this task-owned download directory is removed after import finishes.
    Dir.mktmpdir("innoflow-runtime-", ENV.fetch("RUNNER_TEMP")) do |download|
      run!("xcodebuild", "-downloadPlatform", platform, "-buildVersion", version,
        "-architectureVariant", "arm64", "-exportPath", download)
      images = Dir.glob(File.join(download, "**", "*.dmg"))
      raise "Expected exactly one #{platform} #{version} image" unless images.one?
      raise "Runtime image is a symlink" if File.symlink?(images.first)
      run!("xcodebuild", "-importPlatform", images.first)
    end
    raise "Exact runtime unavailable after import: #{identifier}" unless runtime_available?(identifier)
  end

  def execute(id, evidence)
    hosted!
    entry = matrix.fetch("include").find { |item| item.fetch("check") == id }
    raise "Unknown check: #{id}" unless entry
    xcode = "/Applications/Xcode_#{entry.fetch('xcode')}.app/Contents/Developer"
    raise "Unexpected selected Xcode" unless ENV["DEVELOPER_DIR"] == xcode && File.directory?(xcode)
    raise "Unexpected Xcode version" unless capture!("xcodebuild", "-version").lines.first.to_s.strip == "Xcode #{entry.fetch('xcode')}"
    swift = capture!("swift", "--version").lines.first.to_s
    raise "Swift #{entry.fetch('swift')} is required: #{swift}" unless swift.match?(/\bversion #{Regexp.escape(entry.fetch('swift'))}(?:\.|\b)/)
    raise "Inherited toolchain/SDK override" unless ENV["TOOLCHAINS"].to_s.empty? && ENV["SDKROOT"].to_s.empty?
    provision_runtime!(@checks.find { |check| check.fetch("id") == id })
    run!(File.join(@root, "scripts/run-release-preflight.sh"), "execute", "--check-id", id, "--evidence-root", evidence)
  end

  def outside!(path)
    expanded = File.expand_path(path)
    resolved = File.exist?(expanded) ? File.realpath(expanded) : File.join(File.realpath(File.dirname(expanded)), File.basename(expanded))
    raise "Evidence must be outside checkout" if resolved == @root || resolved.start_with?(@root + "/")
    raise "Evidence path is a symlink" if File.symlink?(expanded)
    resolved
  end

  def rows!(path, header, columns)
    lines = File.readlines(path, chomp: true)
    raise "Invalid header: #{path}" unless lines.shift == header
    lines.map do |line|
      fields = line.split("\t", -1)
      raise "Malformed evidence row: #{path}" unless fields.length == columns && fields.none?(&:empty?)
      fields
    end
  end

  def merge(shards, evidence)
    hosted!
    shards = outside!(shards)
    evidence = outside!(evidence)
    raise "Evidence root already exists" if File.exist?(evidence)
    raise "Evidence overlaps shard input" if evidence.start_with?(shards + "/") || shards.start_with?(evidence + "/")
    expected = @checks.to_h { |check| ["innoflow-preflight-shard-#{ENV.fetch('GITHUB_SHA')}-#{check.fetch('id')}", check.fetch("id")] }
    raise "Missing or unexpected shard artifacts" unless Dir.children(shards).sort == expected.keys.sort
    Find.find(shards) do |path|
      stat = File.lstat(path)
      raise "Unsafe shard entry: #{path}" unless stat.file? || stat.directory?
    end
    # Artifact transport carries exactly one archive per job so ZIP permission
    # normalization cannot invalidate raw-evidence digests. Decode separately.
    Dir.mktmpdir("innoflow-decoded-", File.dirname(evidence)) do |decoded|
      expected.each_key do |name|
        directory = File.join(shards, name)
        raise "Unexpected shard archive files" unless Dir.children(directory) == ["evidence.tar.gz"]
        ReleaseEvidenceArchive.unpack(File.join(directory, "evidence.tar.gz"), File.join(decoded, name))
      end
      merge_decoded(decoded, evidence, expected)
    end
  end

  def merge_decoded(shards, evidence, expected)
    snapshot = capture!(File.join(@root, "scripts/release-candidate-snapshot.rb"),
      "--repository", "innoflow=#{@root}", "--policy", @policy)
    candidate = JSON.parse(snapshot).fetch("aggregateDigest")
    manifests = []
    attempts = []
    FileUtils.mkdir_p(File.join(evidence, "runs"))
    File.write(File.join(evidence, "candidate.json"), snapshot)
    expected.each do |name, id|
      shard = File.join(shards, name)
      raise "Shard snapshot mismatch: #{id}" unless File.binread(File.join(shard, "candidate.json")) == snapshot
      rows = rows!(File.join(shard, "manifest.tsv"), MANIFEST_HEADER, 4)
      raise "Shard must contain exactly its PASS: #{id}" unless rows.one? && rows.first.take(3) == [id, "PASS", candidate]
      shard_attempts = rows!(File.join(shard, "attempts.tsv"), ATTEMPT_HEADER, 5)
      raise "Unexpected shard attempts: #{id}" unless !shard_attempts.empty? && shard_attempts.all? { |row| row[1] == id && row[3] == candidate }
      manifests.concat(rows)
      attempts.concat(shard_attempts)
      # Preserve relative paths, digests, toolchains and raw receipt bytes.
      %w[runs attempts].each do |collection|
        FileUtils.mkdir_p(File.join(evidence, collection))
        Dir.children(File.join(shard, collection)).each do |entry|
          target = File.join(evidence, collection, entry)
          raise "Colliding evidence entry: #{collection}/#{entry}" if File.exist?(target)
          # Both directories are task-owned on RUNNER_TEMP. Move decoded data
          # without a second full raw-xcresult copy on the hosted disk.
          FileUtils.mv(File.join(shard, collection, entry), target)
        end
      end
    end
    raise "Duplicate attempt IDs" unless attempts.map(&:first).uniq.length == attempts.length
    File.write(File.join(evidence, "manifest.tsv"), ([MANIFEST_HEADER] + manifests.map { |row| row.join("\t") }).join("\n") + "\n")
    File.write(File.join(evidence, "attempts.tsv"), ([ATTEMPT_HEADER] + attempts.map { |row| row.join("\t") }).join("\n") + "\n")
    run!(File.join(@root, "scripts/verify-release-evidence.sh"), "--candidate-hash", candidate,
      "--candidate-snapshot", File.join(evidence, "candidate.json"), "--evidence-root", evidence,
      "--manifest", File.join(evidence, "manifest.tsv"), "--attempt-index", "attempts.tsv", "--policy", @policy,
      "--stage", "local-preflight")
  end
end

if $PROGRAM_NAME == __FILE__
  $stdout.sync = true
  begin
    mode = ARGV.shift
    options = {}
    OptionParser.new do |parser|
      parser.on("--check-id ID") { |value| options[:check] = value }
      parser.on("--shards PATH") { |value| options[:shards] = value }
      parser.on("--evidence-root PATH") { |value| options[:evidence] = value }
    end.parse!(ARGV)
    raise "Unexpected arguments" unless ARGV.empty?
    runner = HostedReleasePreflight.new(File.expand_path("..", __dir__))
    case mode
    when "matrix" then puts JSON.generate(runner.matrix)
    when "execute" then runner.execute(options.fetch(:check), options.fetch(:evidence))
    when "merge" then runner.merge(options.fetch(:shards), options.fetch(:evidence))
    else raise "Usage: hosted-release-preflight.rb matrix|execute|merge [--check-id ID] [--shards PATH] [--evidence-root PATH]"
    end
  rescue StandardError => error
    abort "[hosted-release-preflight] #{error.message}"
  end
end
