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
api_runs = jobs.fetch("api-compatibility").fetch("steps").filter_map { |step| step["run"] }
check(api_runs.include?('"$GITHUB_WORKSPACE/scripts/check-migration-consumer.sh"'),
  "CI must run the exact 5.1.1 to 6.0 external migration consumer")
principle = jobs.fetch("principle-gates")
check(Array(principle["needs"]).include?("coverage"),
  "static principle gates must retain the coverage dependency")
principle_runs = principle.fetch("steps").filter_map { |step| step["run"] }
check(principle_runs.any? { |run| run.include?("principle-gates.sh\" --static") },
  "CI principle gates must use the build-free static mode")
check(principle_runs.include?('"$GITHUB_WORKSPACE/scripts/principle-gates-selftest.sh"'),
  "CI must retain gate negative controls")

release = jobs.fetch("release-tests")
check(Array(release["needs"]) == ["lint"],
  "Release tests must start after lint without waiting for Debug tests")
check(release.fetch("steps").any? { |step| step["run"] == '"$GITHUB_WORKSPACE/scripts/check-release-configuration.sh"' },
  "Release tests must execute the Release-only configuration gate")

check(Array(jobs.fetch("sample-build")["needs"]) == ["lint"],
  "canonical sample build must not wait for the full validation graph")
check(jobs.fetch("address-sanitizer")["if"] == "github.event_name == 'push'",
  "full CI must reserve AddressSanitizer for branch pushes")

asan = load_yaml.call(File.join(workflow_dir, "asan.yml"))
asan_trigger = asan["on"] || asan[true]
check(Array(asan_trigger.dig("pull_request", "types")).sort == %w[labeled opened reopened synchronize].sort,
  "pull-request AddressSanitizer must follow label selection and subsequent PR revisions")
asan_job = asan.fetch("jobs").fetch("address-sanitizer")
asan_if = asan_job["if"].to_s
check(asan_if.include?("contains(github.event.pull_request.labels.*.name, 'run-asan')") &&
      asan_if.include?("github.event.action != 'labeled'") &&
      asan_if.include?("github.event.label.name == 'run-asan'"),
  "only selected PR revisions or the run-asan label event may start AddressSanitizer")
check(asan["concurrency"].nil?,
  "non-running label events must not enter the AddressSanitizer concurrency group")
check(asan_job.dig("concurrency", "cancel-in-progress") == true &&
      asan_job.dig("concurrency", "group").to_s.include?("github.event.pull_request.number"),
  "eligible pull-request AddressSanitizer jobs must cancel only superseded runs for the same PR")

required_job_names = %w[
  coverage lint tests release-tests api-compatibility thread-sanitizer
  sample-tests package-builds focused-runtime-tests principle-gates
  sample-package-builds sample-build address-sanitizer sample-ui-tests
]
final_gate = jobs.fetch("ci-required")
check((jobs.keys - ["ci-required"]).sort == required_job_names.sort,
  "CI Required inventory must classify every non-aggregate CI job")
check(final_gate["name"] == "CI Required" && final_gate["if"] == "always()",
  "CI Required must be a stable fail-closed aggregate job")
check(Array(final_gate["needs"]).sort == required_job_names.sort,
  "CI Required dependencies must match every mandatory CI job")
check(!final_gate.key?("continue-on-error"),
  "CI Required must not ignore failures")
final_steps = final_gate.fetch("steps")
check(final_steps.none? { |step| step.key?("continue-on-error") },
  "CI Required steps must not ignore failures")
checker_steps = final_steps.select { |step| step["run"].to_s.include?("check-required-ci-results.rb") }
check(checker_steps.length == 1 && checker_steps.first.equal?(final_steps.last),
  "CI Required must execute exactly one result verifier as its final step")
checker_step = checker_steps.first
check(checker_step["if"].nil?,
  "CI Required result verifier must not have a step-level condition")
expected_result_lines = [
  "set -euo pipefail",
  'ruby "$GITHUB_WORKSPACE/scripts/check-required-ci-results.rb" \\',
  '"${{ github.event_name }}" \\',
]
required_job_names.each_with_index do |name, index|
  continuation = index == required_job_names.length - 1 ? "" : " \\"
  expected_result_lines << "\"#{name}=${{ needs.#{name}.result }}\"#{continuation}"
end
actual_result_lines = checker_step.fetch("run").lines.map(&:strip).reject(&:empty?)
check(actual_result_lines == expected_result_lines,
  "CI Required result verifier command must match the fail-closed canonical form")

cd = load_yaml.call(File.join(workflow_dir, "cd.yml"))
release_gate_runs = cd.fetch("jobs").fetch("release-gate").fetch("steps").filter_map { |step| step["run"] }
check(release_gate_runs.include?('"$GITHUB_WORKSPACE/scripts/check-migration-consumer.sh"'),
  "tag Release Gate must rerun the previous-stable migration consumer")
check(release_gate_runs.any? { |run| run.include?("principle-gates.sh\" --static") },
  "release workflow must avoid repeating the Debug and sample suites inside principle gates")
check(release_gate_runs.include?('"$GITHUB_WORKSPACE/scripts/check-release-configuration.sh"'),
  "release workflow must retain Release configuration validation")
check(release_gate_runs.include?('"$GITHUB_WORKSPACE/scripts/principle-gates-selftest.sh"'),
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
