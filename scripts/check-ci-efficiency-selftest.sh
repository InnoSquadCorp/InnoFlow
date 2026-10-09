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
    "base edit is unobserved" => [".github/workflows/ci.yml", ->(doc) { (doc["on"] || doc[true])["pull_request"]["types"].delete("edited") }],
    "metadata starts planner" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["ci-plan"]["if"] = "always()" }],
    "metadata loses CI context" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["ci-required"]["name"] = "CI Metadata Only" }],
    "metadata loses docs context" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["docs-required"]["name"] = "Documentation Metadata Only" }],
    "metadata skips docs aggregate" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["docs-required"]["if"] = "success()" }],
    "policy omits workflow lint" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["policy"]["steps"].each { |step| step["run"] = step["run"].lines.reject { |line| line.strip == "python3 -B scripts/check-ci-workflows.py" }.join if step["run"] } }],
    "Ready transition reruns heavy CI" => [".github/workflows/ci.yml", ->(doc) { (doc["on"] || doc[true])["pull_request"]["types"] << "ready_for_review" }],
    "proof admission is conditional" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["ci-plan"]["steps"].find { |step| step["id"] == "reuse" }["if"] = "false" }],
    "proof output is forged" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["ci-plan"]["outputs"]["reuse-proof"] = "{}" }],
    "fresh coverage is skipped by proof" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["coverage"]["if"] = "needs.ci-plan.outputs.coverage == 'true'" }],
    "proof verifier can write" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["ci-required"]["permissions"]["checks"] = "write" }],
    "policy omits macro contract" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["policy"]["steps"].each { |step| step["run"] = step["run"].lines.reject { |line| line.strip == "scripts/check-macro-operations.sh" }.join if step["run"] } }],
    "policy omits community contract" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["policy"]["steps"].each { |step| step["run"] = step["run"].lines.reject { |line| line.strip == "scripts/check-community-health.sh" }.join if step["run"] } }],
    "label removal does not replan" => [".github/workflows/ci.yml", ->(doc) { (doc["on"] || doc[true])["pull_request"]["types"].delete("unlabeled") }],
    "stale runs survive" => [".github/workflows/ci.yml", ->(doc) { doc["concurrency"]["cancel-in-progress"] = false }],
    "full principle gate repeats tests" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["principle-gates"]["steps"].find { |step| step["run"].to_s.include?("principle-gates.sh") }["run"] = "scripts/principle-gates.sh" }],
    "Release waits for Debug" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["release-tests"]["needs"] = ["lint", "tests"] }],
    "CI omits independent consumers" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["principle-gates"]["steps"].reject! { |step| step["run"].to_s.include?("check-independent-consumers.sh") } }],
    "CI independent consumers mask failure" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["principle-gates"]["steps"].find { |step| step["run"].to_s.include?("check-independent-consumers.sh") }["continue-on-error"] = true }],
    "tag independent consumers can skip" => [".github/workflows/cd.yml", ->(doc) { doc["jobs"]["release-gate"]["steps"].find { |step| step["run"].to_s.include?("check-independent-consumers.sh") }["if"] = "false" }],
    "tag gate omits independent consumers" => [".github/workflows/cd.yml", ->(doc) { doc["jobs"]["release-gate"]["steps"].reject! { |step| step["run"].to_s.include?("check-independent-consumers.sh") } }],
    "selective graph verification removed" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["swift-syntax-compatibility"]["steps"].find { |step| step["name"] == "Verify selective test package on the audited compiler" }["run"].sub!("python3 -B scripts/ci-test-targets.py verify\n", "") }],
    "plain Release build removed" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["swift-syntax-compatibility"]["steps"].find { |step| step["name"] == "Verify selective test package on the audited compiler" }["run"].sub!("swift build --configuration release --jobs 1 -Xswiftc -warnings-as-errors\n", "") }],
    "plain Release build forces testability" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["swift-syntax-compatibility"]["steps"].find { |step| step["name"] == "Verify selective test package on the audited compiler" }["run"].sub!("swift build --configuration release", "swift build -Xswiftc -enable-testing --configuration release") }],
    "selective compiler check skipped" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["swift-syntax-compatibility"]["steps"].find { |step| step["name"] == "Verify selective test package on the audited compiler" }["if"] = "false" }],
    "selective compiler check missing" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["swift-syntax-compatibility"]["steps"].reject! { |step| step["name"] == "Verify selective test package on the audited compiler" } }],
    "codemod skips audited syntax line" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["swift-syntax-compatibility"]["steps"].find { |step| step["run"].to_s.include?("innoflow-migrate/scripts/check.sh") }["env"] = {} }],
    "codemod masks failure" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["swift-syntax-compatibility"]["steps"].find { |step| step["run"].to_s.include?("innoflow-migrate/scripts/check.sh") }["continue-on-error"] = true }],
    "CI omits migration consumer" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["api-compatibility"]["steps"].reject! { |step| step["run"].to_s.include?("check-migration-consumer.sh") } }],
    "tag gate omits migration consumer" => [".github/workflows/cd.yml", ->(doc) { doc["jobs"]["release-gate"]["steps"].reject! { |step| step["run"].to_s.include?("check-migration-consumer.sh") } }],
    "sample build is serialized" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["sample-build"]["needs"] = "principle-gates" }],
    "ASan duplicates every PR" => [".github/workflows/asan.yml", ->(doc) { (doc["on"] || doc[true])["pull_request"] = {} }],
    "source platform removed" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["package-builds"]["strategy"]["matrix"]["platform"].delete("watchOS") }],
    "focused runtime platform removed" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["focused-runtime-tests"]["strategy"]["matrix"]["platform"].delete("visionOS") }],
    "sample matrix fail-fast" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["sample-package-builds"]["strategy"]["fail-fast"] = true }],
    "ASan permanently skipped" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["address-sanitizer"]["if"] = "github.event_name == 'push'" }],
    "PR can publish docs artifact" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["documentation"]["with"]["publish_pages"] = true }],
    "every plan allows publication" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["ci-plan"]["outputs"]["post_merge"] = "true" }],
    "planner shallow checkout" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["ci-plan"]["steps"].first["with"]["fetch-depth"] = 1 }],
    "planner conditional" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["ci-plan"]["steps"].find { |step| step["id"] == "plan" }["if"] = "false" }],
    "selected core permanently skipped" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["tests"]["if"] = "false" }],
    "policy only runs on main" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["policy"]["if"] = "github.event_name == 'push'" }],
    "PR paths omit required context" => [".github/workflows/ci.yml", ->(doc) { (doc["on"] || doc[true])["pull_request"]["paths"] = ["Sources/**"] }],
    "docs protection context renamed" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["docs-required"]["name"] = "Documentation Required" }],
    "docs protection context ignores skips" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["docs-required"]["steps"].last["run"] = "true" }],
    "CI aggregate omits coverage" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["ci-required"]["needs"].delete("coverage") }],
    "new CI job bypasses aggregate" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["shadow-validation"] = { "runs-on" => "macos-26", "steps" => [{ "run" => "true" }] } }],
    "CI aggregate can be skipped" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["ci-required"]["if"] = "success()" }],
    "CI aggregate ignores results" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["ci-required"]["steps"].find { |step| step["run"].to_s.include?("ci-policy.py evaluate") }["run"] = "true" }],
    "CI result verifier has a false condition" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["ci-required"]["steps"].find { |step| step["run"].to_s.include?("ci-policy.py evaluate") }["if"] = "false" }],
    "CI result verifier ignores failure by expression" => [".github/workflows/ci.yml", ->(doc) { doc["jobs"]["ci-required"]["steps"].find { |step| step["run"].to_s.include?("ci-policy.py evaluate") }["continue-on-error"] = "${{ true }}" }],
    "CI result verifier masks failure" => [".github/workflows/ci.yml", ->(doc) { step = doc["jobs"]["ci-required"]["steps"].find { |candidate| candidate["run"].to_s.include?("ci-policy.py evaluate") }; step["run"] = step["run"].sub(/\n?\z/, " || true\\n") }],
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
