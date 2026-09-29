#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ruby - "$SCRIPT_DIR" <<'RUBY'
require "tmpdir"
require "fileutils"
require "open3"
require "yaml"
scripts = ARGV.fetch(0)
Dir.mktmpdir("innoflow-coverage-workflow") do |root|
  original = File.join(scripts, "../.github/workflows")
  mutations = {
    "no floor execution" => ["coverage.yml", ->(doc) { doc["jobs"]["coverage"]["steps"].find { |step| step["run"] == "scripts/run-coverage.sh" }["run"] = "echo scripts/run-coverage.sh" }],
    "conditional execution" => ["coverage.yml", ->(doc) { doc["jobs"]["coverage"]["if"] = "false" }],
    "ignored failure" => ["coverage.yml", ->(doc) { doc["jobs"]["coverage"]["steps"][0]["continue-on-error"] = true }],
    "missing artifact" => ["coverage.yml", ->(doc) { doc["jobs"]["coverage"]["steps"].last["with"]["if-no-files-found"] = "warn" }],
    "no namespace" => ["coverage.yml", ->(doc) { doc["concurrency"]["group"] = '${{ github.workflow }}' }],
    "CI bypass" => ["ci.yml", ->(doc) { doc["jobs"]["principle-gates"]["needs"].delete("coverage") }],
    "release bypass" => ["cd.yml", ->(doc) { doc["jobs"]["release-evidence"]["needs"].delete("release-coverage") }],
    "conditional caller" => ["ci.yml", ->(doc) { doc["jobs"]["coverage"]["if"] = "false" }],
  }
  run = -> { Open3.capture3("ruby", File.join(scripts, "check-coverage-workflow.rb"), root) }
  FileUtils.cp(Dir.glob(File.join(original, "*.yml")), root)
  abort "Valid coverage workflow rejected" unless run.call.last.success?
  mutations.each do |name, (file, mutation)|
    FileUtils.cp(Dir.glob(File.join(original, "*.yml")), root)
    path = File.join(root, file)
    document = YAML.safe_load(File.read(path), aliases: false)
    mutation.call(document)
    File.write(path, YAML.dump(document))
    abort "Mutation passed: #{name}" if run.call.last.success?
  end
  FileUtils.cp(Dir.glob(File.join(original, "*.yml")), root)
  FileUtils.cp(File.join(root, "coverage.yml"), File.join(root, "duplicate.yml"))
  abort "Duplicate reusable concurrency namespace passed" if run.call.last.success?
end
puts "[coverage-workflow-selftest] All negative controls passed"
RUBY
