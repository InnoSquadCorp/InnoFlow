#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
checker="$script_dir/check-release-evidence-workflow.sh"
source_workflow="$script_dir/../.github/workflows/cd.yml"
source_producer="$script_dir/../.github/workflows/release-evidence.yml"
source_preflight="$script_dir/../.github/workflows/release-preflight.yml"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

"$checker" "$source_workflow" >/dev/null

expect_mutation_failure() {
  local name="$1" expression="$2"
  local fixture="$fixture_root/$name.yml"
  ruby -e "$expression" "$source_workflow" "$fixture"
  if "$checker" "$fixture" >/dev/null 2>&1; then
    echo "Workflow mutation was not rejected: $name" >&2
    exit 1
  fi
}

expect_mutation_failure echo-verifier \
  's=File.read(ARGV[0]); s.sub!("scripts/verify-release-evidence.sh", "echo scripts/verify-release-evidence.sh"); File.write(ARGV[1],s)'
expect_mutation_failure unrelated-needs \
  's=File.read(ARGV[0]); s.sub!("needs: [release-gate, release-platform-builds, release-runtime-tests, release-sanitizers, release-coverage]", "needs: [release-gate]"); File.write(ARGV[1],s)'
expect_mutation_failure continue-on-error \
  's=File.read(ARGV[0]); s.sub!("    runs-on: xcode-27\n    timeout-minutes: 120", "    runs-on: xcode-27\n    continue-on-error: true\n    timeout-minutes: 120"); File.write(ARGV[1],s)'
expect_mutation_failure old-xcresult-reader \
  's=File.read(ARGV[0]); s.sub!("runs-on: xcode-27", "runs-on: macos-26"); File.write(ARGV[1],s)'
expect_mutation_failure suppress-verifier \
  's=File.read(ARGV[0]); s.sub!("            --stage pre-publication\n", "            --stage pre-publication || true\n"); File.write(ARGV[1],s)'
expect_mutation_failure echo-remote-verifier \
  's=File.read(ARGV[0]); s.sub!("-- scripts/verify-github-evidence-run.sh", "-- echo scripts/verify-github-evidence-run.sh"); File.write(ARGV[1],s)'
expect_mutation_failure evidence-inside-checkout \
  's=File.read(ARGV[0]); s.sub!("$RUNNER_TEMP/innoflow-release-evidence-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT", "release-evidence"); File.write(ARGV[1],s)'
expect_mutation_failure missing-snapshot \
  's=File.read(ARGV[0]); s.gsub!(/--candidate-snapshot [^ \\\n]+/, "--snapshot-removed"); File.write(ARGV[1],s)'
expect_mutation_failure publish-bypass \
  's=File.read(ARGV[0]); s.sub!("    needs: [release-evidence]", "    needs: [release-gate]"); File.write(ARGV[1],s)'
expect_mutation_failure publish-default-true \
  's=File.read(ARGV[0]); s.sub!("      publish_release:\n        description: \"Explicitly publish the GitHub Release after every release gate passes\"\n        required: false\n        default: false", "      publish_release:\n        description: \"Explicitly publish the GitHub Release after every release gate passes\"\n        required: false\n        default: true"); File.write(ARGV[1],s)'
expect_mutation_failure publish-without-opt-in \
  's=File.read(ARGV[0]); s.sub!("inputs.publish_release == true && ", ""); File.write(ARGV[1],s)'
expect_mutation_failure publish-on-tag-push \
  's=File.read(ARGV[0]); s.sub!("github.event_name == '\''workflow_dispatch'\'' && ", ""); File.write(ARGV[1],s)'
expect_mutation_failure sdk-build-bypass \
  's=File.read(ARGV[0]); s.sub!("scripts/run-sdk-platform-build.sh", "xcodebuild"); File.write(ARGV[1],s)'
expect_mutation_failure sample-platform-build-bypass \
  's=File.read(ARGV[0]); s.sub!("-scheme InnoFlowSampleAppFeature", "-scheme MissingSampleFeature"); File.write(ARGV[1],s)'
