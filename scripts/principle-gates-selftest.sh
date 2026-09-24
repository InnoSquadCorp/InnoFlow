#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/principle-gates-lib.sh"

assert_success() {
  if ! "$@"; then
    echo "[principle-gates-selftest] Expected success: $*"
    exit 1
  fi
}

assert_failure() {
  if "$@"; then
    echo "[principle-gates-selftest] Expected failure: $*"
    exit 1
  fi
}

assert_equals() {
  local actual="$1"
  local expected="$2"
  if [[ "$actual" != "$expected" ]]; then
    echo "[principle-gates-selftest] Expected '$expected' but got '$actual'"
    exit 1
  fi
}

make_fixture_tree() {
  local root="$1"
  mkdir -p "$root/core/Nested" "$root/docs" "$root/sample"

  cat >"$root/core/Nested/Leaky.swift" <<'EOF'
public import SwiftUI
EOF

  cat >"$root/docs/Legacy.md" <<'EOF'
@InnoFlow
struct LegacyFeature {
  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    .none
  }
}
EOF

  cat >"$root/docs/Clean.md" <<'EOF'
@InnoFlow
struct CleanFeature {
  var body: some Reducer<State, Action, Never> {
    Reduce { _, _ in .none }
  }
}
EOF

  cat >"$root/sample/RouterCompositionDemo.swift" <<'EOF'
let path = RouteStack()
EOF

  cat >"$root/sample/Feature.swift" <<'EOF'
let navigator = Navigator()
EOF

  cat >"$root/docs/README.md" <<'EOF'
## InnoFlow 3.0 direction
EOF

  cat >"$root/docs/README.kr.md" <<'EOF'
## InnoFlow 3.0 direction
EOF

  cat >"$root/docs/GettingStarted.md" <<'EOF'
```swift
import SwiftUI
```
EOF

  cat >"$root/docs/SelectedStoreLifecycleGood.md" <<'EOF'
SelectedStore dynamic-member reads use the last valid cached snapshot in optimized builds.
EOF

  cat >"$root/docs/SelectedStoreLifecycleContradiction.md" <<'EOF'
SelectedStore dynamic-member reads trap in release. ScopedStore dynamic-member reads use cached snapshots.
EOF

  cat >"$root/docs/SelectedStoreLifecyclePrefixContradiction.md" <<'EOF'
In release builds, SelectedStore dynamic-member reads trap. ScopedStore dynamic-member reads use cached snapshots.
EOF

  cat >"$root/docs/SelectedStoreLifecycleTieredGood.md" <<'EOF'
SelectedStore dynamic-member reads use cached snapshots in release; use requireAlive() to trap in release.
EOF
}

write_doc_parity_contract() {
  local path="$1"
  local sample_id="$2"

  mkdir -p "$(dirname "$path")"
  cat >"$path" <<EOF
{
  "requiredPatterns": [
    {
      "file": "docs/README.md",
      "label": "direction heading",
      "pattern": "^## InnoFlow 3.0 direction$"
    }
  ],
  "sectionCounts": [
    {
      "file": "docs/README.md",
      "label": "direction heading",
      "pattern": "^## InnoFlow 3.0 direction$",
      "count": 1
    }
  ],
  "readmeCorePatterns": [
    {
      "label": "direction heading",
      "pattern": "^## InnoFlow 3.0 direction$",
      "files": [
        "docs/README.md",
        "docs/README.kr.md"
      ]
    }
  ],
  "localizedHeaderParity": [
    {
      "source": "docs/README.md",
      "headerLevel": "h2",
      "expectedSourceHeaderCount": 1,
      "translations": [
        {
          "file": "docs/README.kr.md",
          "expectedHeaderCount": 1
        }
      ]
    }
  ],
  "sampleIdentifiers": [
    {
      "file": "docs/README.md",
      "values": ["$sample_id"]
    }
  ]
}
EOF
}

