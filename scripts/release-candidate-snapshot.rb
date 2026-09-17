#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "pathname"

def abort_usage
  warn "Usage: release-candidate-snapshot.rb --repository <label=path> [--repository <label=path> ...] --policy <json> [--digest-only]"
  exit 64
end

repositories = []
policy_path = nil
digest_only = false
arguments = ARGV.dup
until arguments.empty?
  case arguments.shift
  when "--repository"
    value = arguments.shift or abort_usage
    label, path = value.split("=", 2)
    abort_usage if label.nil? || label.empty? || path.nil? || path.empty?
    repositories << [label, File.realpath(path)]
  when "--policy"
    policy_path = arguments.shift or abort_usage
  when "--digest-only"
    digest_only = true
  else
    abort_usage
  end
end
abort_usage if repositories.empty? || policy_path.nil?
abort "Duplicate repository labels" unless repositories.map(&:first).uniq.length == repositories.length
abort "Release evidence policy is missing: #{policy_path}" unless File.file?(policy_path)

def git(root, *arguments, allow_failure: false)
  output, error, status = Open3.capture3("git", "-C", root, *arguments)
  abort(error.empty? ? "git #{arguments.join(" ")} failed" : error) unless status.success? || allow_failure
  [output, status]
end

def repository_files(root)
  tracked, = git(root, "ls-files", "--cached", "-z")
  untracked, = git(root, "ls-files", "--others", "--exclude-standard", "-z")
  generated_prefixes = %w[Derived/ InnoFlow.xcodeproj/]
  (tracked.split("\0") + untracked.split("\0")).reject(&:empty?).uniq.sort.reject do |relative|
    generated_prefixes.any? { |prefix| relative.start_with?(prefix) }
  end
end

def file_entry(root, relative)
  absolute = File.join(root, relative)
  stat = File.lstat(absolute)
  if stat.symlink?
    contents = File.readlink(absolute)
    kind = "symlink"
  elsif stat.file?
    contents = File.binread(absolute)
    kind = "file"
  else
    abort "Unsupported release candidate input: #{relative}"
  end
  {
    "path" => relative,
    "kind" => kind,
    "mode" => format("%04o", stat.mode & 0o7777),
    "sha256" => Digest::SHA256.hexdigest(contents),
  }
rescue Errno::ENOENT
  { "path" => relative, "kind" => "deleted", "mode" => nil, "sha256" => nil }
end

components = repositories.sort_by(&:first).map do |label, root|
  head, = git(root, "rev-parse", "HEAD")
  status, = git(root, "status", "--porcelain=v1", "-z")
  files = repository_files(root).map { |relative| file_entry(root, relative) }
  abort "Release candidate contains no source files in #{label}" if files.empty?
  digest_input = files.map { |entry| JSON.generate(entry) }.join("\n") + "\n"
  {
    "label" => label,
    "headRevision" => head.strip,
    "dirty" => !status.empty?,
    "contentDigest" => Digest::SHA256.hexdigest(digest_input),
    "files" => files,
  }
end

policy = JSON.parse(File.read(policy_path))
abort "Unsupported release evidence policy schema" unless policy["schema"] == "inno-flow-release-evidence-policy-v3"
policy_digest = Digest::SHA256.hexdigest(JSON.generate(policy))
aggregate_input = components.map { |component| "#{component.fetch("label")}\t#{component.fetch("contentDigest")}" }
aggregate_input << "policy\t#{policy_digest}"
aggregate_digest = Digest::SHA256.hexdigest(aggregate_input.join("\n") + "\n")
snapshot = {
  "schema" => "inno-flow-release-candidate-v2",
  "aggregateDigest" => aggregate_digest,
  "policyDigest" => policy_digest,
  "components" => components,
}

if digest_only
  puts aggregate_digest
else
  puts JSON.pretty_generate(snapshot)
end