expect_mutation_failure checkout-after-script \
  's=File.read(ARGV[0]); block=s[/      - name: Checkout exact release candidate\n.*?          persist-credentials: false\n/m]; s.sub!(block, ""); marker="      - name: Download candidate-bound release evidence\n"; s.sub!(marker, block+"\n"+marker); File.write(ARGV[1],s)'
expect_mutation_failure retired-consumer-checkout \
  's=File.read(ARGV[0]); marker="      - name: Verify complete pre-publication evidence\n"; block="      - name: Checkout Mulbyul\n        uses: actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10\n        with:\n          repository: InnoSquadCorp/Mulbyul\n          fetch-depth: 0\n          persist-credentials: false\n          path: release-components/Mulbyul\n\n"; s.sub!(marker, block+marker); File.write(ARGV[1],s)'

expect_producer_mutation_failure() {
  local name="$1" expression="$2"
  local fixture="$fixture_root/producer-$name.yml"
  ruby -e "$expression" "$source_producer" "$fixture"
  if "$checker" "$source_workflow" "$fixture" >/dev/null 2>&1; then
    echo "Producer workflow mutation was not rejected: $name" >&2
    exit 1
  fi
}

expect_producer_mutation_failure no-explicit-approval \
  's=File.read(ARGV[0]); s.sub!("github.ref_type == '\''tag'\'' && inputs.release_approval", "github.ref_type == '\''tag'\''"); File.write(ARGV[1],s)'
expect_producer_mutation_failure self-hosted-runner \
  's=File.read(ARGV[0]); s.sub!("runs-on: xcode-27", "runs-on: [self-hosted, macOS, innoflow-release-evidence]"); File.write(ARGV[1],s)'
expect_producer_mutation_failure echo-tag-check \
  's=File.read(ARGV[0]); s.sub!("-- scripts/check-release-sync.sh", "-- echo scripts/check-release-sync.sh"); File.write(ARGV[1],s)'
expect_producer_mutation_failure skip-local-verifier \
  's=File.read(ARGV[0]); s.sub!("--stage local-preflight", "--stage-removed"); File.write(ARGV[1],s)'
expect_producer_mutation_failure overwrite-artifact \
  's=File.read(ARGV[0]); s.sub!("overwrite: false", "overwrite: true"); File.write(ARGV[1],s)'
expect_producer_mutation_failure deploy-command \
  's=File.read(ARGV[0]); s.sub!("set -euo pipefail", "set -euo pipefail\n          gh release create 6.0.0"); File.write(ARGV[1],s)'
expect_producer_mutation_failure retired-consumer-input \
  's=File.read(ARGV[0]); marker="      preflight_run_id:\n"; block="      mulbyul_sha:\n        description: retired\n        required: true\n        type: string\n"; s.sub!(marker, block+marker); File.write(ARGV[1],s)'
expect_producer_mutation_failure skip-ci-provenance \
  's=File.read(ARGV[0]); s.sub!("--preflight \\\n", "--no-preflight \\\n"); File.write(ARGV[1],s)'
expect_producer_mutation_failure import-local-intake \
  's=File.read(ARGV[0]); s.sub!("gh run download", "ditto"); File.write(ARGV[1],s)'
expect_producer_mutation_failure download-wrong-sha \
  's=File.read(ARGV[0]); s.sub!("--name \"innoflow-release-preflight-$GITHUB_SHA\"", "--name \"unrelated\""); File.write(ARGV[1],s)'
expect_producer_mutation_failure unpack-bypass \
  's=File.read(ARGV[0]); s.sub!("release-evidence-archive.rb unpack", "release-evidence-archive.rb skip"); File.write(ARGV[1],s)'

