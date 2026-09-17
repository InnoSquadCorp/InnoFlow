#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ruby - "$ROOT_DIR" "$SCRIPT_DIR/check-ci-efficiency.rb" <<'RUBY'
require "tmpdir"
require "fileutils"
require "open3"
require "yaml"

source, checker = ARGV
Dir.mktmpdir("innoflow-ci-efficiency") do |root|
  FileUtils.mkdir_p(File.join(root, ".github", "workflows"))
  copy = lambda do
    FileUtils.cp(Dir.glob(File.join(source, ".github", "workflows", "*.yml")), File.join(root, ".github", "workflows"))
    FileUtils.cp(File.join(source, ".github", "dependabot.yml"), File.join(root, ".github"))
  end
  run = -> { Open3.capture3("ruby", checker, root).last.success? }
  mutate = lambda do |relative, &block|
    path = File.join(root, relative)
    document = YAML.safe_load(File.read(path), aliases: false)
    block.call(document)
    File.write(path, YAML.dump(document))
  end

  copy.call
  abort "Valid CI efficiency configuration rejected" unless run.call

  mutations = {
    "label restarts full CI" => [".github/workflows/ci.yml", ->(doc) { (doc["on"] || doc[true])["pull_request"]["types"] << "labeled" }],
    "stale runs survive" => [".github/workflows/ci.yml", ->(doc) { doc["concurrency"]["cancel-in-progress"] = false }],
    "full principle gate repeats tests" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["principle-gates"]["steps"].find { |step| step["run"].to_s.include?("principle-gates.sh") }["run"] = "scripts/principle-gates.sh" }],
    "Release waits for Debug" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["release-tests"]["needs"] = ["lint", "tests"] }],
    "sample build is serialized" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["sample-build"]["needs"] = "principle-gates" }],
    "ASan accepts every label" => [".github/workflows/asan.yml", ->(doc) { doc["jobs"]["address-sanitizer"].delete("if") }],
    "Dependabot fan-out" => [".github/dependabot.yml", ->(doc) { doc["updates"].first.delete("groups") }],
  }
  mutations.each do |name, (relative, mutation)|
    copy.call
    mutate.call(relative, &mutation)
    abort "Mutation passed: #{name}" if run.call
  end
end
puts "[ci-efficiency-selftest] All negative controls passed"
RUBY
