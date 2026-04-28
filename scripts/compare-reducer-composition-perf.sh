#!/usr/bin/env bash
#
# Compares machine-readable reducer composition benchmark output emitted by
# `ReducerCompositionPerfTests` when `INNOFLOW_REDUCER_PERF_OUTPUT=<path>` is
# set. Comparison is local-only and intentionally not wired into CI gates.

set -euo pipefail

TOLERANCE="0.25"
BASELINE=""
CURRENT=""

print_help() {
  cat <<'HELP'
compare-reducer-composition-perf.sh — compare reducer composition benchmark JSONL

Required:
  --baseline <path>   Baseline JSONL fixture
  --current  <path>   Fresh JSONL emitted from ReducerCompositionPerfTests

Optional:
  --tolerance <n>     Allowed relative increase per benchmark (default: 0.25)
  --help              Print this help

Generate fresh local results from the repository root:
  INNOFLOW_PERF_BENCHMARKS=1 \
  INNOFLOW_REDUCER_PERF_OUTPUT=/tmp/reducer-composition-perf.jsonl \
  swift test --package-path . --build-path .build-reducer-perf -c release \
    -Xswiftc -warnings-as-errors --filter PerfReducerComposition

This tool is local-only by design. It does not participate in CI or
`scripts/principle-gates.sh`.
HELP
}

require_option_value() {
  local option="$1"
  local value="${2:-}"

  if [[ -z "$value" || "$value" == --* ]]; then
    echo "[compare-reducer-composition-perf] missing value for $option" >&2
    print_help >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline)
      require_option_value "$1" "${2:-}"
      BASELINE="$2"; shift 2 ;;
    --current)
      require_option_value "$1" "${2:-}"
      CURRENT="$2"; shift 2 ;;
    --tolerance)
      require_option_value "$1" "${2:-}"
      TOLERANCE="$2"; shift 2 ;;
    --help|-h)
      print_help; exit 0 ;;
    *)
      echo "[compare-reducer-composition-perf] unknown argument: $1" >&2
      print_help >&2
      exit 1 ;;
  esac
done

if [[ ! "$TOLERANCE" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "[compare-reducer-composition-perf] --tolerance must be a non-negative number" >&2
  exit 1
fi

if [[ -z "$BASELINE" || -z "$CURRENT" ]]; then
  echo "[compare-reducer-composition-perf] --baseline and --current are required" >&2
  print_help >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "[compare-reducer-composition-perf] 'jq' is required. Install with: brew install jq" >&2
  exit 1
fi

if [[ ! -f "$BASELINE" ]]; then
  echo "[compare-reducer-composition-perf] baseline file not found: $BASELINE" >&2
  exit 1
fi

if [[ ! -f "$CURRENT" ]]; then
  echo "[compare-reducer-composition-perf] current file not found: $CURRENT" >&2
  exit 1
fi

require_unique_labels() {
  local file="$1"
  local duplicate_labels
  duplicate_labels="$(jq -rs '
    group_by(.label)
    | map(select(length > 1) | .[0].label)
    | join(",")
  ' "$file")"

  if [[ -n "$duplicate_labels" ]]; then
    echo "[compare-reducer-composition-perf] duplicate benchmark labels in $file: $duplicate_labels" >&2
    exit 1
  fi
}

require_unique_labels "$BASELINE"
require_unique_labels "$CURRENT"

read_per_iteration_nanos() {
  local file="$1"
  local label="$2"
  local role="$3"
  local value

  if ! value="$(jq -re --arg label "$label" '
    select(.label == $label)
    | .perIterationNanos
    | select(type == "number")
  ' "$file")"; then
    echo "[compare-reducer-composition-perf] $role perIterationNanos must be numeric for $label" >&2
    exit 1
  fi

  printf '%s\n' "$value"
}

BASELINE_LABELS=()
while IFS= read -r label; do
  BASELINE_LABELS[${#BASELINE_LABELS[@]}]="$label"
done < <(jq -r '.label' "$BASELINE")

CURRENT_LABELS=()
while IFS= read -r label; do
  CURRENT_LABELS[${#CURRENT_LABELS[@]}]="$label"
done < <(jq -r '.label' "$CURRENT")

for label in "${BASELINE_LABELS[@]}"; do
  if ! jq -e --arg label "$label" 'select(.label == $label)' "$CURRENT" >/dev/null; then
    echo "[compare-reducer-composition-perf] current results are missing benchmark: $label" >&2
    exit 1
  fi
done

for label in "${CURRENT_LABELS[@]}"; do
  if ! jq -e --arg label "$label" 'select(.label == $label)' "$BASELINE" >/dev/null; then
    echo "[compare-reducer-composition-perf] current results contain unexpected benchmark: $label" >&2
    exit 1
  fi
done

overall_ok=1

for label in "${BASELINE_LABELS[@]}"; do
  baseline_value="$(read_per_iteration_nanos "$BASELINE" "$label" "baseline")"
  current_value="$(read_per_iteration_nanos "$CURRENT" "$label" "current")"

  if [[ "$baseline_value" == "0" ]]; then
    echo "[compare-reducer-composition-perf] baseline perIterationNanos is zero for $label" >&2
    exit 1
  fi

  ratio="$(awk -v c="$current_value" -v b="$baseline_value" 'BEGIN { printf "%.6f", (c - b) / b }')"
  ratio_ok="$(awk -v r="$ratio" -v t="$TOLERANCE" 'BEGIN { print (r <= t) ? 1 : 0 }')"

  summary=$(printf '[compare-reducer-composition-perf] label=%s baseline=%sns current=%sns ratio=%s tolerance=%s' \
    "$label" "$baseline_value" "$current_value" "$ratio" "$TOLERANCE")

  if [[ "$ratio_ok" == "1" ]]; then
    echo "$summary PASS"
  else
    echo "$summary FAIL" >&2
    overall_ok=0
  fi
done

if [[ "$overall_ok" == "1" ]]; then
  echo "[compare-reducer-composition-perf] overall=PASS"
  exit 0
fi

echo "[compare-reducer-composition-perf] overall=FAIL" >&2
exit 1