run_search_tests() {
  local force_no_rg="$1"
  local mode_name="$2"
  local tmp_root
  tmp_root="$(mktemp -d)"
  trap "rm -rf '$tmp_root'" RETURN
  make_fixture_tree "$tmp_root"

  export PRINCIPLE_GATES_FORCE_NO_RG="$force_no_rg"
  initialize_search_backend

  echo "[principle-gates-selftest] Running search tests in $mode_name mode"

  assert_success search_multiline '@InnoFlow[\s\S]{0,200}struct[\s\S]{0,700}func reduce\(into[^)]*action:' "$tmp_root/docs/Legacy.md"
  assert_failure search_multiline '@InnoFlow[\s\S]{0,200}struct[\s\S]{0,700}func reduce\(into[^)]*action:' "$tmp_root/docs/Clean.md"

  assert_failure search_lines_excluding "RouteStack|NavigationPath|NavigationStore|Navigator" "RouterCompositionDemo|InnoFlowSampleAppRootView" "$tmp_root/sample/RouterCompositionDemo.swift"
  assert_success search_lines_excluding "RouteStack|NavigationPath|NavigationStore|Navigator" "RouterCompositionDemo|InnoFlowSampleAppRootView" "$tmp_root/sample"
  assert_success search_swift_lines '^[[:space:]]*(@_exported[[:space:]]+)?(public[[:space:]]+)?import[[:space:]]+SwiftUI$' "$tmp_root/core"
  assert_failure search_swift_lines '^[[:space:]]*(@_exported[[:space:]]+)?(public[[:space:]]+)?import[[:space:]]+SwiftUI$' "$tmp_root/docs"

  assert_equals "$(count_line_matches '^## InnoFlow 3.0 direction$' "$tmp_root/docs/README.md")" "1"
  assert_success validate_selected_store_dynamic_member_doc "$tmp_root/docs/SelectedStoreLifecycleGood.md"
  assert_failure validate_selected_store_dynamic_member_doc "$tmp_root/docs/SelectedStoreLifecycleContradiction.md"
  assert_failure validate_selected_store_dynamic_member_doc "$tmp_root/docs/SelectedStoreLifecyclePrefixContradiction.md"
  assert_success validate_selected_store_dynamic_member_doc "$tmp_root/docs/SelectedStoreLifecycleTieredGood.md"

  trap - RETURN
  rm -rf "$tmp_root"
}

run_doc_parity_contract_tests() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "[principle-gates-selftest] Skipping doc parity tests because jq is not installed"
    return
  fi

  local tmp_root
  local previous_root
  tmp_root="$(mktemp -d)"
  previous_root="$ROOT_DIR"
  trap "ROOT_DIR='$previous_root'; rm -rf '$tmp_root'" RETURN
  make_fixture_tree "$tmp_root"

  ROOT_DIR="$tmp_root"
  pushd "$tmp_root" >/dev/null

  printf 'sample.basics\n' >>docs/README.md
  write_doc_parity_contract "docs/contracts/doc-parity.json" "sample.basics"
  assert_success verify_doc_parity_contract

  cat >docs/contracts/doc-parity.json <<'EOF'
{
  "sectionCounts": [],
  "sampleIdentifiers": []
}
EOF
  assert_failure verify_doc_parity_contract

  sed -i.bak '$d' docs/README.md
  printf 'sampleXbasics\n' >>docs/README.md
  rm -f docs/README.md.bak
  write_doc_parity_contract "docs/contracts/doc-parity.json" "sample.basics"
  assert_failure verify_doc_parity_contract

  popd >/dev/null
  ROOT_DIR="$previous_root"
  trap - RETURN
  rm -rf "$tmp_root"
}

run_internal_diagnostic_log_tests() {
  local tmp_root
  tmp_root="$(mktemp -d)"
  trap "rm -rf '$tmp_root'" RETURN

  printf 'Build complete\n' >"$tmp_root/clean.log"
  assert_success reject_toolchain_internal_diagnostics "clean log" "$tmp_root/clean.log"

  printf 'Internal Error: DecodingError.dataCorrupted: Corrupted JSON\n' >"$tmp_root/bad.log"
  assert_failure reject_toolchain_internal_diagnostics "bad log" "$tmp_root/bad.log"

  trap - RETURN
  rm -rf "$tmp_root"
}