expect_preflight_mutation_failure() {
  local name="$1" expression="$2"
  local fixture="$fixture_root/preflight-$name.yml"
  ruby -e "$expression" "$source_preflight" "$fixture"
  if "$checker" "$source_workflow" "$source_producer" "$fixture" >/dev/null 2>&1; then
    echo "Preflight workflow mutation was not rejected: $name" >&2
    exit 1
  fi
}
expect_preflight_mutation_failure untrusted-branch \
  's=File.read(ARGV[0]); s.sub!("refs/heads/main", "refs/heads/feature"); File.write(ARGV[1],s)'
expect_preflight_mutation_failure subset \
  's=File.read(ARGV[0]); s.sub!("fromJSON(needs.plan.outputs.matrix)", "fromJSON(needs.plan.outputs.subset)"); File.write(ARGV[1],s)'
expect_preflight_mutation_failure plan-not-execute \
  's=File.read(ARGV[0]); s.sub!("execute --check-id", "matrix --check-id"); File.write(ARGV[1],s)'
expect_preflight_mutation_failure failed-pass-artifact \
  's=File.read(ARGV[0]); s.sub!("      - name: Upload complete candidate-bound preflight", "      - if: always()\n        name: Upload complete candidate-bound preflight"); File.write(ARGV[1],s)'
expect_preflight_mutation_failure job-continue-on-error \
  's=File.read(ARGV[0]); s.sub!("    timeout-minutes: 180", "    continue-on-error: true\n    timeout-minutes: 180"); File.write(ARGV[1],s)'
expect_preflight_mutation_failure self-hosted-runner \
  's=File.read(ARGV[0]); s.sub!("runs-on: ${{ matrix.runner }}", "runs-on: [self-hosted, macOS]"); File.write(ARGV[1],s)'
expect_preflight_mutation_failure aggregate-without-shards \
  's=File.read(ARGV[0]); s.sub!("needs: [plan, preflight]", "needs: [plan]"); File.write(ARGV[1],s)'
expect_preflight_mutation_failure skip-merge \
  's=File.read(ARGV[0]); s.sub!("merge --shards", "matrix --shards"); File.write(ARGV[1],s)'
expect_preflight_mutation_failure flatten-artifacts \
  's=File.read(ARGV[0]); s.sub!("merge-multiple: false", "merge-multiple: true"); File.write(ARGV[1],s)'
expect_preflight_mutation_failure foreign-run-artifacts \
  's=File.read(ARGV[0]); s.sub!("merge-multiple: false", "merge-multiple: false\n          run-id: 1234"); File.write(ARGV[1],s)'
expect_preflight_mutation_failure archive-bypass \
  's=File.read(ARGV[0]); s.sub!("release-evidence-archive.rb pack", "release-evidence-archive.rb skip"); File.write(ARGV[1],s)'

RELEASE_GATE_RESULT=success RELEASE_PLATFORM_BUILDS_RESULT=success \
  RELEASE_RUNTIME_TESTS_RESULT=success RELEASE_SANITIZERS_RESULT=success RELEASE_COVERAGE_RESULT=success \
  "$script_dir/verify-release-prerequisites.sh" >/dev/null
if RELEASE_GATE_RESULT=success RELEASE_PLATFORM_BUILDS_RESULT=skipped \
  RELEASE_RUNTIME_TESTS_RESULT=success RELEASE_SANITIZERS_RESULT=success RELEASE_COVERAGE_RESULT=success \
  "$script_dir/verify-release-prerequisites.sh" >/dev/null 2>&1; then
  echo "Skipped prerequisite must fail" >&2
  exit 1
fi

for coverage_status in missing skipped failure cancelled; do
  if RELEASE_GATE_RESULT=success RELEASE_PLATFORM_BUILDS_RESULT=success \
    RELEASE_RUNTIME_TESTS_RESULT=success RELEASE_SANITIZERS_RESULT=success \
    RELEASE_COVERAGE_RESULT="$coverage_status" \
    "$script_dir/verify-release-prerequisites.sh" >/dev/null 2>&1; then
    echo "Coverage prerequisite must fail: $coverage_status" >&2
    exit 1
  fi
done

echo "[check-release-evidence-workflow-selftest] All checks passed"
