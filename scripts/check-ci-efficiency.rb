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
check(Array(ci_trigger.dig("pull_request", "types")).sort == %w[opened synchronize reopened labeled unlabeled edited].sort,
  "CI must replan current changes and opt-in labels for every supported PR transition")
%w[push pull_request].each do |event|
  check((ci_trigger.fetch(event).keys & %w[paths paths-ignore]).empty?,
    "#{event}: required CI cannot disappear behind path filters")
end
check(ci_trigger.key?("workflow_dispatch") && ci_trigger.dig("merge_group", "types") == ["checks_requested"],
  "manual recovery and merge queues must produce full CI")
check(ci.dig("concurrency", "cancel-in-progress") == true,
  "CI must cancel superseded runs")
check(ci.dig("concurrency", "group").to_s.include?("github.event.pull_request.number"),
  "CI concurrency must be scoped to a pull request or ref")

jobs = ci.fetch("jobs")
required_job_names = %w[
  ci-plan policy docs-required documentation coverage lint tests release-tests api-compatibility thread-sanitizer
  sample-tests package-builds focused-runtime-tests principle-gates
  sample-package-builds sample-build address-sanitizer sample-ui-tests swift-syntax-compatibility
]
check((jobs.keys - ["ci-required"]).sort == required_job_names.sort,
  "CI Required inventory must classify every non-aggregate CI job")
# Original build/test dependency edges are kept; the planner is added as a
# predecessor so a selected job can never start with incomplete change evidence.
prior_dependencies = {
  "documentation" => [], "coverage" => [], "lint" => [],
  "tests" => ["lint"], "release-tests" => ["lint"], "api-compatibility" => ["lint"],
  "thread-sanitizer" => ["lint"], "sample-tests" => ["lint"], "package-builds" => ["lint"],
  "focused-runtime-tests" => ["lint"], "principle-gates" => %w[lint coverage],
  "sample-package-builds" => ["sample-tests"], "sample-build" => ["lint"],
  "address-sanitizer" => ["lint"], "sample-ui-tests" => ["sample-build"], "swift-syntax-compatibility" => ["lint"],
}
prior_dependencies.each do |name, prior|
  job = jobs.fetch(name)
  check(Array(job["needs"]).sort == (["ci-plan"] + prior).sort,
    "#{name}: original dependencies plus CI Plan must be retained")
  reusable = %w[tests release-tests thread-sanitizer address-sanitizer package-builds swift-syntax-compatibility]
  expected_condition = reusable.include?(name) ? "needs.ci-plan.outputs.#{name} == 'true'" : "fromJSON(needs.ci-plan.outputs.plan).jobs.#{name}"
  check(job["if"] == expected_condition,
    "#{name}: selection must use exactly its fail-closed planned boolean")
end
jobs.each do |name, job|
  check(!job.key?("continue-on-error"), "#{name}: job cannot ignore failures")
  check(Array(job["steps"]).none? { |step| step.key?("continue-on-error") },
    "#{name}: steps cannot ignore failures")
end

metadata_only = "(github.event_name == 'pull_request' && (((github.event.action == 'labeled' || github.event.action == 'unlabeled') && github.event.label.name && github.event.label.name != 'release-validation' && github.event.label.name != 'run-asan') || (github.event.action == 'edited' && !github.event.changes.base)))"
plan = jobs.fetch("ci-plan")
check(plan["name"] == "CI Plan" && plan["if"] == "${{ !#{metadata_only} }}" && !plan.key?("needs"),
  "CI Plan must run independently for validation events")
check(plan.dig("outputs", "plan") == '${{ steps.plan.outputs.plan }}', "CI Plan output must come from the planner")
plan_step = plan.fetch("steps").find { |step| step["id"] == "plan" }
check(plan_step && !plan_step.key?("if") &&
  plan_step["run"] == 'python3 -B scripts/ci-policy.py plan --event "$GITHUB_EVENT_PATH" --output .build/ci-plan.json',
  "CI Plan must execute exact changed-path planning unconditionally")
check(plan.dig("outputs", "post_merge") == "${{ github.ref == 'refs/heads/main' && (github.event_name == 'push' || (github.event_name == 'workflow_dispatch' && inputs.dependabot_merge_pr != '')) }}",
  "Pages artifact eligibility must be limited to successful main push/recovery plans")
check(jobs.dig("documentation", "with", "publish_pages") == "${{ needs.ci-plan.outputs.post_merge == 'true' }}",
  "documentation publication eligibility must come from the successful CI Plan")
check(plan.dig("permissions") == {"contents" => "read", "pull-requests" => "read", "actions" => "read", "checks" => "read"},
  "Reuse planning must remain read-only")
check(plan.dig("outputs", "reuse-proof") == '${{ steps.reuse.outputs.proof }}' &&
  plan_step.dig("env", "CI_REUSE") == '${{ steps.reuse.outputs.proof }}', "Plan must bind its admitted proof")
