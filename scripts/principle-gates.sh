#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CANONICAL_ROOT_DIR=""

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
      --exclude '.build-principle-gates-release' \
      --exclude '.git' \
      "$ROOT_DIR/" "$CANONICAL_ROOT_DIR/"
  else
    ditto "$ROOT_DIR" "$CANONICAL_ROOT_DIR"
    rm -rf \
      "$CANONICAL_ROOT_DIR/.build" \
      "$CANONICAL_ROOT_DIR/.build-principle-gates-release" \
      "$CANONICAL_ROOT_DIR/.git"
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

validate_doc_parity_contract_shape() {
  local contract_path="$1"

  jq -e '
    def non_empty_array($name):
      has($name) and (.[$name] | type == "array") and (.[$name] | length > 0);
    def typed_field($name; $kind):
      has($name) and (.[$name] | type == $kind);

    non_empty_array("requiredPatterns")
    and non_empty_array("sectionCounts")
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

main() {
  initialize_search_backend
  trap cleanup_temp_dirs EXIT
  cd "$ROOT_DIR"

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

  echo "[principle-gates] Checking official composition primitives"
  search_lines "public struct Reduce<" Sources/InnoFlow/ReducerComposition.swift >/dev/null
  search_lines "public struct CombineReducers<" Sources/InnoFlow/ReducerComposition.swift >/dev/null
  search_lines "public struct Scope<" Sources/InnoFlow/ReducerComposition.swift >/dev/null
  search_lines "public struct IfLet<" Sources/InnoFlow/ReducerComposition.swift >/dev/null
  search_lines "public struct IfCaseLet<" Sources/InnoFlow/ReducerComposition.swift >/dev/null
  search_lines "public struct ForEachReducer<" Sources/InnoFlow/ReducerComposition.swift >/dev/null
  search_lines "public struct StoreClock" Sources/InnoFlow/StoreClock.swift >/dev/null
  search_lines "public struct StoreInstrumentation" Sources/InnoFlow/StoreInstrumentation.swift >/dev/null
  search_lines "public final class SelectedStore<" Sources/InnoFlow/SelectedStore.swift >/dev/null
  search_lines "public struct EffectContext" Sources/InnoFlow/EffectTask.swift >/dev/null
  search_lines "public actor ManualTestClock" Sources/InnoFlowTesting/ManualTestClock.swift >/dev/null
  search_lines "public static func preview\\(" Sources/InnoFlow/Store+SwiftUIPreviews.swift >/dev/null
  search_lines "public func map<" Sources/InnoFlow/EffectTask.swift >/dev/null
  if ! search_multiline 'public func select<[\s\S]{0,220}dependingOn dependency:' Sources/InnoFlow/SelectedStore.swift; then
    echo "[principle-gates] Failed: SelectedStore dependency-annotated selection overload is missing"
    exit 1
  fi
  if ! search_multiline 'public func select<[\s\S]{0,260}dependingOn dependencies:\s*\([\s\S]{0,180}KeyPath<[^>]+,[^>]+>[\s\S]{0,120}KeyPath<[^>]+,[^>]+>' Sources/InnoFlow/SelectedStore.swift; then
    echo "[principle-gates] Failed: SelectedStore multi-field selection overload is missing"
    exit 1
  fi
  if search_multiline 'public init\([\s\S]{0,240}extractAction:\s*@escaping' Sources/InnoFlow/ReducerComposition.swift; then
    echo "[principle-gates] Failed: reducer composition still exposes public closure-based action lifting"
    exit 1
  fi
  if search_multiline 'public func scope<[\s\S]{0,280}action:\s*@escaping\s*@Sendable' Sources/InnoFlow/ScopedStore.swift; then
    echo "[principle-gates] Failed: Store.scope still exposes public closure-based action lifting"
    exit 1
  fi
  if search_multiline 'public func scope<[\s\S]{0,320}extractAction:\s*@escaping' Sources/InnoFlowTesting/TestStore.swift; then
    echo "[principle-gates] Failed: TestStore.scope still exposes public closure-based action lifting"
    exit 1
  fi

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

  echo "[principle-gates] Checking guidance for selections, effect context, and SwiftUI integration"
  search_lines "SelectedStore" README.md ARCHITECTURE_CONTRACT.md Sources/InnoFlow/InnoFlow.docc >/dev/null
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

  echo "[principle-gates] Verifying release build succeeds (SIL inliner regression guard)"
  # Use an isolated build path so release object files do not leak into the
  # main .build/ tree. The stale-scope and phase-map subprocess harnesses
  # enumerate .build/**/InnoFlow.build/*.o to link probe binaries; mixing
  # debug and release artifacts there causes duplicate-symbol failures.
  RELEASE_BUILD_PATH="${ROOT_DIR}/.build-principle-gates-release"
  if ! swift build --package-path "$ROOT_DIR" --build-path "$RELEASE_BUILD_PATH" -c release >/dev/null 2>&1; then
    echo "[principle-gates] Failed: 'swift build -c release' crashed or failed — SIL inliner regression suspected"
    swift --version || true
    rm -rf "$RELEASE_BUILD_PATH"
    exit 1
  fi
  rm -rf "$RELEASE_BUILD_PATH"

  echo "[principle-gates] Running package tests"
  swift test --package-path "$ROOT_DIR" -Xswiftc -warnings-as-errors

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
  RELEASE_TEST_BUILD_PATH="${ROOT_DIR}/.build-principle-gates-release-test"
  if ! swift test \
      --package-path "$ROOT_DIR" \
      --build-path "$RELEASE_TEST_BUILD_PATH" \
      -c release \
      -Xswiftc -warnings-as-errors; then
    echo "[principle-gates] Failed: 'swift test -c release' failed — release-mode regression"
    rm -rf "$RELEASE_TEST_BUILD_PATH"
    exit 1
  fi
  rm -rf "$RELEASE_TEST_BUILD_PATH"

  echo "[principle-gates] Running isolated release timing baseline gate"
  # `INNOFLOW_CHECK_EFFECT_BASELINE=1` opts the `EffectTimingBaselineGate` in
  # for this dedicated release-only run so release-mode scheduling regressions
  # (the 2026-04 class of yield-count failures) are detected against
  # `Tests/InnoFlowTests/Fixtures/EffectTimings.baseline.jsonl` via
  # `scripts/compare-effect-timings.sh` without unrelated suite load skewing
  # the measured mean.
  RELEASE_BASELINE_BUILD_PATH="${ROOT_DIR}/.build-principle-gates-release-baseline"
  if ! INNOFLOW_CHECK_EFFECT_BASELINE=1 swift test \
      --package-path "$ROOT_DIR" \
      --build-path "$RELEASE_BASELINE_BUILD_PATH" \
      -c release \
      -Xswiftc -warnings-as-errors \
      --filter EffectTimingBaselineGate; then
    echo "[principle-gates] Failed: isolated release timing baseline gate regressed"
    rm -rf "$RELEASE_BASELINE_BUILD_PATH"
    exit 1
  fi
  rm -rf "$RELEASE_BASELINE_BUILD_PATH"

  echo "[principle-gates] Running sample package tests"
  local sample_test_root
  sample_test_root="$(canonical_root_for_sample_package_tests)"
  swift test --package-path "$sample_test_root/Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage" -Xswiftc -warnings-as-errors

  echo "[principle-gates] Building canonical sample app"
  xcodebuild \
    -project "$sample_test_root/Examples/InnoFlowSampleApp/InnoFlowSampleApp.xcodeproj" \
    -scheme InnoFlowSampleApp \
    -destination 'generic/platform=iOS' \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build >/dev/null

  echo "[principle-gates] All checks passed"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
