#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CANONICAL_ROOT_DIR=""
SWIFTPM_JOBS="${PRINCIPLE_GATES_SWIFTPM_JOBS:-1}"
PROCESS_NICE="${PRINCIPLE_GATES_NICE:-15}"
SWIFT_FRONTEND_THREADS="${PRINCIPLE_GATES_SWIFT_FRONTEND_THREADS:-1}"
SWIFT_FRONTEND_THREAD_FLAGS=()
if [[ "$SWIFT_FRONTEND_THREADS" != "0" ]]; then
  SWIFT_FRONTEND_THREAD_FLAGS=(-Xswiftc -num-threads -Xswiftc "$SWIFT_FRONTEND_THREADS")
fi

cd "$ROOT_DIR"

HAS_RG=0
RG_BIN=""

cleanup_temp_dirs() {
  if [[ -n "$CANONICAL_ROOT_DIR" ]]; then
    rm -rf "$(dirname "$CANONICAL_ROOT_DIR")"
  fi
}

canonical_root_for_sample_package_tests() {
  if [[ "$(basename "$ROOT_DIR")" == "InnoFlow" ]]; then
    printf '%s\n' "$ROOT_DIR"
    return
  fi

  if [[ -n "$CANONICAL_ROOT_DIR" ]]; then
    printf '%s\n' "$CANONICAL_ROOT_DIR"
    return
  fi

  local temp_parent
  temp_parent="$(mktemp -d "${TMPDIR:-/tmp}/innoflow-principle-gates.XXXXXX")"
  CANONICAL_ROOT_DIR="$temp_parent/InnoFlow"
  mkdir -p "$CANONICAL_ROOT_DIR"

  if command -v rsync >/dev/null 2>&1; then
    rsync -a \
      --delete \
      --exclude '.build' \
      --exclude '.build-*' \
      --exclude '.git' \
      --exclude 'Repro' \
      "$ROOT_DIR/" "$CANONICAL_ROOT_DIR/"
  else
    ditto "$ROOT_DIR" "$CANONICAL_ROOT_DIR"
    find "$CANONICAL_ROOT_DIR" -maxdepth 1 -type d -name '.build*' -exec rm -rf {} +
    rm -rf \
      "$CANONICAL_ROOT_DIR/.git" \
      "$CANONICAL_ROOT_DIR/Repro"
  fi

  printf '%s\n' "$CANONICAL_ROOT_DIR"
}

initialize_search_backend() {
  if [[ "${PRINCIPLE_GATES_FORCE_NO_RG:-0}" == "1" ]]; then
    HAS_RG=0
    RG_BIN=""
    return
  fi

  if RG_BIN="$(command -v rg 2>/dev/null)"; then
    HAS_RG=1
  else
    HAS_RG=0
    RG_BIN=""
  fi
}

enumerate_target_files() {
  local target
  for target in "$@"; do
    if [[ -d "$target" ]]; then
      find "$target" -type f | sort
    elif [[ -e "$target" ]]; then
      printf '%s\n' "$target"
    fi
  done
}

enumerate_swift_files() {
  local target
  for target in "$@"; do
    if [[ -d "$target" ]]; then
      find "$target" -type f -name '*.swift' | sort
    elif [[ -f "$target" && "$target" == *.swift ]]; then
      printf '%s\n' "$target"
    fi
  done
}

search_lines() {
  local pattern="$1"
  shift

  if [[ "$HAS_RG" == "1" ]]; then
    "$RG_BIN" -H -n -- "$pattern" "$@"
    return $?
  fi

  local matched=1
  local file
  while IFS= read -r file; do
    if grep -Hn -E -- "$pattern" "$file"; then
      matched=0
    fi
  done < <(enumerate_target_files "$@")
  return "$matched"
}

search_swift_lines() {
  local pattern="$1"
  shift

  if [[ "$HAS_RG" == "1" ]]; then
    "$RG_BIN" -H -n --glob '*.swift' -- "$pattern" "$@"
    return $?
  fi

  local matched=1
  local file
  while IFS= read -r file; do
    if grep -Hn -E -- "$pattern" "$file"; then
      matched=0
    fi
  done < <(enumerate_swift_files "$@")
  return "$matched"
}

search_multiline() {
  local pattern="$1"
  shift

  if [[ "$HAS_RG" == "1" ]]; then
    "$RG_BIN" -n -U -Pzo -- "$pattern" "$@"
    return $?
  fi

  local matched=1
  local file
  while IFS= read -r file; do
    if SEARCH_PATTERN="$pattern" perl -0ne '
      BEGIN { $matched = 0 }
      if (/$ENV{SEARCH_PATTERN}/ms) {
        print "$ARGV\n";
        $matched = 1;
        last;
      }
      END { exit($matched ? 0 : 1) }
    ' "$file"; then
      matched=0
    fi
  done < <(enumerate_target_files "$@")
  return "$matched"
}

run_low_priority() {
  if [[ "$PROCESS_NICE" == "0" ]]; then
    "$@"
  else
    nice -n "$PROCESS_NICE" "$@"
  fi
}

search_lines_excluding() {
  local include_pattern="$1"
  local exclude_pattern="$2"
  shift 2

  local output
  output="$(search_lines "$include_pattern" "$@" || true)"
  if [[ -z "$output" ]]; then
    return 1
  fi

  local filtered
  filtered="$(printf '%s\n' "$output" | grep -E -v -- "$exclude_pattern" || true)"
  if [[ -z "$filtered" ]]; then
    return 1
  fi

  printf '%s\n' "$filtered"
}