run_source_preserves_cwd_test() {
  local tmp_root
  tmp_root="$(mktemp -d)"
  trap "rm -rf '$tmp_root'" RETURN

  echo "[principle-gates-selftest] Running source cwd preservation test"
  (
    cd "$tmp_root"
    assert_success bash -c 'set -euo pipefail; before="$PWD"; source "$1"; [[ "$PWD" == "$before" ]]' bash "$SCRIPT_DIR/principle-gates-lib.sh"
  )

  trap - RETURN
  rm -rf "$tmp_root"
}

run_cleanup_trap_isolation_tests() {
  echo "[principle-gates-selftest] Running cleanup trap isolation tests"
  assert_success bash -c '
    set -euo pipefail
    source "$1"

    run_authoring_surface_checks() { :; }
    run_workflow_security_checks() { :; }
    run_sample_static_contract_checks() { :; }
    run_doc_contract_checks() { :; }
    run_authoring_policy_checks() { :; }
    run_release_build_checks() { :; }
    run_release_configuration_checks() { :; }
    run_sample_runtime_contract_checks() { :; }
    run_gate_negative_controls() { :; }

    trap "echo caller-cleanup >/dev/null" EXIT
    before="$(trap -p EXIT)"

    run_principle_gates >/dev/null
    after_principle="$(trap -p EXIT)"
    [[ "$after_principle" == "$before" ]]

    run_sample_contract_checks >/dev/null
    after_sample="$(trap -p EXIT)"
    [[ "$after_sample" == "$before" ]]
  ' bash "$SCRIPT_DIR/principle-gates-lib.sh"
}

run_workflow_action_pin_tests() {
  local tmp_root
  tmp_root="$(mktemp -d)"
  trap 'rm -rf "$tmp_root"' RETURN

  mkdir -p "$tmp_root/workflows"
  cat >"$tmp_root/workflows/pinned.yml" <<'EOF'
steps:
  - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
  - uses: ./local-action
  - uses: docker://alpine:3.22
EOF
  assert_success "$SCRIPT_DIR/check-workflow-action-pins.sh" "$tmp_root/workflows"

  cat >"$tmp_root/workflows/floating.yml" <<'EOF'
steps:
  - uses: actions/checkout@v6
EOF
  assert_failure "$SCRIPT_DIR/check-workflow-action-pins.sh" "$tmp_root/workflows"

  trap - RETURN
  rm -rf "$tmp_root"
}

