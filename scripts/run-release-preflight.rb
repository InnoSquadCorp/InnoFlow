#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "pathname"
require "securerandom"
require "shellwords"
require "time"

ROOT = File.realpath(File.expand_path("..", __dir__))
LOCAL_STAGE = "local-preflight"

def abort_preflight(message)
  abort "[release-preflight] #{message}"
end

def capture!(*command, env: {})
  output, error, status = Open3.capture3(env, *command, chdir: ROOT)
  abort_preflight("#{command.join(' ')} failed: #{error.strip}") unless status.success?
  output
end

def inside?(parent, child)
  child == parent || child.start_with?(parent + File::SEPARATOR)
end

def catalog(check, raw, derived, destination = nil)
  id = check.fetch("id")
  case id
  when "static-format"
    %w[swift format lint --strict --recursive Sources Tests Examples]
  when "static-innoflow-diff"
    %w[git diff --check]
  when "static-principle", "doc-swift-syntax", "doc-copyable-examples", "coverage", "full-principle", "catalyst-macro-consumer", "migration-consumer"
    [check.fetch("commandContract").fetch("executable"), *check.fetch("commandContract").fetch("exactArguments")]
  when "tsan-focused", "asan-focused"
    sanitizer = id.start_with?("tsan") ? "thread" : "address"
    %w[swift test --jobs 1 --no-parallel -Xswiftc -warnings-as-errors] +
      ["--sanitize=#{sanitizer}", "--filter", "EffectRunSchedulerTests|FlowScopeTests|DispatchDiagnosticsTests|OutputCasePathTests"]
  when "external-macro-consumer"
    %w[swift test --jobs 1 --no-parallel -Xswiftc -warnings-as-errors --filter CompileContractTests]
  when "swift-6.3-toolchain", "swift-6.4-toolchain"
    ["scripts/run-swift-toolchain-evidence.sh", "--expected-prefix", id.include?("6.3") ? "6.3" : "6.4",
      "--", "swift", "test", "--jobs", "1", "--no-parallel", "-Xswiftc", "-warnings-as-errors"]
  when "sample-swift-6.3"
    ["scripts/check-sample-swift63.sh", "--scratch-path", File.join(File.dirname(derived), "SampleBuild")]
  when /^sdk-(macos|ios|tvos|watchos|visionos)$/
    ["scripts/run-sdk-platform-build.sh", "--platform", check.fetch("environment").fetch("platform"),
      "--derived-data", derived, "--result-bundle", raw]
  when /^runtime-(ios|tvos|watchos|visionos)-/
    abort_preflight("Missing destination for #{id}") unless destination
    ["scripts/run-focused-platform-runtime-tests.sh", "--destination", destination,
      "--derived-data", derived, "--result-bundle", raw]
  else
    abort_preflight("No reviewed command catalog entry for required check #{id}")
  end
end

def runtime_info(check)
  id = check.fetch("id")
  return nil unless id.start_with?("runtime-")
  platform = id.split("-")[1]
  version = check.fetch("environment").fetch("os")
  runtime_platform = platform == "visionos" ? "xrOS" : platform
  runtime = "com.apple.CoreSimulator.SimRuntime.#{runtime_platform}-#{version.tr('.', '-')}"
  types = {
    "ios" => %w[com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro],
    "tvos" => %w[com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-4K],
    "watchos" => %w[com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-10-46mm],
    "visionos" => %w[com.apple.CoreSimulator.SimDeviceType.Apple-Vision-Pro-4K com.apple.CoreSimulator.SimDeviceType.Apple-Vision-Pro],
  }
  [runtime, types.fetch(platform), check.fetch("environment").fetch("platform")]
end

def available_runtime!(check)
  runtime, = runtime_info(check)
  list = JSON.parse(capture!("xcrun", "simctl", "list", "runtimes", "-j"))
  abort_preflight("Required simulator runtime is unavailable: #{runtime}") unless
    list.fetch("runtimes").any? { |entry| entry["identifier"] == runtime && entry["isAvailable"] }
  runtime
end