reject_toolchain_internal_diagnostics() {
  local label="$1"
  local log_file="$2"

  if grep -E "Internal Error:|DecodingError\\.dataCorrupted|Corrupted JSON" "$log_file" >/dev/null; then
    echo "[principle-gates] Failed: $label emitted Swift toolchain internal diagnostics"
    grep -E "Internal Error:|DecodingError\\.dataCorrupted|Corrupted JSON" "$log_file" || true
    return 1
  fi
}

run_logged_gate_command() {
  local label="$1"
  shift

  local log_file
  log_file="$(mktemp "${TMPDIR:-/tmp}/innoflow-principle-gate-log.XXXXXX")"

  if ! "$@" >"$log_file" 2>&1; then
    cat "$log_file"
    echo "[principle-gates] Failed: $label command failed"
    rm -f "$log_file"
    return 1
  fi

  if ! reject_toolchain_internal_diagnostics "$label" "$log_file"; then
    cat "$log_file"
    rm -f "$log_file"
    return 1
  fi

  rm -f "$log_file"
}

require_pattern_in_every_file() {
  local pattern="$1"
  shift
  local label="docs/DEPENDENCY_PATTERNS.md"

  if [[ "${1:-}" == "--label" ]]; then
    shift
    label="${1:-$label}"
    shift || true
  fi

  local file
  for file in "$@"; do
    if [[ ! -f "$file" ]]; then
      echo "[principle-gates] Failed: $file not found"
      return 1
    fi
    if ! search_lines "$pattern" "$file" >/dev/null; then
      echo "[principle-gates] Failed: $file must link to $label"
      return 1
    fi
  done
}

count_line_matches() {
  local pattern="$1"
  shift

  local output
  output="$(search_lines "$pattern" "$@" || true)"
  if [[ -z "$output" ]]; then
    echo 0
    return
  fi

  printf '%s\n' "$output" | sed '/^$/d' | wc -l | tr -d ' '
}

warn_if_optimize_none_workaround_should_be_retested() {
  local version_line
  version_line="$(swift --version 2>/dev/null | head -n 1 || true)"

  if [[ "$version_line" =~ Swift\ version\ ([0-9]+)\.([0-9]+) ]]; then
    local major="${BASH_REMATCH[1]}"
    local minor="${BASH_REMATCH[2]}"
    if (( major > 6 || (major == 6 && minor >= 4) )); then
      echo "[principle-gates] Warning: Swift ${major}.${minor} detected; retest removing @_optimize(none) from Store/TestStore deinits (swiftlang/swift#88173)."
    fi
  fi
}

validate_doc_parity_contract_shape() {
  local contract_path="$1"

  jq -e '
    def non_empty_array($name):
      has($name) and (.[$name] | type == "array") and (.[$name] | length > 0);
    def typed_field($name; $kind):
      has($name) and (.[$name] | type == $kind);

    non_empty_array("requiredPatterns")
    and non_empty_array("sectionCounts")
    and non_empty_array("readmeCorePatterns")
    and non_empty_array("localizedHeaderParity")
    and non_empty_array("sampleIdentifiers")
    and all(
      .requiredPatterns[];
      typed_field("file"; "string")
      and typed_field("label"; "string")
      and typed_field("pattern"; "string")
    )
    and all(
      .sectionCounts[];
      typed_field("file"; "string")
      and typed_field("label"; "string")
      and typed_field("pattern"; "string")
      and typed_field("count"; "number")
    )
    and all(
      .readmeCorePatterns[];
      typed_field("label"; "string")
      and typed_field("pattern"; "string")
      and has("files")
      and (.files | type == "array")
      and (.files | length > 0)
      and all(.files[]; type == "string")
    )
    and all(
      .localizedHeaderParity[];
      typed_field("source"; "string")
      and typed_field("headerLevel"; "string")
      and typed_field("expectedSourceHeaderCount"; "number")
      and has("translations")
      and (.translations | type == "array")
      and (.translations | length > 0)
      and all(
        .translations[];
        typed_field("file"; "string")
        and typed_field("expectedHeaderCount"; "number")
      )
    )
    and all(
      .sampleIdentifiers[];
      typed_field("file"; "string")
      and has("values")
      and (.values | type == "array")
      and (.values | length > 0)
      and all(.values[]; type == "string")
    )
  ' "$contract_path" >/dev/null
}