run_docc_plugin_pin_tests() {
  local tmp_root
  tmp_root="$(mktemp -d)"
  trap 'rm -rf "$tmp_root"' RETURN

  cat >"$tmp_root/generate-docc.sh" <<'EOF'
DOCC_PLUGIN_VERSION="1.5.0"
DOCC_PLUGIN_REVISION="647c708be89f834fa6a6d4945442793a77ddf5b6"
DOCC_SYMBOLKIT_VERSION="1.0.0"
DOCC_SYMBOLKIT_REVISION="b45d1f2ed151d057b54504d653e0da5552844e34"
DOCC_SWIFT_SYNTAX_VERSION="603.0.1"
DOCC_SWIFT_SYNTAX_REVISION="9de99a78f099e59caf2b2beec65a4c45d54b2081"
dependency_line = 'swift-docc-plugin", revision: "{plugin_revision}"'
cp "$DOCC_LOCKFILE" "$DOCS_PACKAGE_DIR/Package.resolved"
--disable-automatic-resolution
--disable-automatic-resolution
EOF
  cat >"$tmp_root/docc-package.resolved" <<'EOF'
{
  "pins": [
    {"identity":"swift-docc-plugin","state":{"revision":"647c708be89f834fa6a6d4945442793a77ddf5b6"}},
    {"identity":"swift-docc-symbolkit","state":{"revision":"b45d1f2ed151d057b54504d653e0da5552844e34","version":"1.0.0"}},
    {"identity":"swift-syntax","state":{"revision":"9de99a78f099e59caf2b2beec65a4c45d54b2081","version":"603.0.1"}}
  ],
  "version": 2
}
EOF
  printf '%s\n' 'Use `swift-docc-plugin` 1.5.0 at revision `647c708be89f834fa6a6d4945442793a77ddf5b6`, `swift-docc-symbolkit` 1.0.0 at revision `b45d1f2ed151d057b54504d653e0da5552844e34`, and `swift-syntax` 603.0.1 at revision `9de99a78f099e59caf2b2beec65a4c45d54b2081`.' >"$tmp_root/RELEASING.md"
  assert_success verify_docc_plugin_pin \
    "$tmp_root/generate-docc.sh" \
    "$tmp_root/RELEASING.md" \
    "$tmp_root/docc-package.resolved"

  sed -i.bak 's/647c708be89f834fa6a6d4945442793a77ddf5b6/too-short/g' "$tmp_root/generate-docc.sh"
  rm -f "$tmp_root/generate-docc.sh.bak"
  assert_failure verify_docc_plugin_pin \
    "$tmp_root/generate-docc.sh" \
    "$tmp_root/RELEASING.md" \
    "$tmp_root/docc-package.resolved"

  cat >"$tmp_root/generate-docc.sh" <<'EOF'
DOCC_PLUGIN_VERSION="1.5.0"
DOCC_PLUGIN_REVISION="647c708be89f834fa6a6d4945442793a77ddf5b6"
DOCC_SYMBOLKIT_VERSION="1.0.0"
DOCC_SYMBOLKIT_REVISION="b45d1f2ed151d057b54504d653e0da5552844e34"
DOCC_SWIFT_SYNTAX_VERSION="603.0.1"
DOCC_SWIFT_SYNTAX_REVISION="9de99a78f099e59caf2b2beec65a4c45d54b2081"
dependency_line = 'swift-docc-plugin", exact: "{plugin_version}"'
cp "$DOCC_LOCKFILE" "$DOCS_PACKAGE_DIR/Package.resolved"
--disable-automatic-resolution
--disable-automatic-resolution
EOF
  assert_failure verify_docc_plugin_pin \
    "$tmp_root/generate-docc.sh" \
    "$tmp_root/RELEASING.md" \
    "$tmp_root/docc-package.resolved"

  sed -i.bak 's/swift-docc-plugin\", exact: \"{plugin_version}\"/swift-docc-plugin\", revision: \"{plugin_revision}\"/' "$tmp_root/generate-docc.sh"
  rm -f "$tmp_root/generate-docc.sh.bak"
  sed -i.bak 's/b45d1f2ed151d057b54504d653e0da5552844e34/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' "$tmp_root/docc-package.resolved"
  rm -f "$tmp_root/docc-package.resolved.bak"
  assert_failure verify_docc_plugin_pin \
    "$tmp_root/generate-docc.sh" \
    "$tmp_root/RELEASING.md" \
    "$tmp_root/docc-package.resolved"

  trap - RETURN
  rm -rf "$tmp_root"
}

run_release_tag_policy_tests() {
  local tmp_root
  local original_dir
  source "$SCRIPT_DIR/release-tag-policy.sh"
  tmp_root="$(mktemp -d)"
  original_dir="$PWD"
  trap 'cd "$original_dir"; rm -rf "$tmp_root"' RETURN

  cd "$tmp_root"
  git init -q
  git config user.name "InnoFlow Selftest"
  git config user.email "selftest@invalid.example"
  printf 'release\n' >fixture
  git add fixture
  git commit -qm "release fixture"

  assert_failure require_release_tag_at_head "6.0.0"
  git tag 6.0.0
  assert_success require_release_tag_at_head "6.0.0"
  git tag -a 6.0.1 -m "annotated fixture"
  assert_success require_release_tag_at_head "6.0.1"
  git tag 7.0.0
  assert_success require_release_tag_at_head "6.0.0"

  assert_failure bash -c 'source "$1"; GITHUB_REF_TYPE=tag GITHUB_REF_NAME=5.1.1 require_release_tag_at_head 6.0.0' bash "$SCRIPT_DIR/release-tag-policy.sh"
  assert_success bash -c 'source "$1"; GITHUB_REF_TYPE=tag GITHUB_REF_NAME=6.0.0 require_release_tag_at_head 6.0.0' bash "$SCRIPT_DIR/release-tag-policy.sh"

  local invalid_tag
  for invalid_tag in v6.0.0 6.0.0-rc.1 6.0.0+build.1 6.0 06.0.0 6.00.0 release.6.0.0 foo.bar.baz; do
    assert_failure is_strict_release_tag "$invalid_tag"
  done

  printf 'next\n' >>fixture
  git add fixture
  git commit -qm "move head"
  assert_failure require_release_tag_at_head "6.0.0"

  cd "$original_dir"
  trap - RETURN
  rm -rf "$tmp_root"
}

