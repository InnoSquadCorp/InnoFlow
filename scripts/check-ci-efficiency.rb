#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"

def check(condition, message)
  abort "[ci-efficiency] #{message}" unless condition
end

root = ARGV.fetch(0, File.expand_path("..", __dir__))
workflow_dir = File.join(root, ".github", "workflows")
load_yaml = ->(path) { YAML.safe_load(File.read(path), aliases: false) }

ci = load_yaml.call(File.join(workflow_dir, "ci.yml"))
ci_trigger = ci["on"] || ci[true]
pull_request_types = Array(ci_trigger.dig("pull_request", "types"))
check(!pull_request_types.include?("labeled"), "full CI must not restart for label events")
check(ci.dig("concurrency", "cancel-in-progress") == true,
  "full CI must cancel superseded runs")
check(ci.dig("concurrency", "group").to_s.include?("github.event.pull_request.number"),
  "full CI concurrency must be scoped to a pull request or ref")

jobs = ci.fetch("jobs")
principle = jobs.fetch("principle-gates")
check(Array(principle["needs"]).include?("coverage"),
  "static principle gates must retain the coverage dependency")
principle_runs = principle.fetch("steps").filter_map { |step| step["run"] }
check(principle_runs.any? { |run| run.include?("principle-gates.sh\" --static") },
  "CI principle gates must use the build-free static mode")
check(principle_runs.include?("$GITHUB_WORKSPACE/scripts/principle-gates-selftest.sh"),
  "CI must retain gate negative controls")

release = jobs.fetch("release-tests")
check(Array(release["needs"]) == ["lint"],
  "Release tests must start after lint without waiting for Debug tests")
check(release.fetch("steps").any? { |step| step["run"] == "$GITHUB_WORKSPACE/scripts/check-release-configuration.sh" },
  "Release tests must execute the Release-only configuration gate")

check(Array(jobs.fetch("sample-build")["needs"]) == ["lint"],
  "canonical sample build must not wait for the full validation graph")
check(jobs.fetch("address-sanitizer")["if"] == "github.event_name == 'push'",
  "full CI must reserve AddressSanitizer for branch pushes")

asan = load_yaml.call(File.join(workflow_dir, "asan.yml"))
asan_trigger = asan["on"] || asan[true]
check(Array(asan_trigger.dig("pull_request", "types")) == ["labeled"],
  "pull-request AddressSanitizer must be label-triggered")
asan_job = asan.fetch("jobs").fetch("address-sanitizer")
check(asan_job["if"] == "github.event.label.name == 'run-asan'",
  "only the run-asan label may start pull-request AddressSanitizer")
check(asan.dig("concurrency", "cancel-in-progress") == true,
  "pull-request AddressSanitizer must cancel superseded runs")

cd = load_yaml.call(File.join(workflow_dir, "cd.yml"))
release_gate_runs = cd.fetch("jobs").fetch("release-gate").fetch("steps").filter_map { |step| step["run"] }
check(release_gate_runs.any? { |run| run.include?("principle-gates.sh\" --static") },
  "release workflow must avoid repeating the Debug and sample suites inside principle gates")
check(release_gate_runs.include?("$GITHUB_WORKSPACE/scripts/check-release-configuration.sh"),
  "release workflow must retain Release configuration validation")
check(release_gate_runs.include?("$GITHUB_WORKSPACE/scripts/principle-gates-selftest.sh"),
  "release workflow must retain gate negative controls")

dependabot = load_yaml.call(File.join(root, ".github", "dependabot.yml"))
updates = dependabot.fetch("updates")
%w[github-actions swift].each do |ecosystem|
  update = updates.find { |entry| entry["package-ecosystem"] == ecosystem }
  groups = update&.fetch("groups", {}) || {}
  check(groups.values.any? { |group| Array(group["patterns"]).include?("*") },
    "Dependabot #{ecosystem} updates must be grouped")
end

puts "[ci-efficiency] Trigger, dependency and duplicate-work contracts passed"