verify_doc_parity_contract() {
  local contract_path="docs/contracts/doc-parity.json"

  if [[ ! -f "$contract_path" ]]; then
    echo "[principle-gates] Failed: $contract_path is missing"
    return 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "[principle-gates] Failed: jq is required to evaluate $contract_path"
    return 1
  fi

  if ! validate_doc_parity_contract_shape "$contract_path"; then
    echo "[principle-gates] Failed: $contract_path has an invalid contract shape"
    return 1
  fi

  local item
  local file
  local label
  local pattern
  while IFS= read -r item; do
    file="$(jq -r '.file' <<<"$item")"
    label="$(jq -r '.label' <<<"$item")"
    pattern="$(jq -r '.pattern' <<<"$item")"
    if [[ ! -f "$file" ]]; then
      echo "[principle-gates] Failed: $file not found"
      return 1
    fi
    if ! search_lines "$pattern" "$file" >/dev/null; then
      echo "[principle-gates] Failed: $file must include $label"
      return 1
    fi
  done < <(jq -c '.requiredPatterns[]' "$contract_path")

  local expected_count
  local actual_count
  while IFS= read -r item; do
    file="$(jq -r '.file' <<<"$item")"
    label="$(jq -r '.label' <<<"$item")"
    pattern="$(jq -r '.pattern' <<<"$item")"
    expected_count="$(jq -r '.count' <<<"$item")"
    if [[ ! -f "$file" ]]; then
      echo "[principle-gates] Failed: $file not found"
      return 1
    fi
    actual_count="$(count_line_matches "$pattern" "$file")"
    if [[ "$actual_count" != "$expected_count" ]]; then
      echo "[principle-gates] Failed: expected $file to contain exactly $expected_count '$label' section(s)"
      return 1
    fi
  done < <(jq -c '.sectionCounts[]' "$contract_path")

  local readme_file
  while IFS= read -r item; do
    label="$(jq -r '.label' <<<"$item")"
    pattern="$(jq -r '.pattern' <<<"$item")"
    while IFS= read -r readme_file; do
      if [[ ! -f "$readme_file" ]]; then
        echo "[principle-gates] Failed: $readme_file not found"
        return 1
      fi
      if ! search_lines "$pattern" "$readme_file" >/dev/null; then
        echo "[principle-gates] Failed: $readme_file must include README core pattern '$label'"
        return 1
      fi
    done < <(jq -r '.files[]' <<<"$item")
  done < <(jq -c '.readmeCorePatterns[]' "$contract_path")

  local sample_id
  while IFS= read -r item; do
    file="$(jq -r '.file' <<<"$item")"
    if [[ ! -f "$file" ]]; then
      echo "[principle-gates] Failed: $file not found"
      return 1
    fi
    while IFS= read -r sample_id; do
      if ! grep -F -q -- "$sample_id" "$file"; then
        echo "[principle-gates] Failed: $file must mention sample identifier $sample_id"
        return 1
      fi
    done < <(jq -r '.values[]' <<<"$item")
  done < <(jq -c '.sampleIdentifiers[]' "$contract_path")
}

DOC_AND_SAMPLE_PATHS=()
MARKDOWN_DOC_PATHS=()

configure_principle_gate_paths() {
  DOC_AND_SAMPLE_PATHS=(
    "README.md"
    "CLAUDE.md"
    "AGENTS.md"
    "ARCHITECTURE_CONTRACT.md"
    "CONTRIBUTING.md"
    "ARCHITECTURE_REVIEW.md"
    "PHASE_DRIVEN_MODELING.md"
    "docs/adr"
    "Sources/InnoFlow/InnoFlow.docc"
    "Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage/Sources"
  )

  MARKDOWN_DOC_PATHS=(
    "README.md"
    "README.kr.md"
    "README.jp.md"
    "README.cn.md"
    "ARCHITECTURE_CONTRACT.md"
    "CHANGELOG.md"
    "RELEASE_NOTES.md"
    "MIGRATION.md"
    "RELEASING.md"
    "docs"
    "Sources/InnoFlow/InnoFlow.docc"
    "Examples/README.md"
    "Examples/InnoFlowSampleApp/README.md"
  )
}

ensure_principle_gate_context() {
  initialize_search_backend
  cd "$ROOT_DIR"
  configure_principle_gate_paths
}