run_workflow_job_timeout_tests() {
  local tmp_root
  tmp_root="$(mktemp -d)"
  trap 'rm -rf "$tmp_root"' RETURN

  mkdir -p "$tmp_root/workflows"
  cat >"$tmp_root/workflows/good.yml" <<'EOF'
jobs:
  build:
    runs-on: macos-26
    timeout-minutes: 30
    steps: []
EOF
  assert_success "$SCRIPT_DIR/check-workflow-job-timeouts.sh" "$tmp_root/workflows"

  cat >"$tmp_root/workflows/caller.yml" <<'EOF'
jobs:
  call:
    uses: ./.github/workflows/good.yml
EOF
  assert_success "$SCRIPT_DIR/check-workflow-job-timeouts.sh" "$tmp_root/workflows"
  cat >"$tmp_root/workflows/caller.yml" <<'EOF'
jobs:
  call:
    uses: ./.github/workflows/missing.yml
EOF
  assert_failure "$SCRIPT_DIR/check-workflow-job-timeouts.sh" "$tmp_root/workflows"
  cat >"$tmp_root/workflows/caller.yml" <<'EOF'
jobs:
  call:
    uses: ./.github/workflows/good.yml
    timeout-minutes: 30
EOF
  assert_failure "$SCRIPT_DIR/check-workflow-job-timeouts.sh" "$tmp_root/workflows"
  rm "$tmp_root/workflows/caller.yml"

  cat >"$tmp_root/workflows/bad.yml" <<'EOF'
jobs:
  build:
    runs-on: macos-26
    steps: []
EOF
  assert_failure "$SCRIPT_DIR/check-workflow-job-timeouts.sh" "$tmp_root/workflows"

  trap - RETURN
  rm -rf "$tmp_root"
}

run_api_compatibility_mode_tests() {
  local tmp_root
  tmp_root="$(mktemp -d)"
  trap 'rm -rf "$tmp_root"' RETURN

  mkdir -p "$tmp_root/scripts"
  cp "$SCRIPT_DIR/check-api-compatibility.sh" "$tmp_root/scripts/"
  chmod +x "$tmp_root/scripts/check-api-compatibility.sh"
  git -C "$tmp_root" init -q

  printf '5.1.1\n' >"$tmp_root/STABLE_VERSION"
  assert_success "$tmp_root/scripts/check-api-compatibility.sh"

  printf '6.0.0\n' >"$tmp_root/STABLE_VERSION"
  assert_failure "$tmp_root/scripts/check-api-compatibility.sh"

  printf 'invalid\n' >"$tmp_root/STABLE_VERSION"
  assert_failure "$tmp_root/scripts/check-api-compatibility.sh"

  trap - RETURN
  rm -rf "$tmp_root"
}