reuse_step = plan.fetch("steps").find { |step| step["id"] == "reuse" }
check(reuse_step && !reuse_step.key?("if") && reuse_step["run"] == 'python3 -B scripts/main-ci-reuse-policy.py --event "$GITHUB_EVENT_PATH"',
  "Reuse admission must be unconditional and metadata-only")
%w[tests release-tests thread-sanitizer address-sanitizer package-builds swift-syntax-compatibility].each do |name|
  check(plan.dig("outputs", name) == "${{ steps.plan.outputs.#{name} }}", "#{name}: exact physical planner output missing")
end
check(jobs.dig("ci-required", "permissions") == {"contents" => "read", "actions" => "read", "checks" => "read", "pull-requests" => "read"},
  "Final proof revalidation must remain read-only")
checkout = plan.fetch("steps").find { |step| step["uses"].to_s.start_with?("actions/checkout@") }
check(checkout && checkout.dig("with", "fetch-depth") == 0 && checkout.dig("with", "persist-credentials") == false,
  "CI Plan must fetch exact diff history without persisting credentials")

policy = jobs.fetch("policy")
check(Array(policy["needs"]) == ["ci-plan"] && !policy.key?("if"), "policy contracts must run for every valid plan")
policy_runs = policy.fetch("steps").filter_map { |step| step["run"] }.join("\n")
["python3 -B -m unittest discover -s scripts/tests -p 'test_*.py'", "python3 -B scripts/check-public-operations.py",
 "python3 -B scripts/check-ci-workflows.py", "scripts/check-workflow-action-pins.sh", "scripts/check-workflow-job-timeouts.sh",
 "scripts/check-macro-operations.sh", "scripts/check-community-health.sh"].each do |command|
  check(policy_runs.lines.map(&:strip).include?(command), "policy must run #{command}")
end

api_runs = jobs.fetch("api-compatibility").fetch("steps").filter_map { |step| step["run"] }
check(api_runs.include?('"$GITHUB_WORKSPACE/scripts/check-migration-consumer.sh"'),
  "CI must run the exact 5.1.1 to 6.0 external migration consumer")
principle_runs = jobs.fetch("principle-gates").fetch("steps").filter_map { |step| step["run"] }
check(principle_runs.any? { |run| run.include?("principle-gates.sh\" --static") },
  "CI principle gates must use the build-free static mode")
check(principle_runs.include?('"$GITHUB_WORKSPACE/scripts/principle-gates-selftest.sh"'),
  "CI must retain gate negative controls")
check(jobs.fetch("release-tests").fetch("steps").any? { |step| step["run"] == '"$GITHUB_WORKSPACE/scripts/check-release-configuration.sh"' },
  "Release tests must execute the Release-only configuration gate")
{
  "package-builds" => %w[macOS iOS tvOS watchOS visionOS],
  "focused-runtime-tests" => %w[iOS tvOS watchOS visionOS],
  "sample-package-builds" => %w[tvOS watchOS visionOS],
}.each do |name, platforms|
  check(jobs.dig(name, "strategy", "matrix", "platform") == platforms && jobs.dig(name, "strategy", "fail-fast") == false,
    "#{name}: original complete platform matrix must be preserved")
end

asan = load_yaml.call(File.join(workflow_dir, "asan.yml"))
asan_trigger = asan["on"] || asan[true]
check(asan_trigger.keys == ["workflow_dispatch"],
  "standalone ASan is manual-only; planned CI owns source, bot and run-asan label checks")

# Both existing protected contexts run for validation events. A skipped selected job
# is an error, never a successful no-op, including reused workflow/matrix jobs.
{
  "ci-required" => ["CI Required", required_job_names, "Require every planned CI result", "evaluate"],
  "docs-required" => ["Build Documentation", %w[ci-plan documentation], "Require planned documentation result", "evaluate-documentation"],
}.each do |id, (name, dependencies, step_name, command)|
  final_gate = jobs.fetch(id)
  noop = id == "ci-required" ? "CI Metadata Only" : "Documentation Metadata Only"
  check(final_gate["name"] == "${{ #{metadata_only} && '#{noop}' || '#{name}' }}" &&
    final_gate["if"] == "${{ always() && !#{metadata_only} }}",
    "#{name} must aggregate validation without replacing protected contexts on metadata events")
  check(Array(final_gate["needs"]).sort == dependencies.sort,
    "#{name}: dependencies must match its complete result inventory")
  steps = final_gate.fetch("steps")
  verifier = steps.last
  check(verifier["name"] == step_name && !verifier.key?("if") &&
    verifier["run"] == "python3 -B scripts/ci-policy.py #{command}" &&
    verifier["env"] == ({"CI_PLAN" => '${{ needs.ci-plan.outputs.plan }}', "CI_NEEDS" => '${{ toJSON(needs) }}'}.merge(id == "ci-required" ? {"GH_TOKEN" => '${{ github.token }}', "CI_REUSE" => '${{ needs.ci-plan.outputs.reuse-proof }}'} : {})),
    "#{name}: final unconditional verifier must consume the exact plan and dependency results")
end

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

puts "[ci-efficiency] Change-aware selection, protected contexts and complete existing gates passed"