run_authoring_surface_checks() {
  ensure_principle_gate_context

  echo "[principle-gates] Checking legacy @InnoFlow explicit reducer authoring"
  if search_multiline '@InnoFlow[\s\S]{0,200}struct[\s\S]{0,700}func reduce\(into[^)]*action:' "${DOC_AND_SAMPLE_PATHS[@]}"; then
    echo "[principle-gates] Failed: legacy explicit reducer authoring found in docs or sample sources"
    exit 1
  fi

  echo "[principle-gates] Checking binding authoring contract"
  # `store.binding(\.$field, to: Feature.Action.setX)` is the preferred spelling;
  # `send:` remains supported indefinitely as a semantic alias. The projected
  # key-path check below is what the gate actually enforces — argument label is
  # left to idiomatic judgment.
  if search_lines "BindableProperty\\(" "${DOC_AND_SAMPLE_PATHS[@]}"; then
    echo "[principle-gates] Failed: docs or canonical sample still author state with direct BindableProperty"
    exit 1
  fi
  if search_lines_excluding "binding\\(\\\\\\.[A-Za-z_][A-Za-z0-9_]*" "binding\\(\\\\\\.\\$" "${DOC_AND_SAMPLE_PATHS[@]}"; then
    echo "[principle-gates] Failed: docs or canonical sample use non-projected binding key paths"
    exit 1
  fi
  if ! search_lines "@BindableField" README.md Sources/InnoFlow/InnoFlow.docc Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage/Sources >/dev/null; then
    echo "[principle-gates] Failed: expected @BindableField examples in docs or canonical sample"
    exit 1
  fi
  if search_lines "static let [A-Za-z_][A-Za-z0-9_]*(CasePath|ActionPath) = (CasePath|CollectionActionPath)<" "${DOC_AND_SAMPLE_PATHS[@]}"; then
    echo "[principle-gates] Failed: docs or canonical sample still manually define synthesized action paths"
    exit 1
  fi
  if search_lines "_ReducerBuilder[A-Za-z]+" README.md CLAUDE.md AGENTS.md CONTRIBUTING.md ARCHITECTURE_CONTRACT.md Sources/InnoFlow/InnoFlow.docc Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage/Sources; then
    echo "[principle-gates] Failed: docs or canonical sample expose builder implementation types"
    exit 1
  fi
  if search_lines "_ReducerSequence|_OptionalReducer|_ConditionalReducer|_ArrayReducer|_EmptyReducer" "${DOC_AND_SAMPLE_PATHS[@]}"; then
    echo "[principle-gates] Failed: docs or canonical sample expose builder-internal composition types"
    exit 1
  fi
  if search_lines "extractAction|embedAction" "${DOC_AND_SAMPLE_PATHS[@]}"; then
    echo "[principle-gates] Failed: docs or canonical sample still mention closure-based scoping hooks"
    exit 1
  fi

  echo "[principle-gates] Checking Markdown .run throwing snippets"
  if search_multiline '\.run[[:space:]]*\{[^\n}]*\bin(?![ \t]+do[ \t]*\{)[^\n}]*try[ \t]+await' "${MARKDOWN_DOC_PATHS[@]}"; then
    echo "[principle-gates] Failed: Markdown docs must wrap throwing .run work in do/catch"
    exit 1
  fi
  if search_multiline '\.run[[:space:]]*\{[^\n}]*\bin[ \t]*\n(?![ \t]*do[ \t]*\{)(?:(?!\n[ \t]*do[ \t]*\{)[^}])*try[ \t]+await' "${MARKDOWN_DOC_PATHS[@]}"; then
    echo "[principle-gates] Failed: Markdown docs must wrap throwing .run work in do/catch"
    exit 1
  fi

  echo "[principle-gates] Checking official composition primitives"
  search_lines "public struct Reduce<" Sources/InnoFlowCore/ReducerComposition.swift >/dev/null
  search_lines "public struct CombineReducers<" Sources/InnoFlowCore/ReducerComposition.swift >/dev/null
  search_lines "public struct Scope<" Sources/InnoFlowCore/ReducerComposition.swift >/dev/null
  search_lines "public struct IfLet<" Sources/InnoFlowCore/ReducerComposition.swift >/dev/null
  search_lines "public struct IfCaseLet<" Sources/InnoFlowCore/ReducerComposition.swift >/dev/null
  search_lines "public struct ForEachReducer<" Sources/InnoFlowCore/ReducerComposition.swift >/dev/null
  search_lines "public struct StoreClock" Sources/InnoFlowCore/StoreClock.swift >/dev/null
  search_lines "public struct StoreInstrumentation" Sources/InnoFlowCore/StoreInstrumentation.swift >/dev/null
  search_lines "public final class SelectedStore<" Sources/InnoFlowCore/SelectedStore.swift >/dev/null
  search_lines "public struct EffectContext" Sources/InnoFlowCore/EffectTask.swift >/dev/null
  search_lines "public actor ManualTestClock" Sources/InnoFlowTesting/ManualTestClock.swift >/dev/null
  search_lines "public static func preview\\(" Sources/InnoFlowSwiftUI/Store+SwiftUIPreviews.swift >/dev/null
  search_lines "public func map<" Sources/InnoFlowCore/EffectTask.swift >/dev/null
  search_lines 'name: "InnoFlowSwiftUI"' Package.swift >/dev/null
  if search_swift_lines '^[[:space:]]*(@_exported[[:space:]]+)?(public[[:space:]]+)?import[[:space:]]+SwiftUI$' Sources/InnoFlowCore Sources/InnoFlow >/dev/null; then
    echo "[principle-gates] Failed: InnoFlowCore and the InnoFlow facade must not import SwiftUI"
    exit 1
  fi
  if ! search_multiline 'public func select<[\s\S]{0,220}dependingOn dependency:' Sources/InnoFlowCore/SelectedStore.swift >/dev/null; then
    echo "[principle-gates] Failed: SelectedStore dependency-annotated selection overload is missing"
    exit 1
  fi
  if ! search_multiline 'public func select<each Dep: Equatable & Sendable[\s\S]{0,200}dependingOnAll dependencies:\s*repeat KeyPath<' Sources/InnoFlowCore/SelectedStore.swift >/dev/null; then
    echo "[principle-gates] Failed: SelectedStore variadic dependingOnAll overload is missing"
    exit 1
  fi
  if search_multiline 'public init\([\s\S]{0,240}extractAction:\s*@escaping' Sources/InnoFlowCore/ReducerComposition.swift; then
    echo "[principle-gates] Failed: reducer composition still exposes public closure-based action lifting"
    exit 1
  fi
  if search_multiline 'public func scope<[\s\S]{0,280}action:\s*@escaping\s*@Sendable' Sources/InnoFlowCore/ScopedStore.swift; then
    echo "[principle-gates] Failed: Store.scope still exposes public closure-based action lifting"
    exit 1
  fi
  if search_multiline 'public func scope<[\s\S]{0,320}extractAction:\s*@escaping' Sources/InnoFlowTesting/TestStore.swift; then
    echo "[principle-gates] Failed: TestStore.scope still exposes public closure-based action lifting"
    exit 1
  fi
}