run_release_sync_lifecycle_tests() {
  local tmp_root
  tmp_root="$(mktemp -d)"
  trap 'rm -rf "$tmp_root"' RETURN
  mkdir -p "$tmp_root/scripts"
  cp "$SCRIPT_DIR/check-release-sync.sh" "$SCRIPT_DIR/release-tag-policy.sh" "$tmp_root/scripts/"
  cp "$ROOT_DIR/STABLE_VERSION" "$ROOT_DIR/RELEASING.md" "$ROOT_DIR/README.md" \
    "$ROOT_DIR/README.kr.md" "$ROOT_DIR/README.jp.md" "$ROOT_DIR/README.cn.md" \
    "$ROOT_DIR/RELEASE_NOTES.md" "$ROOT_DIR/CHANGELOG.md" "$ROOT_DIR/MIGRATION.md" \
    "$ROOT_DIR/ARCHITECTURE_CONTRACT.md" "$tmp_root/"
  git -C "$tmp_root" init -q
  git -C "$tmp_root" config user.name "InnoFlow Selftest"
  git -C "$tmp_root" config user.email "selftest@invalid.example"
  git -C "$tmp_root" add .
  git -C "$tmp_root" commit -qm "candidate fixture"

  assert_success env ROOT_DIR="$tmp_root" INNOFLOW_RELEASE_VERSION=6.0.0 \
    "$tmp_root/scripts/check-release-sync.sh"
  assert_failure env ROOT_DIR="$tmp_root" INNOFLOW_RELEASE_VERSION=6.0.0 \
    INNOFLOW_REQUIRE_RELEASE_TAG=1 "$tmp_root/scripts/check-release-sync.sh"
  printf '999999999999999999999999999999.0.0\n' >"$tmp_root/STABLE_VERSION"
  assert_failure env ROOT_DIR="$tmp_root" INNOFLOW_RELEASE_VERSION=6.0.0 \
    "$tmp_root/scripts/check-release-sync.sh"
  printf '5.1.1\n' >"$tmp_root/STABLE_VERSION"
  git -C "$tmp_root" tag 6.0.0
  assert_success env ROOT_DIR="$tmp_root" INNOFLOW_RELEASE_VERSION=6.0.0 \
    INNOFLOW_REQUIRE_RELEASE_TAG=1 "$tmp_root/scripts/check-release-sync.sh"
  assert_failure env ROOT_DIR="$tmp_root" GITHUB_REF_TYPE=tag GITHUB_REF_NAME=5.1.1 \
    INNOFLOW_RELEASE_VERSION=6.0.0 INNOFLOW_REQUIRE_RELEASE_TAG=1 \
    "$tmp_root/scripts/check-release-sync.sh"
  printf '6.0.0\n' >"$tmp_root/STABLE_VERSION"
  assert_failure env ROOT_DIR="$tmp_root" INNOFLOW_RELEASE_VERSION=6.0.0 \
    INNOFLOW_REQUIRE_RELEASE_TAG=1 "$tmp_root/scripts/check-release-sync.sh"
  ruby -e 'path=ARGV.fetch(0); body=File.read(path); old="Current stable public release: `5.1.1`"; abort "missing fixture marker" unless body.include?(old); File.write(path, body.sub(old, "Current stable public release: `6.0.0`"))' \
    "$tmp_root/RELEASING.md"
  git -C "$tmp_root" add STABLE_VERSION RELEASING.md
  git -C "$tmp_root" commit -qm "post-publication metadata fixture"
  assert_success env ROOT_DIR="$tmp_root" INNOFLOW_RELEASE_VERSION=6.0.0 \
    "$tmp_root/scripts/check-release-sync.sh"
  assert_failure env ROOT_DIR="$tmp_root" INNOFLOW_RELEASE_VERSION=6.0.0 \
    INNOFLOW_REQUIRE_RELEASE_TAG=1 "$tmp_root/scripts/check-release-sync.sh"

  trap - RETURN
  rm -rf "$tmp_root"
}

run_release_test_command_tests() {
  local tmp_root
  tmp_root="$(mktemp -d)"
  trap 'rm -rf "$tmp_root"' RETURN

  cat >"$tmp_root/RELEASING.md" <<'EOF'
`swift test --jobs 1 --no-parallel -Xswiftc -warnings-as-errors`
`swift test -c release --jobs 1 --no-parallel -Xswiftc -warnings-as-errors`
EOF
  assert_success verify_release_test_commands "$tmp_root/RELEASING.md"

  sed -i.bak 's/ --no-parallel//' "$tmp_root/RELEASING.md"
  rm -f "$tmp_root/RELEASING.md.bak"
  assert_failure verify_release_test_commands "$tmp_root/RELEASING.md"

  trap - RETURN
  rm -rf "$tmp_root"
}

