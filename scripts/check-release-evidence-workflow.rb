#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"

def fail_contract(message)
  abort "Release evidence workflow contract failed: #{message}"
end

def load_workflow(path)
  YAML.safe_load(File.read(path), aliases: false)
rescue Psych::SyntaxError, Errno::ENOENT => error
  fail_contract("invalid YAML #{path}: #{error.message}")
end

def job!(jobs, name)
  value = jobs[name]
  fail_contract("missing #{name} job") unless value.is_a?(Hash)
  value
end

def steps!(job, name)
  steps = job["steps"]
  fail_contract("#{name} steps are missing") unless steps.is_a?(Array) && !steps.empty?
  steps.each do |step|
    fail_contract("#{name} uses continue-on-error") if step["continue-on-error"] == true
    fail_contract("#{name} suppresses command failure") if step["run"].to_s.match?(/\|\|\s*true/)
  end
  steps
end

def strict_script_step!(steps, script, required_fragments, exact_invocations: 1)
  matches = steps.select do |step|
    run = step["run"]
    run.is_a?(String) && run.lines.any? { |line| line.strip.start_with?(script) }
  end
  fail_contract("#{script} must be invoked in exactly one step") unless matches.one?
  run = matches.first.fetch("run")
  lines = run.lines.map(&:strip).reject { |line| line.empty? || line.start_with?("#") }
  fail_contract("#{script} step must start fail-closed") unless lines.first == "set -euo pipefail"
  invocation_indices = lines.each_index.select { |index| lines[index].start_with?(script) }
  fail_contract("#{script} invocation count must be #{exact_invocations}") unless invocation_indices.length == exact_invocations
  command_lines = invocation_indices.flat_map do |invocation_index|
    invocation = lines[invocation_index]
    fail_contract("#{script} must be executed, not mentioned") unless invocation.match?(/\A#{Regexp.escape(script)}(?:\s|\\|\z)/)
    invocation_lines = []
    index = invocation_index
    loop do
      invocation_lines << lines.fetch(index)
      break unless lines.fetch(index).end_with?("\\")
      index += 1
      fail_contract("#{script} has an incomplete continuation") if index >= lines.length
    end
    invocation_lines
  end
  command_source = command_lines.join(" ")
  required_fragments.each do |fragment|
    fail_contract("#{script} is missing #{fragment}") unless command_source.include?(fragment)
  end
end

def checkout_steps(steps)
  steps.each_with_index.select { |step, _index| step["uses"].to_s.start_with?("actions/checkout@") }
end

def assert_checkout!(step, label:, path:, ref: nil, repository: nil)
  fail_contract("#{label} checkout is missing") unless step
  inputs = step.fetch("with", {})
  fail_contract("#{label} checkout path mismatch") unless inputs["path"] == path
  fail_contract("#{label} checkout must disable persisted credentials") unless inputs["persist-credentials"] == false
  fail_contract("#{label} checkout must fetch tags/history") unless inputs["fetch-depth"] == 0
  fail_contract("#{label} checkout ref mismatch") if ref && inputs["ref"] != ref
  fail_contract("#{label} checkout repository mismatch") if repository && inputs["repository"] != repository
end

begin
  cd_path = ARGV.fetch(0) { abort "Usage: check-release-evidence-workflow.rb <cd.yml> <release-evidence.yml>" }
  producer_path = ARGV.fetch(1) { abort "Usage: check-release-evidence-workflow.rb <cd.yml> <release-evidence.yml>" }

  cd = load_workflow(cd_path)
  jobs = cd.fetch("jobs")
  evidence = job!(jobs, "release-evidence")
  fail_contract("release-evidence job uses continue-on-error") if evidence["continue-on-error"] == true
  required_needs = %w[release-gate release-platform-builds release-runtime-tests release-sanitizers release-coverage].sort
  fail_contract("release-evidence needs do not match required jobs") unless Array(evidence["needs"]).sort == required_needs
  evidence_if = evidence["if"].to_s
  fail_contract("release-evidence must run after failures to reject them") unless evidence_if.include?("always()") && evidence_if.include?("refs/tags/")
  evidence_steps = steps!(evidence, "release-evidence")
  checkouts = checkout_steps(evidence_steps)
  fail_contract("release-evidence must checkout InnoFlow and Mulbyul exactly once") unless checkouts.length == 2
  innoflow_checkout, innoflow_index = checkouts.find { |step, _| step.dig("with", "path") == "release-components/InnoFlow" }
  mulbyul_checkout, = checkouts.find { |step, _| step.dig("with", "path") == "release-components/Mulbyul" }
  assert_checkout!(innoflow_checkout, label: "release-evidence InnoFlow", path: "release-components/InnoFlow", ref: "${{ github.sha }}")
  assert_checkout!(mulbyul_checkout, label: "release-evidence Mulbyul", path: "release-components/Mulbyul", repository: "InnoSquad/Mulbyul")
  repository_script_indices = evidence_steps.each_index.select { |index| evidence_steps[index]["run"].to_s.include?("scripts/") }
  fail_contract("release-evidence has no repository script step") if repository_script_indices.empty?
  fail_contract("InnoFlow checkout must precede every repository script") unless innoflow_index < repository_script_indices.min
  strict_script_step!(evidence_steps, "scripts/verify-release-prerequisites.sh", required_needs.map { |name| name.upcase.tr("-", "_") + "_RESULT" })
  strict_script_step!(evidence_steps, "scripts/write-github-evidence-provenance.sh", %w[--run-id --artifact-name --output])
  strict_script_step!(evidence_steps, "scripts/verify-candidate-component.sh", ["--candidate-snapshot", "--label innoflow", "--label mulbyul", "--repository", "--policy"], exact_invocations: 2)
  strict_script_step!(evidence_steps, "scripts/record-release-evidence.sh", ["--check-id remote-ci", "--attempt-index attempts.tsv", "-- scripts/verify-github-evidence-run.sh"])
  strict_script_step!(evidence_steps, "scripts/verify-release-evidence.sh", ["--candidate-hash", "--candidate-snapshot", "--evidence-root", "--manifest", "--attempt-index attempts.tsv", "--policy", "--trusted-producer-context", "--stage pre-publication"])
  download_steps = evidence_steps.select { |step| step.fetch("run", "").include?("gh run download") }
  fail_contract("release evidence must have one download step") unless download_steps.one?
  download_run = download_steps.first.fetch("run")
  fail_contract("download step must reject a missing run ID") unless download_run.include?("A prior evidence run ID is required") && download_run.include?("exit 1")
  fail_contract("evidence must stay outside the candidate checkout") unless download_run.include?("$RUNNER_TEMP/") && !download_run.include?("--dir release-evidence")

  publish = job!(jobs, "publish-release")
  fail_contract("publish-release must need only release-evidence") unless Array(publish["needs"]) == ["release-evidence"]
  publish_if = publish["if"].to_s
  fail_contract("publish-release must be tag-only and may not use always") unless publish_if.include?("refs/tags/") && !publish_if.include?("always()")
  fail_contract("publish-release uses continue-on-error") if publish["continue-on-error"] == true
  steps!(publish, "publish-release")

  producer = load_workflow(producer_path)
  producer_trigger = producer["on"] || producer[true]
  fail_contract("producer must only expose workflow_dispatch") unless producer_trigger.is_a?(Hash) && producer_trigger.keys == ["workflow_dispatch"]
  inputs = producer_trigger.dig("workflow_dispatch", "inputs")
  fail_contract("producer inputs are incomplete") unless inputs.is_a?(Hash) && %w[mulbyul_sha intake_name release_approval].all? { |name| inputs.key?(name) }
  fail_contract("producer permissions must be read-only") unless producer["permissions"] == { "contents" => "read" }
  producer_jobs = producer.fetch("jobs")
  fail_contract("producer must define exactly one non-deploy job") unless producer_jobs.keys == ["produce-release-evidence"]
  producer_job = job!(producer_jobs, "produce-release-evidence")
  producer_if = producer_job["if"].to_s
  fail_contract("producer must require a tag and explicit approval") unless producer_if.include?("github.ref_type == 'tag'") && producer_if.include?("inputs.release_approval")
  fail_contract("producer must use the dedicated self-hosted labels") unless Array(producer_job["runs-on"]) == %w[self-hosted macOS innoflow-release-evidence]
  producer_steps = steps!(producer_job, "produce-release-evidence")
  producer_checkouts = checkout_steps(producer_steps)
  fail_contract("producer must checkout InnoFlow and Mulbyul exactly once") unless producer_checkouts.length == 2
  producer_innoflow, = producer_checkouts.find { |step, _| step.dig("with", "path") == "components/InnoFlow" }
  producer_mulbyul, = producer_checkouts.find { |step, _| step.dig("with", "path") == "components/Mulbyul" }
  assert_checkout!(producer_innoflow, label: "producer InnoFlow", path: "components/InnoFlow", ref: "${{ github.sha }}")
  assert_checkout!(producer_mulbyul, label: "producer Mulbyul", path: "components/Mulbyul", repository: "InnoSquad/Mulbyul")
  strict_script_step!(producer_steps, "scripts/verify-candidate-component.sh", ["--candidate-snapshot", "--label innoflow", "--label mulbyul", "--repository", "--policy"], exact_invocations: 2)
  strict_script_step!(producer_steps, "scripts/verify-release-evidence.sh", ["--candidate-hash", "--candidate-snapshot", "--evidence-root", "--manifest", "--attempt-index attempts.tsv", "--policy", "--stage local-preflight"])
  strict_script_step!(producer_steps, "scripts/record-release-evidence.sh", ["--check-id tag-api-baseline", "--attempt-index attempts.tsv", "-- scripts/check-release-sync.sh"])
  strict_script_step!(producer_steps, "scripts/record-manual-release-evidence.sh", ["--check-id release-approval", "--reviewer", "--observed-at", "--attempt-index attempts.tsv", "--producer-json"])
  upload_steps = producer_steps.select { |step| step["uses"].to_s.start_with?("actions/upload-artifact@") }
  fail_contract("producer must upload exactly one evidence artifact") unless upload_steps.one?
  upload = upload_steps.first.fetch("with", {})
  fail_contract("producer artifact name is not candidate-bound") unless upload["name"] == "innoflow-release-evidence-${{ github.sha }}"
  fail_contract("producer artifact must fail closed") unless upload["if-no-files-found"] == "error" && upload["overwrite"] == false
  fail_contract("producer may not contain deployment commands") if File.read(producer_path).match?(/\b(?:gh release create|swift package publish|npm publish|deploy)\b/i)

  puts "[check-release-evidence-workflow] OK"
rescue KeyError, TypeError => error
  fail_contract("invalid workflow structure: #{error.message}")
end