run_sample_static_contract_checks() {
  ensure_principle_gate_context

  echo "[principle-gates] Checking canonical sample app only"
  local sample_root_view="Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage/Sources/InnoFlowSampleAppFeature/InnoFlowSampleAppRootView.swift"
  local sample_catalog="Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage/Sources/InnoFlowSampleAppFeature/SampleCatalog.swift"
  local -a canonical_sample_ids=(
    'sample\.basics'
    'sample\.orchestration'
    'sample\.phase-driven-fsm'
    'sample\.router-composition'
    'sample\.authentication-flow'
    'sample\.list-detail-pagination'
    'sample\.offline-first'
    'sample\.realtime-stream'
    'sample\.form-validation'
    'sample\.bidirectional-websocket'
  )
  if [[ -d "Examples/CounterApp" || -d "Examples/TodoApp" ]]; then
    echo "[principle-gates] Failed: legacy example apps still exist"
    exit 1
  fi
  if [[ ! -d "Examples/InnoFlowSampleApp" ]]; then
    echo "[principle-gates] Failed: canonical sample app is missing"
    exit 1
  fi
  if search_lines "InnoFlowDIBridge|FeatureDependencies|import InnoDI|import InnoRouter" README.md ARCHITECTURE_CONTRACT.md Sources/InnoFlow/InnoFlow.docc Examples/README.md Examples/InnoFlowSampleApp/README.md Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage/Sources Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage/Package.swift; then
    echo "[principle-gates] Failed: canonical docs or sample still reference removed bridge/extra libraries"
    exit 1
  fi
  local sample_id
  for sample_id in "${canonical_sample_ids[@]}"; do
    search_lines "$sample_id" "$sample_root_view" "$sample_catalog" >/dev/null
  done

  echo "[principle-gates] Checking ownership boundary drift in sample sources"
  if search_lines_excluding "RouteStack|NavigationPath|NavigationStore|Navigator" "RouterCompositionDemo|InnoFlowSampleAppRootView" Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage/Sources; then
    echo "[principle-gates] Failed: navigation ownership leaked outside the router composition demo"
    exit 1
  fi

  if search_lines_excluding "import InnoNetworkWebSocket|WebSocketManager|WebSocketEvent|WebSocketTask|reconnect|retry policy|transport lifecycle|session lifecycle" "BidirectionalWebSocketDemo|InnoFlowSampleAppRootView|SampleCatalog" Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage/Sources; then
    echo "[principle-gates] Failed: network transport ownership leaked outside the explicitly labeled cross-framework demo"
    exit 1
  fi
}