def toolchain_identity(check)
  env = %w[swift-6.3-toolchain sample-swift-6.3].include?(check.fetch("id")) ? {
    "TOOLCHAINS" => "org.swift.633202606251a",
    "SDKROOT" => "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk",
  } : {}
  swift = capture!("swift", "--version", env: env).lines.first.to_s.strip
  expected = check.dig("environment", "swift")
  abort_preflight("Swift #{expected} toolchain is unavailable: #{swift}") if expected && !swift.match?(/\bversion #{Regexp.escape(expected)}(?:\.|\b)/)
  xcode = capture!("xcodebuild", "-version").lines.map(&:strip).join("/")
  ["#{swift}; #{xcode}; #{RUBY_PLATFORM}", env]
end

def snapshot!(policy, evidence, clean:)
  status = capture!("git", "status", "--porcelain=v1", "--untracked-files=all")
  abort_preflight("A clean isolated candidate is required for execute/resume") if clean && !status.empty?
  snapshot = File.join(evidence, "candidate.json")
  generated = capture!("scripts/release-candidate-snapshot.rb", "--repository", "innoflow=#{ROOT}", "--policy", policy)
  if File.exist?(snapshot)
    abort_preflight("Candidate snapshot changed; start a new evidence root") unless File.binread(snapshot) == generated
  else
    File.write(snapshot, generated)
  end
  [snapshot, JSON.parse(generated).fetch("aggregateDigest")]
end

def check_receipt?(check, policy, evidence, snapshot, candidate, toolchain)
  id = check.fetch("id")
  manifest = File.join(evidence, "manifest.tsv")
  return false unless File.file?(manifest) && File.file?(File.join(evidence, "attempts.tsv"))
  row = File.readlines(manifest, chomp: true).find { |line| line.start_with?("#{id}\t") }
  return false unless row
  fields = row.split("\t", -1)
  return false unless fields.length == 4 && fields[1] == "PASS" && fields[2] == candidate
  relative = Pathname.new(fields[3]).cleanpath
  return false if relative.absolute? || relative.to_s == ".." || relative.to_s.start_with?("../")
  receipt_path = File.join(evidence, relative.to_s)
  return false if File.symlink?(receipt_path) || !inside?(evidence, File.realpath(receipt_path))
  receipt = JSON.parse(File.read(receipt_path))
  return false unless receipt["toolchain"] == toolchain
  _output, _error, status = Open3.capture3(
    File.join(ROOT, "scripts/release-evidence-tool.rb"), "verify", "--policy", policy,
    "--stage", LOCAL_STAGE, "--only-check-id", id, "--candidate", candidate,
    "--candidate-snapshot", snapshot, "--evidence-root", evidence,
    "--manifest", manifest, "--attempt-index", "attempts.tsv", chdir: ROOT
  )
  status.success?
rescue JSON::ParserError, Errno::ENOENT, KeyError, ArgumentError
  false
end

def preflight_environment!(checks, evidence)
  heavy = checks.any? do |check|
    %w[build tests swift-tests].include?(check.fetch("profile")) ||
      %w[coverage migration-consumer catalyst-macro-consumer].include?(check["id"])
  end
  available_kib = capture!("df", "-Pk", evidence).lines.last.to_s.split.fetch(3).to_i
  minimum_kib = heavy ? 10 * 1024 * 1024 : 1024 * 1024
  abort_preflight("Insufficient free space: #{available_kib / 1024} MiB; minimum #{minimum_kib / 1024} MiB") if available_kib < minimum_kib
  sdk_output = capture!("xcodebuild", "-showsdks") if checks.any? { |check| check["id"].start_with?("sdk-") }
  sdk_names = { "macos" => "macosx", "ios" => "iphoneos", "tvos" => "appletvos", "watchos" => "watchos", "visionos" => "xros" }
  checks.each do |check|
    toolchain_identity(check)
    if check["id"].start_with?("sdk-")
      token = sdk_names.fetch(check.fetch("id").delete_prefix("sdk-"))
      abort_preflight("Required SDK is unavailable: #{token}") unless sdk_output.include?(token)
    end
    available_runtime!(check) if runtime_info(check)
  end
end

def run_recorder(env, command)
  Open3.popen3(env, *command, chdir: ROOT, pgroup: true) do |input, output, error, waiter|
    input.close
    readers = [Thread.new { output.read }, Thread.new { error.read }]
    previous_handlers = {}
    %w[INT TERM HUP].each do |signal|
      previous_handlers[signal] = Signal.trap(signal) do
        begin
          Process.kill(signal, -waiter.pid)
        rescue Errno::ESRCH
          nil
        end
      end
    end
    begin
      status = waiter.value
      [readers[0].value, readers[1].value, status]
    ensure
      previous_handlers.each { |signal, handler| Signal.trap(signal, handler) }
    end
  end
end

def execute_check(check, policy, evidence, snapshot, candidate, toolchain, env)
  id = check.fetch("id")
  attempt = "#{id}-#{SecureRandom.hex(8)}"
  work = File.join("#{evidence}.work", attempt)
  FileUtils.mkdir_p(work)
  raw = File.join(evidence, "runs", attempt, "raw.xcresult")
  derived = File.join(work, "DerivedData")
  destination = nil
  device_id = nil
  begin
    if runtime_info(check)
      runtime, device_types, platform = runtime_info(check)
      available_runtime!(check)
      device_types.each do |type|
        output, = Open3.capture3("xcrun", "simctl", "create", "InnoFlow-Preflight-#{attempt}", type, runtime)
        device_id = output.strip unless output.strip.empty?
        break if device_id
      end
      abort_preflight("No compatible simulator device type for #{id}") unless device_id
      capture!("xcrun", "simctl", "boot", device_id)
      capture!("xcrun", "simctl", "bootstatus", device_id, "-b")
      destination = "platform=#{platform},id=#{device_id}"
    end
    command = catalog(check, raw, derived, destination)
    recorder = [File.join(ROOT, "scripts/record-release-evidence.sh"),
      "--check-id", id, "--candidate-hash", candidate, "--candidate-snapshot", snapshot,
      "--repository", "innoflow=#{ROOT}", "--component-label", "innoflow",
      "--evidence-root", evidence, "--manifest", "manifest.tsv",
      "--attempt-id", attempt, "--attempt-index", "attempts.tsv",
      "--artifact", "runs/#{attempt}/output.log", "--receipt", "runs/#{attempt}/receipt.json",
      "--toolchain", toolchain, "--environment-json", JSON.generate(check.fetch("environment", {})),
      "--policy", policy]
    recorder += ["--raw-artifact", "runs/#{attempt}/raw.xcresult"] if %w[build tests].include?(check.fetch("profile"))
    recorder += ["--", *command]
    puts "[release-preflight] RUN #{id} attempt=#{attempt}"
    _output, error, status = run_recorder(env, recorder)
    abort_preflight("#{id} failed (attempt #{attempt}): #{error.strip}; see runs/#{attempt}/output.log") unless status.success?
    abort_preflight("#{id} receipt failed independent verification") unless
      check_receipt?(check, policy, evidence, snapshot, candidate, toolchain)
    puts "[release-preflight] PASS #{id} attempt=#{attempt}"
    FileUtils.remove_entry(work)
  ensure
    if device_id
      Open3.capture3("xcrun", "simctl", "shutdown", device_id)
      Open3.capture3("xcrun", "simctl", "delete", device_id)
    end
  end
end

mode = ARGV.shift
abort_preflight("Usage: run-release-preflight.sh plan|execute|resume|report --evidence-root <outside-repo-dir> [--check-id <id>]") unless
  %w[plan execute resume report].include?(mode)
options = { policy: File.join(ROOT, "docs/contracts/release-evidence-policy.json") }
OptionParser.new do |parser|
  parser.on("--evidence-root PATH") { |value| options[:evidence] = value }
  parser.on("--check-id ID") { |value| options[:check_id] = value }
end.parse!(ARGV)
abort_preflight("Unexpected arguments: #{ARGV.join(' ')}") unless ARGV.empty?
abort_preflight("--evidence-root is required") unless options[:evidence]
evidence = File.expand_path(options.fetch(:evidence))
abort_preflight("Evidence must be outside the candidate repository") if inside?(ROOT, evidence)
policy = options.fetch(:policy)
checks = JSON.parse(File.read(policy)).fetch("checks").select do |check|
  check["stage"] == LOCAL_STAGE && check["requirement"] == "required"
end
abort_preflight("Unknown local-preflight check: #{options[:check_id]}") if
  options[:check_id] && checks.none? { |check| check["id"] == options[:check_id] }
checks.select! { |check| check["id"] == options[:check_id] } if options[:check_id]

if mode == "plan"
  checks.each do |check|
    command = catalog(check, "<evidence>/raw.xcresult", "<work>/DerivedData", "platform=#{check.dig('environment', 'platform')},id=<created-device>")
    puts [check.fetch("id"), check.fetch("profile"), JSON.generate(check.fetch("environment", {})), Shellwords.join(command)].join("\t")
  end
  exit
end

abort_preflight("Evidence root does not exist") if mode == "report" && !File.directory?(evidence)
FileUtils.mkdir_p(evidence) unless mode == "report"
abort_preflight("Evidence root must not be a symlink") if File.symlink?(evidence)
evidence = File.realpath(evidence)
abort_preflight("Evidence root resolves inside candidate repository") if inside?(ROOT, evidence)
  if mode == "report"
    snapshot = File.join(evidence, "candidate.json")
    candidate = File.file?(snapshot) ? JSON.parse(File.read(snapshot)).fetch("aggregateDigest") : nil
    current_candidate = capture!("scripts/release-candidate-snapshot.rb", "--repository", "innoflow=#{ROOT}",
      "--policy", policy, "--digest-only").strip rescue nil
    attempts = File.file?(File.join(evidence, "attempts.tsv")) ? File.readlines(File.join(evidence, "attempts.tsv"), chomp: true) : []
    checks.each do |check|
      id = check.fetch("id")
      relevant = attempts.filter_map do |row|
        fields = row.split("\t", -1)
        next unless fields.length == 5 && fields[1] == id
        relative = Pathname.new(fields[4]).cleanpath
        next if relative.absolute? || relative.to_s == ".." || relative.to_s.start_with?("../")
        receipt = File.join(evidence, relative.to_s)
        next unless File.file?(receipt) && !File.symlink?(receipt)
        JSON.parse(File.read(receipt))
      end
      current_toolchain = toolchain_identity(check).first rescue nil
      valid = candidate && candidate == current_candidate && current_toolchain &&
        check_receipt?(check, policy, evidence, snapshot, candidate, current_toolchain)
      seconds = relevant.sum do |entry|
        Time.iso8601(entry.fetch("finishedAt")) - Time.iso8601(entry.fetch("startedAt"))
      end
      state = if valid
        "PASS_VERIFIED"
      elsif candidate && current_candidate != candidate
        "STALE_CANDIDATE"
      else
        relevant.empty? ? "MISSING" : "FAILED_OR_STALE"
      end
      puts [id, state,
        "attempts=#{relevant.length}", "seconds=#{seconds.to_i}",
        "artifacts=#{relevant.filter_map { |entry| entry.dig('artifact', 'path') }.join(',')}"].join("\t")
    end
    exit
end

lock = File.join(evidence, ".runner.lock")
abort_preflight("Runner lock is a symlink") if File.symlink?(lock)
File.open(lock, File::RDWR | File::CREAT, 0o600) do |file|
  abort_preflight("Another preflight runner owns this evidence root") unless file.flock(File::LOCK_EX | File::LOCK_NB)
  snapshot, candidate = snapshot!(policy, evidence, clean: true)
  preflight_environment!(checks, evidence)
  checks.each do |check|
    toolchain, env = toolchain_identity(check)
    if mode == "resume"
      if check_receipt?(check, policy, evidence, snapshot, candidate, toolchain)
        puts "[release-preflight] REUSED #{check.fetch('id')}"
        next
      end
      manifest = File.join(evidence, "manifest.tsv")
      if File.file?(manifest) && File.readlines(manifest).any? { |row| row.start_with?("#{check.fetch('id')}\t") }
        abort_preflight("Recorded #{check.fetch('id')} evidence is stale or damaged; preserve it and start a new evidence root")
      end
    end
    execute_check(check, policy, evidence, snapshot, candidate, toolchain, env)
  end
  if options[:check_id].nil?
    puts capture!("scripts/verify-release-evidence.sh", "--candidate-hash", candidate,
      "--candidate-snapshot", snapshot, "--evidence-root", evidence, "--manifest", "manifest.tsv", "--policy", policy).strip
  end
end
