#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/principle-gates.sh"

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
  mkdir -p "$root/docs" "$root/sample"

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
  var body: some Reducer<State, Action> {
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

  assert_equals "$(count_line_matches '^## InnoFlow 3.0 direction$' "$tmp_root/docs/README.md")" "1"

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

if command -v rg >/dev/null 2>&1; then
  run_search_tests "0" "rg"
else
  echo "[principle-gates-selftest] Skipping rg mode because rg is not installed"
fi

run_search_tests "1" "fallback"
run_doc_parity_contract_tests
run_internal_diagnostic_log_tests

echo "[principle-gates-selftest] All checks passed"