run_doc_contract_checks() {
  ensure_principle_gate_context

  echo "[principle-gates] Checking required documentation sections"
  if [[ ! -f "ARCHITECTURE_CONTRACT.md" ]]; then
    echo "[principle-gates] Failed: ARCHITECTURE_CONTRACT.md is missing"
    exit 1
  fi
  if [[ ! -f "docs/adr/ADR-phase-transition-guards.md" ]]; then
    echo "[principle-gates] Failed: ADR-phase-transition-guards.md is missing"
    exit 1
  fi
  if [[ ! -f "docs/adr/ADR-declarative-phase-map.md" ]]; then
    echo "[principle-gates] Failed: ADR-declarative-phase-map.md is missing"
    exit 1
  fi
  if [[ ! -f "docs/adr/ADR-phase-map-totality-validation.md" ]]; then
    echo "[principle-gates] Failed: ADR-phase-map-totality-validation.md is missing"
    exit 1
  fi
  if ! search_lines "opt-in validation|partial by default" README.md PHASE_DRIVEN_MODELING.md Sources/InnoFlow/InnoFlow.docc >/dev/null; then
    echo "[principle-gates] Failed: docs must describe PhaseMap as partial-by-default with opt-in validation"
    exit 1
  fi
  if [[ ! -f "Sources/InnoFlow/InnoFlow.docc/VisionOSIntegration.md" ]]; then
    echo "[principle-gates] Failed: VisionOSIntegration.md is missing"
    exit 1
  fi
  if [[ ! -f "docs/DEPENDENCY_PATTERNS.md" ]]; then
    echo "[principle-gates] Failed: docs/DEPENDENCY_PATTERNS.md is missing"
    exit 1
  fi
  if [[ ! -f "docs/CROSS_FRAMEWORK.md" ]]; then
    echo "[principle-gates] Failed: docs/CROSS_FRAMEWORK.md is missing"
    exit 1
  fi
  if ! verify_doc_parity_contract; then
    exit 1
  fi

  echo "[principle-gates] Checking ADR document format"
  local adr_dir="docs/adr"
  if [[ ! -d "$adr_dir" ]]; then
    echo "[principle-gates] Failed: $adr_dir directory is missing"
    exit 1
  fi
  shopt -s nullglob
  local -a adr_files=("$adr_dir"/ADR-*.md)
  shopt -u nullglob
  if [[ "${#adr_files[@]}" -eq 0 ]]; then
    echo "[principle-gates] Failed: $adr_dir contains no ADR-*.md files"
    exit 1
  fi
  local adr_file
  local adr_basename
  local adr_section
  local -a adr_required_sections=("## Status" "## Context" "## Decision" "## Consequences")
  for adr_file in "${adr_files[@]}"; do
    adr_basename="$(basename "$adr_file")"
    if [[ ! "$adr_basename" =~ ^ADR-[a-z0-9]+(-[a-z0-9]+)*\.md$ ]]; then
      echo "[principle-gates] Failed: $adr_file filename must match ADR-{kebab-case}.md"
      exit 1
    fi
    for adr_section in "${adr_required_sections[@]}"; do
      if ! grep -qF -- "$adr_section" "$adr_file"; then
        echo "[principle-gates] Failed: $adr_file is missing required section '$adr_section'"
        exit 1
      fi
    done
  done

  echo "[principle-gates] Checking release surface sync"
  release_sync_output=""
  release_sync_status=0
  release_sync_output="$(scripts/check-release-sync.sh 2>&1)" || release_sync_status=$?
  if [[ "$release_sync_status" -ne 0 ]]; then
    if [[ -n "$release_sync_output" ]]; then
      printf '%s\n' "$release_sync_output" >&2
    fi
    echo "[principle-gates] CHECK-RELEASE-SYNC FAILED" >&2
    exit "$release_sync_status"
  fi
  if [[ -n "$release_sync_output" ]]; then
    printf '%s\n' "$release_sync_output"
  fi

  echo "[principle-gates] Checking localized README header parity baselines"
  doc_parity_output=""
  doc_parity_status=0
  doc_parity_output="$(scripts/check-doc-parity.sh 2>&1)" || doc_parity_status=$?
  if [[ "$doc_parity_status" -ne 0 ]]; then
    if [[ -n "$doc_parity_output" ]]; then
      printf '%s\n' "$doc_parity_output" >&2
    fi
    echo "[principle-gates] CHECK-DOC-PARITY FAILED" >&2
    exit "$doc_parity_status"
  fi
  if [[ -n "$doc_parity_output" ]]; then
    printf '%s\n' "$doc_parity_output"
  fi

  echo "[principle-gates] Checking guidance for selections, effect context, and SwiftUI integration"
  search_lines "SelectedStore" README.md ARCHITECTURE_CONTRACT.md Sources/InnoFlow/InnoFlow.docc >/dev/null
  search_lines "optionalValue" README.md ARCHITECTURE_CONTRACT.md Sources/InnoFlow/InnoFlow.docc >/dev/null
  search_lines "requireAlive" README.md ARCHITECTURE_CONTRACT.md Sources/InnoFlow/InnoFlow.docc >/dev/null
  if search_lines 'state`/`value|state / value|cached-fallback `value`|cached-fallback value|`value` accessors|SelectedStore[^[:cntrl:]]*cached fallback|SelectedStore[^[:cntrl:]]*cached snapshot' README.md ARCHITECTURE_CONTRACT.md Sources/InnoFlow/InnoFlow.docc; then
    echo "[principle-gates] Failed: current docs must not describe SelectedStore.value or SelectedStore cached fallback as a live contract"
    exit 1
  fi
  if search_lines_excluding "SelectedStore\\.value" "removed|not a cached-fallback accessor" README.md ARCHITECTURE_CONTRACT.md Sources/InnoFlow/InnoFlow.docc; then
    echo "[principle-gates] Failed: current docs may only mention SelectedStore.value as removed API"
    exit 1
  fi
  search_lines "dependingOn:" README.md ARCHITECTURE_CONTRACT.md Sources/InnoFlow/InnoFlow.docc >/dev/null
  search_lines "always-refresh fallback|always refresh fallback" README.md ARCHITECTURE_CONTRACT.md Sources/InnoFlow/InnoFlow.docc >/dev/null
  search_lines "PhaseMap" README.md ARCHITECTURE_CONTRACT.md CLAUDE.md PHASE_DRIVEN_MODELING.md Sources/InnoFlow/InnoFlow.docc Examples/InnoFlowSampleApp/README.md >/dev/null
  search_lines "derivedGraph" README.md ARCHITECTURE_CONTRACT.md PHASE_DRIVEN_MODELING.md Sources/InnoFlow/InnoFlow.docc Examples/InnoFlowSampleApp/README.md >/dev/null
  search_lines "EffectContext|context\\.sleep" README.md ARCHITECTURE_CONTRACT.md Sources/InnoFlow/InnoFlow.docc >/dev/null
  search_lines "validationReport" README.md ARCHITECTURE_CONTRACT.md Sources/InnoFlow/InnoFlow.docc >/dev/null
  search_lines "ADR-phase-transition-guards|guard-bearing transitions remain intentionally out of scope" README.md ARCHITECTURE_CONTRACT.md Sources/InnoFlow/InnoFlow.docc docs/adr >/dev/null
  search_lines "ADR-declarative-phase-map|topology-only|post-reduce" README.md ARCHITECTURE_CONTRACT.md Sources/InnoFlow/InnoFlow.docc docs/adr >/dev/null
  search_lines "best-effort async cleanup|deadlock-resistant|deadlock risk" ARCHITECTURE_CONTRACT.md README.md Sources/InnoFlow/InnoFlow.docc >/dev/null
  search_lines "StoreInstrumentation\\.sink|swift-metrics|Datadog|Prometheus" README.md ARCHITECTURE_CONTRACT.md Sources/InnoFlow/InnoFlow.docc >/dev/null
  search_lines "@Environment" README.md Sources/InnoFlow/InnoFlow.docc >/dev/null
  search_lines "Dependencies" README.md ARCHITECTURE_CONTRACT.md Sources/InnoFlow/InnoFlow.docc Examples/InnoFlowSampleApp/README.md >/dev/null
  search_lines "ForEachReducer" README.md ARCHITECTURE_CONTRACT.md Sources/InnoFlow/InnoFlow.docc Examples/InnoFlowSampleApp/README.md >/dev/null
  search_lines "Store\\.preview|#Preview" README.md ARCHITECTURE_CONTRACT.md Sources/InnoFlow/InnoFlow.docc Examples/README.md Examples/InnoFlowSampleApp/README.md >/dev/null
  search_lines "VoiceOver|accessibilityIdentifier|Dynamic Type" README.md ARCHITECTURE_CONTRACT.md Examples/InnoFlowSampleApp/README.md Sources/InnoFlow/InnoFlow.docc >/dev/null
  search_lines "modal dismiss|hub rows|destructive|cancellation" README.md ARCHITECTURE_CONTRACT.md Examples/InnoFlowSampleApp/README.md Sources/InnoFlow/InnoFlow.docc >/dev/null
  search_lines "accessibilityLabel|accessibilityHint" Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage/Sources >/dev/null
  search_lines "Dynamic Type" README.md Sources/InnoFlow/InnoFlow.docc >/dev/null
  search_lines "accessibilityIdentifier" README.md Sources/InnoFlow/InnoFlow.docc Examples/InnoFlowSampleApp/README.md >/dev/null
  search_lines "visionOS" README.md ARCHITECTURE_CONTRACT.md Sources/InnoFlow/InnoFlow.docc >/dev/null
  search_lines "app layer owns window|immersive-space orchestration stays in the app layer|spatial runtime" README.md ARCHITECTURE_CONTRACT.md Sources/InnoFlow/InnoFlow.docc >/dev/null
  search_lines "PhaseMap\\(" Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage/Sources/InnoFlowSampleAppFeature/PhaseDrivenFSMDemo.swift >/dev/null
  if search_lines "On\\(Action\\._" README.md CLAUDE.md PHASE_DRIVEN_MODELING.md Sources/InnoFlow/InnoFlow.docc Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage/Sources; then
    echo "[principle-gates] Failed: canonical docs or sample still expose underscored action path names in PhaseMap"
    exit 1
  fi
}