run_release_configuration_split_tests() {
  local tmp_root
  tmp_root="$(mktemp -d)"
  trap 'rm -rf "$tmp_root"' RETURN

  assert_success bash -c '
    set -euo pipefail
    source "$1"
    ROOT_DIR="$2/package"
    command_log="$2/commands.log"
    RELEASE_GATE_BUILD_PATH=""
    mkdir -p "$ROOT_DIR"
    SWIFTPM_JOBS=1
    SWIFT_FRONTEND_THREAD_FLAGS=(-Xswiftc -num-threads -Xswiftc 1)
    warn_if_optimize_none_workaround_should_be_retested() { :; }
    ensure_principle_gate_context() { :; }
    run_low_priority() { printf "%s\n" "$*" >>"$command_log"; }
    run_release_configuration_checks
    [[ "$(wc -l <"$command_log" | tr -d " ")" == "3" ]]
    [[ "$(grep -c -- "-c release" "$command_log")" == "3" ]]
    [[ "$(grep -c -- "--filter EffectTimingBaselineGate" "$command_log")" == "1" ]]
  ' bash "$SCRIPT_DIR/principle-gates-lib.sh" "$tmp_root"

  trap - RETURN
  rm -rf "$tmp_root"
}

run_source_preserves_cwd_test
run_cleanup_trap_isolation_tests
run_workflow_action_pin_tests
run_docc_plugin_pin_tests
run_release_tag_policy_tests
run_workflow_job_timeout_tests
run_api_compatibility_mode_tests
run_release_sync_lifecycle_tests
run_release_test_command_tests
run_release_configuration_split_tests
assert_success "$SCRIPT_DIR/principle-gates.sh" --help
assert_failure "$SCRIPT_DIR/principle-gates.sh" --unknown
assert_failure "$SCRIPT_DIR/principle-gates.sh" --static --unexpected
assert_success "$SCRIPT_DIR/verify-release-evidence-selftest.sh"
assert_success "$SCRIPT_DIR/run-release-preflight-selftest.sh"
assert_success "$SCRIPT_DIR/report-public-api-inventory-selftest.rb"
assert_success "$SCRIPT_DIR/inventory-doc-swift-blocks-selftest.rb"
assert_success "$SCRIPT_DIR/check-migration-consumer-selftest.sh"
assert_success ruby "$SCRIPT_DIR/release-evidence-artifact-selftest.rb"
assert_success ruby "$SCRIPT_DIR/release-evidence-output-parser-selftest.rb"
assert_success bash "$SCRIPT_DIR/check-release-evidence-policy-selftest.sh"
assert_success bash "$SCRIPT_DIR/check-required-ci-results-selftest.sh"
assert_success "$SCRIPT_DIR/check-release-evidence-workflow-selftest.sh"
assert_success "$SCRIPT_DIR/write-github-evidence-provenance-selftest.sh"
assert_success "$SCRIPT_DIR/verify-github-evidence-run-selftest.sh"
assert_success "$SCRIPT_DIR/run-swift-toolchain-evidence-selftest.sh"
assert_success "$SCRIPT_DIR/run-focused-platform-runtime-matrix-selftest.sh"
assert_success "$SCRIPT_DIR/run-focused-platform-runtime-tests-selftest.sh"
assert_success bash "$SCRIPT_DIR/run-sdk-platform-build-selftest.sh"
assert_success ruby "$SCRIPT_DIR/check-sample-concurrency-snippet.rb"
assert_success "$SCRIPT_DIR/release-candidate-snapshot-selftest.sh"
assert_success env PYTHONDONTWRITEBYTECODE=1 python3 "$SCRIPT_DIR/coverage-selftest.py"
assert_success bash "$SCRIPT_DIR/check-coverage-workflow-selftest.sh"
assert_success bash "$SCRIPT_DIR/check-ci-efficiency-selftest.sh"

if command -v rg >/dev/null 2>&1; then
  run_search_tests "0" "rg"
else
  echo "[principle-gates-selftest] Skipping rg mode because rg is not installed"
fi

run_search_tests "1" "fallback"
run_doc_parity_contract_tests
run_internal_diagnostic_log_tests

echo "[principle-gates-selftest] All checks passed"
