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
  fail_contract("#{script} must run unconditionally") if matches.first.key?("if")
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
  preflight_path = ARGV.fetch(2) { abort "Missing release-preflight.yml" }

  cd = load_workflow(cd_path)
  jobs = cd.fetch("jobs")
  fail_contract("release validation permissions must remain read-only") unless
    cd["permissions"] == { "contents" => "read", "actions" => "read" }
  fail_contract("release attempts must serialize per ref without cancellation") unless
    cd["concurrency"] == { "group" => "innoflow-release-${{ github.ref }}", "cancel-in-progress" => false }
  jobs.each do |name, job|
    if name != "publish-release" && job.fetch("permissions", {}).values.any? { |level| level != "read" }
      fail_contract("#{name} must not grant publication permissions")
    end
    checkout_steps(Array(job["steps"])).each do |step, _index|
      fail_contract("#{name} checkout must use the exact event SHA without credentials") unless
        step.dig("with", "ref") == "${{ github.sha }}" && step.dig("with", "persist-credentials") == false
    end
  end
  platform_builds = job!(jobs, "release-platform-builds")
  fail_contract("release SDK matrix changed") unless
    platform_builds.dig("strategy", "matrix", "platform") == %w[macOS iOS tvOS watchOS visionOS]
  platform_steps = steps!(platform_builds, "release-platform-builds")
  strict_script_step!(
    platform_steps,
    "scripts/run-sdk-platform-build.sh",
    ["--platform", "${{ matrix.platform }}", "--derived-data", "--result-bundle"]
  )
  sample_steps = platform_steps.select { |step| step["name"] == "Build canonical sample package for ${{ matrix.platform }}" }
  fail_contract("release sample platform build step is missing or duplicated") unless sample_steps.one?
  fail_contract("release sample platform build is conditional") if sample_steps.first.key?("if")
  fail_contract("release sample platform build must use the canonical package") unless
    sample_steps.first.fetch("run", "").include?('cd "$GITHUB_WORKSPACE/Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage"')
  strict_script_step!(
    sample_steps,
    "xcodebuild",
    ["-scheme InnoFlowSampleAppFeature", "-disableAutomaticPackageResolution",
      "generic/platform=${{ matrix.platform }}", "-derivedDataPath", "-resultBundlePath",
      "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "build"]
  )
  evidence = job!(jobs, "release-evidence")
  fail_contract("release evidence must reopen Xcode 27 results on hosted Xcode 27") unless evidence["runs-on"] == "xcode-27" &&
    evidence.dig("env", "DEVELOPER_DIR") == "/Applications/Xcode_27.0.app/Contents/Developer"
  fail_contract("release-evidence job uses continue-on-error") if evidence["continue-on-error"] == true
  required_needs = %w[release-gate release-platform-builds release-runtime-tests release-sanitizers release-coverage].sort
  fail_contract("release-evidence needs do not match required jobs") unless Array(evidence["needs"]).sort == required_needs
  evidence_if = evidence["if"].to_s
  fail_contract("release-evidence must run after failures to reject them") unless evidence_if.include?("always()") && evidence_if.include?("refs/tags/")
  evidence_steps = steps!(evidence, "release-evidence")
  checkouts = checkout_steps(evidence_steps)
  fail_contract("release-evidence must checkout only InnoFlow") unless checkouts.length == 1
  innoflow_checkout, innoflow_index = checkouts.find { |step, _| step.dig("with", "path") == "release-components/InnoFlow" }
  assert_checkout!(innoflow_checkout, label: "release-evidence InnoFlow", path: "release-components/InnoFlow", ref: "${{ github.sha }}")
  repository_script_indices = evidence_steps.each_index.select { |index| evidence_steps[index]["run"].to_s.include?("scripts/") }
  fail_contract("release-evidence has no repository script step") if repository_script_indices.empty?
  fail_contract("InnoFlow checkout must precede every repository script") unless innoflow_index < repository_script_indices.min
  strict_script_step!(evidence_steps, "scripts/verify-release-prerequisites.sh", required_needs.map { |name| name.upcase.tr("-", "_") + "_RESULT" })
  strict_script_step!(evidence_steps, "scripts/write-github-evidence-provenance.sh", %w[--run-id --artifact-name --output])
  strict_script_step!(evidence_steps, "scripts/verify-candidate-component.sh", ["--candidate-snapshot", "--label innoflow", "--repository", "--policy"])
  strict_script_step!(evidence_steps, "scripts/record-release-evidence.sh", ["--check-id remote-ci", "--attempt-index attempts.tsv", "-- scripts/verify-github-evidence-run.sh"])
  strict_script_step!(evidence_steps, "scripts/verify-release-evidence.sh", ["--candidate-hash", "--candidate-snapshot", "--evidence-root", "--manifest", "--attempt-index attempts.tsv", "--policy", "--trusted-producer-context", "--stage pre-publication"])
  download_steps = evidence_steps.select { |step| step.fetch("run", "").include?("gh run download") }
  fail_contract("release evidence must have one download step") unless download_steps.one?
  download_run = download_steps.first.fetch("run")
  fail_contract("download step must reject a missing run ID") unless download_run.include?("A prior evidence run ID is required") && download_run.include?("exit 1")
  fail_contract("evidence must stay outside the candidate checkout") unless download_run.include?("$RUNNER_TEMP/") && !download_run.include?("--dir release-evidence")

  publish = job!(jobs, "publish-release")
  fail_contract("publish-release must need only release-evidence") unless Array(publish["needs"]) == ["release-evidence"]
  cd_trigger = cd["on"] || cd[true]
  publish_input = cd_trigger.dig("workflow_dispatch", "inputs", "publish_release")
  fail_contract("release publication must default to false") unless
    publish_input.is_a?(Hash) && publish_input["type"] == "boolean" &&
    publish_input["default"] == false && publish_input["required"] == false
  publish_if = publish["if"].to_s
  fail_contract("publish-release requires explicit dispatch, tag, evidence success, and opt-in") unless
    publish_if == "github.event_name == 'workflow_dispatch' && inputs.publish_release == true && startsWith(github.ref, 'refs/tags/') && needs.release-evidence.result == 'success'"
  fail_contract("publish-release uses continue-on-error") if publish["continue-on-error"] == true
  fail_contract("publication must enter the release environment") unless publish["environment"] == "release"
  fail_contract("only publication may write repository contents") unless publish["permissions"] == { "contents" => "write" }
  publish_steps = steps!(publish, "publish-release")
  strict_script_step!(publish_steps, "scripts/verify-release-publication.sh", ['"$RELEASE_TAG" "$RELEASE_SHA"'])
  tag_check = publish_steps.find { |step| step.fetch("run", "").include?("scripts/verify-release-publication.sh") }
  fail_contract("publication tag check must bind the dispatch tag and SHA") unless
    tag_check["env"] == { "RELEASE_TAG" => "${{ github.ref_name }}", "RELEASE_SHA" => "${{ github.sha }}" }
  publishers = publish_steps.select { |step| step["uses"].to_s.start_with?("softprops/action-gh-release@") }
  fail_contract("publication requires exactly one final release action after tag verification") unless publishers.one? &&
    publish_steps.last == publishers.first && publish_steps[-2] == tag_check && !publishers.first.key?("if")
  fail_contract("publication must require the exact release assets") unless
    publishers.first["with"] == { "tag_name" => "${{ github.ref_name }}", "body_path" => "release-notes.md",
      "fail_on_unmatched_files" => true, "files" => "release-assets/innoflow-docc.tar.gz\nrelease-assets/SHA256SUMS\n" }
  artifact_name = "innoflow-release-gate-${{ github.sha }}"
  gate_steps = steps!(job!(jobs, "release-gate"), "release-gate")
  gate_uploads = gate_steps.select { |step| step["uses"].to_s.start_with?("actions/upload-artifact@") }
  fail_contract("release assets must be candidate-bound, non-overwriting, and fail closed") unless gate_uploads.one? &&
    gate_uploads.first.dig("with", "name") == artifact_name &&
    gate_uploads.first.dig("with", "if-no-files-found") == "error" &&
    gate_uploads.first.dig("with", "overwrite") == false &&
    gate_uploads.first.dig("with", "path") == ".build/docc/innoflow-docc.tar.gz\n.build/docc/SHA256SUMS\n"
  asset_downloads = publish_steps.select { |step| step["uses"].to_s.start_with?("actions/download-artifact@") }
  fail_contract("publication must download only this run's exact candidate assets") unless asset_downloads.one? &&
    !asset_downloads.first.key?("if") && asset_downloads.first["with"] == { "name" => artifact_name, "path" => "release-assets" }
  strict_script_step!(publish_steps, "shasum", ["-a 256 -c SHA256SUMS"])
  checksum_step = publish_steps.find { |step| step.fetch("run", "").include?("shasum -a 256 -c SHA256SUMS") }
  fail_contract("asset checksum must run on the downloaded files before publication") unless
    checksum_step["working-directory"] == "release-assets" &&
    publish_steps.index(asset_downloads.first) < publish_steps.index(checksum_step) &&
    publish_steps.index(checksum_step) < publish_steps.index(tag_check)

  producer = load_workflow(producer_path)
  producer_trigger = producer["on"] || producer[true]
  fail_contract("producer must only expose workflow_dispatch") unless producer_trigger.is_a?(Hash) && producer_trigger.keys == ["workflow_dispatch"]
  inputs = producer_trigger.dig("workflow_dispatch", "inputs")
  fail_contract("producer inputs are incomplete or contain retired inputs") unless inputs.is_a?(Hash) && inputs.keys.sort == %w[preflight_run_id release_approval]
  fail_contract("producer permissions must be read-only") unless producer["permissions"] == { "contents" => "read", "actions" => "read" }
  producer_jobs = producer.fetch("jobs")
  fail_contract("producer must define exactly one non-deploy job") unless producer_jobs.keys == ["produce-release-evidence"]
  producer_job = job!(producer_jobs, "produce-release-evidence")
  producer_if = producer_job["if"].to_s
  fail_contract("producer must require a tag and explicit approval") unless producer_if.include?("github.ref_type == 'tag'") && producer_if.include?("inputs.release_approval")
  fail_contract("producer must use GitHub-hosted Xcode 27") unless producer_job["runs-on"] == "xcode-27" &&
    producer_job.dig("env", "DEVELOPER_DIR") == "/Applications/Xcode_27.0.app/Contents/Developer"
  producer_steps = steps!(producer_job, "produce-release-evidence")
  strict_script_step!(producer_steps, "scripts/write-github-evidence-provenance.sh",
    ["--preflight", '--run-id "$PREFLIGHT_RUN_ID"', '--artifact-name "innoflow-release-preflight-$GITHUB_SHA"', "--output"])
  imports = producer_steps.select { |step| step.fetch("run", "").include?("gh run download") }
  fail_contract("producer must import exactly one verified CI bundle") unless imports.one?
  import_run = imports.first.fetch("run")
  fail_contract("CI provenance must precede download") unless import_run.index("scripts/write-github-evidence-provenance.sh") &&
    import_run.index("scripts/write-github-evidence-provenance.sh") < import_run.index("gh run download")
  fail_contract("producer download must bind run, repository and SHA") unless
    ['gh run download "$PREFLIGHT_RUN_ID"', '--repo "$GITHUB_REPOSITORY"',
      '--name "innoflow-release-preflight-$GITHUB_SHA"', '--dir "$evidence_root.download"'].all? { |part| import_run.include?(part) }
  fail_contract("producer may not import local intake") if File.read(producer_path).match?(/intake_name|INTAKE_NAME|\bditto\b/)
  producer_checkouts = checkout_steps(producer_steps)
  fail_contract("producer must checkout only InnoFlow") unless producer_checkouts.length == 1
  producer_innoflow, = producer_checkouts.find { |step, _| step.dig("with", "path") == "components/InnoFlow" }
  assert_checkout!(producer_innoflow, label: "producer InnoFlow", path: "components/InnoFlow", ref: "${{ github.sha }}")
  strict_script_step!(producer_steps, "scripts/verify-candidate-component.sh", ["--candidate-snapshot", "--label innoflow", "--repository", "--policy"])
  strict_script_step!(producer_steps, "scripts/verify-release-evidence.sh", ["--candidate-hash", "--candidate-snapshot", "--evidence-root", "--manifest", "--attempt-index attempts.tsv", "--policy", "--stage local-preflight"])
  strict_script_step!(producer_steps, "scripts/record-release-evidence.sh", ["--check-id tag-api-baseline", "--attempt-index attempts.tsv", "-- scripts/check-release-sync.sh"])
  strict_script_step!(producer_steps, "scripts/record-manual-release-evidence.sh", ["--check-id release-approval", "--reviewer", "--observed-at", "--attempt-index attempts.tsv", "--producer-json"])
  upload_steps = producer_steps.select { |step| step["uses"].to_s.start_with?("actions/upload-artifact@") }
  fail_contract("producer must upload exactly one evidence artifact") unless upload_steps.one?
  upload = upload_steps.first.fetch("with", {})
  fail_contract("producer artifact name is not candidate-bound") unless upload["name"] == "innoflow-release-evidence-${{ github.sha }}"
  fail_contract("producer artifact must fail closed") unless upload["if-no-files-found"] == "error" && upload["overwrite"] == false
  fail_contract("producer may not contain deployment commands") if File.read(producer_path).match?(/\b(?:gh release create|swift package publish|npm publish|deploy)\b/i)

  preflight = load_workflow(preflight_path)
  preflight_trigger = preflight["on"] || preflight[true]
  fail_contract("preflight must only expose input-free workflow_dispatch") unless preflight_trigger == { "workflow_dispatch" => nil }
  fail_contract("preflight permissions must be read-only") unless preflight["permissions"] == { "contents" => "read" }
  preflight_jobs = preflight.fetch("jobs")
  fail_contract("preflight job inventory changed") unless preflight_jobs.keys == %w[plan preflight aggregate]
  preflight_jobs.each do |name, job|
    fail_contract("#{name} must run only on main") unless job["if"] == "github.ref == 'refs/heads/main'"
    fail_contract("#{name} may not skip failures") if job["continue-on-error"]
    checkouts = checkout_steps(steps!(job, name))
    fail_contract("#{name} must checkout only InnoFlow") unless checkouts.one?
    assert_checkout!(checkouts.first.first, label: name, path: "components/InnoFlow", ref: "${{ github.sha }}")
  end
  plan = job!(preflight_jobs, "plan")
  fail_contract("plan must use hosted macOS") unless plan["runs-on"] == "macos-26"
  fail_contract("matrix output changed") unless plan.dig("outputs", "matrix") == "${{ steps.matrix.outputs.matrix }}"
  planner = plan.fetch("steps").find { |step| step["id"] == "matrix" }
  fail_contract("plan must enumerate the entire validated policy") unless planner &&
    planner["working-directory"] == "components/InnoFlow" && !planner.key?("if") &&
    planner["run"] == "set -euo pipefail\nruby scripts/check-release-evidence-policy.rb\nmatrix=\"$(ruby scripts/hosted-release-preflight.rb matrix)\"\necho \"matrix=$matrix\" >>\"$GITHUB_OUTPUT\"\n"
  preflight_job = job!(preflight_jobs, "preflight")
  fail_contract("preflight must use the complete hosted matrix") unless preflight_job["needs"] == "plan" &&
    preflight_job["runs-on"] == "${{ matrix.runner }}" &&
    preflight_job["strategy"] == { "fail-fast" => false, "max-parallel" => 6, "matrix" => "${{ fromJSON(needs.plan.outputs.matrix) }}" } &&
    preflight_job.dig("env", "DEVELOPER_DIR") == "/Applications/Xcode_${{ matrix.xcode }}.app/Contents/Developer"
  fail_contract("preflight needs a bounded timeout") unless preflight_job["timeout-minutes"] == 180
  preflight_steps = steps!(preflight_job, "preflight")
  runner_script = "ruby scripts/hosted-release-preflight.rb"
  strict_script_step!(preflight_steps, runner_script, ['execute --check-id "$CHECK_ID" --evidence-root "$EVIDENCE_ROOT"'])
  execution = preflight_steps.find { |step| step.fetch("run", "").include?(runner_script) }
  fail_contract("preflight execution must use the selected check unconditionally") unless !execution.key?("if") &&
    execution["working-directory"] == "components/InnoFlow" && execution.dig("env", "CHECK_ID") == "${{ matrix.check }}"
  uploads = preflight_steps.select { |step| step["uses"].to_s.start_with?("actions/upload-artifact@") }
  fail_contract("preflight needs separate shard and diagnostic artifacts") unless uploads.length == 2
  shard = uploads.find { |step| step.dig("with", "name") == "innoflow-preflight-shard-${{ github.sha }}-${{ matrix.check }}" }
  fail_contract("shard upload must follow successful execution") unless shard && !shard.key?("if") &&
    preflight_steps.index(shard) > preflight_steps.index(execution)
  diagnostic = uploads.find { |step| step != shard }
  fail_contract("preflight failure artifact must not impersonate success") unless
    diagnostic.dig("with", "name") == "innoflow-preflight-diagnostics-${{ github.sha }}-${{ matrix.check }}-${{ github.run_attempt }}" &&
    diagnostic["if"] == "${{ failure() || cancelled() }}"
  aggregate = job!(preflight_jobs, "aggregate")
  fail_contract("aggregation requires every shard") unless aggregate["needs"] == %w[plan preflight] &&
    aggregate["runs-on"] == "xcode-27" && aggregate.dig("env", "DEVELOPER_DIR") == "/Applications/Xcode_27.0.app/Contents/Developer"
  aggregate_steps = steps!(aggregate, "aggregate")
  downloads = aggregate_steps.select { |step| step["uses"].to_s.start_with?("actions/download-artifact@") }
  fail_contract("aggregate must download only this run's candidate shards without flattening") unless downloads.one? &&
    downloads.first["with"] == { "pattern" => "innoflow-preflight-shard-${{ github.sha }}-*",
      "path" => "${{ runner.temp }}/innoflow-preflight-shards", "merge-multiple" => false }
  strict_script_step!(aggregate_steps, runner_script, ['merge --shards "$SHARDS" --evidence-root "$EVIDENCE_ROOT"'])
  merge = aggregate_steps.find { |step| step.fetch("run", "").include?(runner_script) }
  fail_contract("aggregation may not skip verification") if merge.key?("if") || merge["working-directory"] != "components/InnoFlow"
  complete_uploads = aggregate_steps.select { |step| step["uses"].to_s.start_with?("actions/upload-artifact@") }
  fail_contract("aggregate must upload exactly one complete bundle") unless complete_uploads.one?
  complete = complete_uploads.first
  fail_contract("complete artifact must follow successful aggregation") unless !complete.key?("if") &&
    complete.dig("with", "name") == "innoflow-release-preflight-${{ github.sha }}" &&
    aggregate_steps.index(complete) > aggregate_steps.index(merge)
  [shard, complete].each do |upload|
    fail_contract("evidence artifact must fail closed") unless upload.dig("with", "if-no-files-found") == "error" &&
      upload.dig("with", "overwrite") == false && upload.dig("with", "include-hidden-files") == true &&
      upload.dig("with", "path") == "${{ runner.temp }}/innoflow-transport/evidence.tar.gz"
  end
  archive_script = "ruby scripts/release-evidence-archive.rb"
  strict_script_step!(evidence_steps, archive_script, ['unpack "$evidence_root.download/evidence.tar.gz" "$evidence_root"'])
  # Producer has both import and export steps, each unconditional.
  [producer_steps, preflight_steps, aggregate_steps].each do |steps|
    packs = steps.select { |step| step.fetch("run", "").include?("#{archive_script} pack") }
    fail_contract("evidence must be archived before upload") unless packs.one? && !packs.first.key?("if") &&
      packs.first.fetch("run").include?('pack "$EVIDENCE_ROOT" "$RUNNER_TEMP/innoflow-transport/evidence.tar.gz"')
  end
  fail_contract("producer must unpack CI evidence") unless import_run.include?(
    'ruby scripts/release-evidence-archive.rb unpack "$evidence_root.download/evidence.tar.gz" "$evidence_root"')
  fail_contract("producer archive path mismatch") unless upload["path"] == "${{ runner.temp }}/innoflow-transport/evidence.tar.gz"
  fail_contract("preflight may not publish") if File.read(preflight_path).match?(/\b(?:gh release create|swift package publish|npm publish)\b/)
  [File.read(cd_path), File.read(producer_path), File.read(preflight_path)].each do |source|
    fail_contract("release workflows retain retired Mulbyul dependencies") if source.match?(/mulbyul|MULBYUL/i)
  end

  puts "[check-release-evidence-workflow] OK"
rescue KeyError, TypeError => error
  fail_contract("invalid workflow structure: #{error.message}")
end