run_authoring_policy_checks() {
  ensure_principle_gate_context

  echo "[principle-gates] Checking @unchecked Sendable removal"
  if search_lines "@unchecked Sendable" Sources Tests Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage/Sources Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage/Tests; then
    echo "[principle-gates] Failed: @unchecked Sendable usage found"
    exit 1
  fi

  echo "[principle-gates] Checking macro maintainability split"
  local macro_entry="Sources/InnoFlowMacros/InnoFlowMacro.swift"
  if search_lines "@BindableField|diagnoseMissingBindableFieldSetters|BindableFieldDiagnostic" "$macro_entry"; then
    echo "[principle-gates] Failed: bindable-field diagnostics leaked back into $macro_entry"
    exit 1
  fi
  local macro_entry_loc
  macro_entry_loc="$(wc -l < "$macro_entry" | tr -d ' ')"
  if [[ "$macro_entry_loc" -gt 300 ]]; then
    echo "[principle-gates] Failed: $macro_entry must stay under 300 lines (found $macro_entry_loc)"
    exit 1
  fi
}

run_release_build_checks() {
  ensure_principle_gate_context

  echo "[principle-gates] Verifying release build succeeds (SIL inliner regression guard)"
  warn_if_optimize_none_workaround_should_be_retested
  # Use an isolated build path so release object files do not leak into the
  # main .build/ tree. The stale-scope and phase-map subprocess harnesses
  # enumerate .build/**/InnoFlow.build/*.o to link probe binaries; mixing
  # debug and release artifacts there causes duplicate-symbol failures.
  RELEASE_GATE_BUILD_PATH="${ROOT_DIR}/.build-principle-gates-release"
  if ! run_low_priority swift build \
      --package-path "$ROOT_DIR" \
      --build-path "$RELEASE_GATE_BUILD_PATH" \
      -c release \
      --jobs "$SWIFTPM_JOBS" \
      "${SWIFT_FRONTEND_THREAD_FLAGS[@]}" >/dev/null 2>&1; then
    echo "[principle-gates] Failed: 'swift build -c release' crashed or failed — SIL inliner regression suspected"
    swift --version || true
    rm -rf "$RELEASE_GATE_BUILD_PATH"
    exit 1
  fi

  echo "[principle-gates] Running package tests"
  run_low_priority swift test --package-path "$ROOT_DIR" --jobs "$SWIFTPM_JOBS" -Xswiftc -warnings-as-errors

  echo "[principle-gates] Running package tests in release configuration"
  # Release-mode test gate. Uses an isolated build path for the same reason as
  # the release build gate above. Catches regressions where tests pass in debug
  # but fail under release optimization (e.g., flaky timing assertions that
  # assumed a fixed `Task.yield()` count).
  #
  # Run the full release suite without the timing baseline gate enabled. The
  # baseline comparison uses absolute timings, so running it alongside the
  # rest of the release suite creates cross-suite scheduler contention and can
  # produce false regressions even when the implementation is healthy.
  if ! run_low_priority swift test \
      --package-path "$ROOT_DIR" \
      --build-path "$RELEASE_GATE_BUILD_PATH" \
      -c release \
      --jobs "$SWIFTPM_JOBS" \
      "${SWIFT_FRONTEND_THREAD_FLAGS[@]}" \
      -Xswiftc -warnings-as-errors; then
    echo "[principle-gates] Failed: 'swift test -c release' failed — release-mode regression"
    rm -rf "$RELEASE_GATE_BUILD_PATH"
    exit 1
  fi

  echo "[principle-gates] Running isolated release timing baseline gate"
  # `INNOFLOW_CHECK_EFFECT_BASELINE=1` opts the `EffectTimingBaselineGate` in
  # for this dedicated release-only run so malformed or incomplete timing
  # captures still fail CI. Metric regressions are reported as non-blocking
  # trend output because wall-clock effect timings are runner-sensitive. Reuse
  # the release gate build path from the full release suite so SwiftSyntax does
  # not need to be compiled repeatedly on local machines.
  if ! run_low_priority env INNOFLOW_CHECK_EFFECT_BASELINE=1 swift test \
      --package-path "$ROOT_DIR" \
      --build-path "$RELEASE_GATE_BUILD_PATH" \
      -c release \
      --jobs "$SWIFTPM_JOBS" \
      "${SWIFT_FRONTEND_THREAD_FLAGS[@]}" \
      -Xswiftc -warnings-as-errors \
      --filter EffectTimingBaselineGate; then
    echo "[principle-gates] Failed: isolated release timing baseline gate regressed"
    rm -rf "$RELEASE_GATE_BUILD_PATH"
    exit 1
  fi
  rm -rf "$RELEASE_GATE_BUILD_PATH"
}

