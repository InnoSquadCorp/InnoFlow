#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"

def check(condition, message)
  abort "[coverage-workflow] #{message}" unless condition
end

directory = ARGV.fetch(0, File.expand_path("../.github/workflows", __dir__))
documents = Dir.glob(File.join(directory, "*.{yml,yaml}")).to_h do |path|
  [File.basename(path), YAML.safe_load(File.read(path), aliases: false)]
end

# InnoRouter's release fix: reusable workflows inherit the caller's workflow
# name, so every callee needs its own literal concurrency namespace.
prefixes = []
documents.each do |name, document|
  trigger = document["on"] || document[true]
  next unless trigger.is_a?(Hash) && trigger.key?("workflow_call")
  group = document.dig("concurrency", "group")
  check(group.is_a?(String), "#{name}: missing reusable concurrency group")
  prefix = group.split("${{", 2).first.to_s.strip
  check(!prefix.empty? && !prefixes.include?(prefix), "#{name}: reusable concurrency namespace collides")
  prefixes << prefix
end

coverage = documents.fetch("coverage.yml")
check(coverage.dig("permissions", "contents") == "read", "coverage must have read-only contents")
job = coverage.fetch("jobs").fetch("coverage")
check(!job.key?("if") && !job.key?("continue-on-error"), "coverage job cannot be optional")
steps = job.fetch("steps")
check(steps.none? { |step| step.key?("continue-on-error") }, "coverage steps cannot ignore failures")
run = steps.select { |step| step["run"] == "scripts/run-coverage.sh" }
check(run.one? && !run.first.key?("if"), "coverage runner must execute exactly once unconditionally")
check(steps.any? { |step| step["run"] == "PYTHONDONTWRITEBYTECODE=1 python3 scripts/coverage-selftest.py" && !step.key?("if") }, "missing coverage negative controls")
uploads = steps.select { |step| step["uses"].to_s.start_with?("actions/upload-artifact@") }
check(uploads.one? && uploads.first["if"] == "always()" &&
  uploads.first.dig("with", "if-no-files-found") == "error" &&
  uploads.first.dig("with", "path") == ".build/coverage/", "coverage evidence must be retained even after failure")

[["ci.yml", "coverage", "principle-gates"], ["cd.yml", "release-coverage", "release-evidence"]].each do |file, name, dependent|
  jobs = documents.fetch(file).fetch("jobs")
  caller = jobs.fetch(name)
  check(caller["uses"] == "./.github/workflows/coverage.yml", "#{file}: coverage callee changed")
  check(!caller.key?("continue-on-error"), "#{file}: coverage caller cannot ignore failures")
  expected_condition = file == "cd.yml" ? "startsWith(github.ref, 'refs/tags/')" : nil
  check(caller["if"] == expected_condition, "#{file}: coverage caller condition changed")
  check(Array(jobs.fetch(dependent)["needs"]).include?(name), "#{file}: #{dependent} must require coverage")
end
puts "[coverage-workflow] CI, release dependencies and reusable namespaces passed"