run_sample_runtime_contract_checks() {
  ensure_principle_gate_context
  trap cleanup_temp_dirs EXIT

  echo "[principle-gates] Running sample package tests"
  local sample_test_root
  sample_test_root="$(canonical_root_for_sample_package_tests)"
  local sample_package_path
  sample_package_path="$sample_test_root/Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage"
  # The sample package has its own .build cache. Clean it before testing so
  # local branch switches cannot reuse a stale source-file graph for InnoFlow.
  run_low_priority swift package --package-path "$sample_package_path" clean
  if ! run_logged_gate_command \
      "sample package tests" \
      run_low_priority swift test --package-path "$sample_package_path" --jobs "$SWIFTPM_JOBS" -Xswiftc -warnings-as-errors; then
    exit 1
  fi

  echo "[principle-gates] Building canonical sample app"
  if ! run_logged_gate_command \
      "canonical sample app build" \
      run_low_priority xcodebuild \
      -jobs 1 \
      -project "$sample_test_root/Examples/InnoFlowSampleApp/InnoFlowSampleApp.xcodeproj" \
      -scheme InnoFlowSampleApp \
      -destination 'generic/platform=iOS' \
      CODE_SIGNING_ALLOWED=NO \
      CODE_SIGNING_REQUIRED=NO \
      build; then
    exit 1
  fi

  echo "[principle-gates] Checking PhaseMap totality enforcement"
  # Phase-managed reducers in the core (Sources/InnoFlowCore) live behind a
  # post-reduce contract (`@InnoFlow(phaseManaged: true)` + `static var
  # phaseMap`). The opt-in `PhaseMapDiagnostics` reporter surfaces *runtime*
  # drift, but only `assertPhaseMapCovers(...)` catches *missing transitions*
  # at test time. If anyone introduces a phase-managed feature inside the core
  # we want an explicit totality assertion landing alongside it; otherwise the
  # contract silently drifts on every new action case.
  #
  # The line-head anchor (`^[[:space:]]*@InnoFlow`) skips doccomment matches
  # because doccomment lines start with `///`. Examples and macro definitions
  # are intentionally excluded — sample-app totality is product polish, not
  # a core contract.
  set +e
  phase_managed_uses=$(
    find Sources/InnoFlowCore \
      -name '*.swift' \
      -not -path '*/InnoFlow.docc/*' \
      -print0 \
      | xargs -0 grep -lE "^[[:space:]]*@InnoFlow\(phaseManaged: true\)" 2>/dev/null
  )
  phase_managed_status=$?
  set -e

  if [[ $phase_managed_status -le 1 && -n "$phase_managed_uses" ]]; then
    if ! grep -RqE "assertPhaseMapCovers" Tests/InnoFlowTests 2>/dev/null; then
      echo "[principle-gates] Failed: phase-managed features found in Sources/InnoFlowCore but Tests/InnoFlowTests has no assertPhaseMapCovers(...) call"
      echo "[principle-gates] Files containing @InnoFlow(phaseManaged: true):"
      printf '  %s\n' "${phase_managed_uses}"
      echo "[principle-gates] Remediation: add 'assertPhaseMapCovers(YourFeature.phaseMap, expectedTriggersByPhase: [...])' to a test in Tests/InnoFlowTests."
      echo "[principle-gates] Reason: phase-managed contracts are easy to drift silently. Totality is the only test path that surfaces missing legal transitions in every build configuration."
      exit 1
    fi
  fi

}

run_authoring_checks() {
  run_authoring_surface_checks "$@"
  run_authoring_policy_checks "$@"
}

run_sample_contract_checks() {
  trap cleanup_temp_dirs EXIT
  run_sample_static_contract_checks "$@"
  run_sample_runtime_contract_checks "$@"
}

run_principle_gates() {
  trap cleanup_temp_dirs EXIT
  run_authoring_surface_checks "$@"
  run_sample_static_contract_checks "$@"
  run_doc_contract_checks "$@"
  run_authoring_policy_checks "$@"
  run_release_build_checks "$@"
  run_sample_runtime_contract_checks "$@"
  echo "[principle-gates] All checks passed"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_principle_gates "$@"
fi
