#!/usr/bin/env bash
#
# Compares a fresh `EffectTimingRecorder` JSONL dump against a committed
# baseline and fails when the relative regression exceeds the tolerance.
#
# The recorder captures `runStarted` / `runFinished` events with a monotonic
# `timestampNanos` stamp. For every matched pair (same `sequence`), this
# script computes the run duration, aggregates the distribution, and compares
# the chosen metric (p95 by default) against the baseline distribution.
#
# A failure exits 1 with the regression delta printed on stderr. A pass
# exits 0 with a one-line summary on stdout. No metric is absolute —
# thresholds are relative so the same baseline survives CI runner churn.
#
# Requires `jq`. If missing, prints an install hint and exits 1.
#
# Usage:
#   ./scripts/compare-effect-timings.sh \
#     --baseline Tests/InnoFlowTests/Fixtures/EffectTimings.baseline.jsonl \
#     --current  /tmp/current.jsonl \
#     [--metric p95] \
#     [--tolerance 0.10]

set -euo pipefail

METRIC="p95"
TOLERANCE="0.10"
BASELINE=""
CURRENT=""

print_help() {
  cat <<'HELP'
compare-effect-timings.sh — baseline comparison for EffectTimingRecorder JSONL

Required:
  --baseline <path>   Committed baseline JSONL
  --current  <path>   Newly-produced JSONL from the current run

Optional:
  --metric   <p95|mean>  Metric to compare (default: p95)
  --tolerance <0..1>     Allowed relative increase (default: 0.10 = 10%)
  --help                 Print this help

Exit codes:
  0  current within tolerance of baseline
  1  regression detected, current capture incomplete, or missing dependency

Install jq if unavailable:
  brew install jq
HELP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline)
      BASELINE="$2"; shift 2 ;;
    --current)
      CURRENT="$2"; shift 2 ;;
    --metric)
      METRIC="$2"; shift 2 ;;
    --tolerance)
      TOLERANCE="$2"; shift 2 ;;
    --help|-h)
      print_help; exit 0 ;;
    *)
      echo "[compare-effect-timings] unknown argument: $1" >&2
      print_help >&2
      exit 1 ;;
  esac
done

if [[ -z "$BASELINE" || -z "$CURRENT" ]]; then
  echo "[compare-effect-timings] --baseline and --current are required" >&2
  print_help >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "[compare-effect-timings] 'jq' is required. Install with: brew install jq" >&2
  exit 1
fi

if [[ ! -f "$BASELINE" ]]; then
  echo "[compare-effect-timings] baseline file not found: $BASELINE" >&2
  exit 1
fi

if [[ ! -f "$CURRENT" ]]; then
  echo "[compare-effect-timings] current file not found: $CURRENT" >&2
  exit 1
fi

# Build the jq filter for the requested metric. For matched run pairs
# (`runStarted` + `runFinished` sharing a `sequence`), compute the duration
# delta and then reduce the distribution to a single number.
case "$METRIC" in
  p95)
    METRIC_FILTER='(($deltas | sort) as $d | if ($d | length) == 0 then 0 else $d[(($d | length - 1) * 0.95 | floor)] end)'
    ;;
  mean)
    METRIC_FILTER='(if ($deltas | length) == 0 then 0 else ($deltas | add) / ($deltas | length) end)'
    ;;
  *)
    echo "[compare-effect-timings] unknown metric: $METRIC (expected p95 or mean)" >&2
    exit 1 ;;
esac

# Produce "<matched run count>\t<metric nanos>" for a given JSONL file.
compute_summary() {
  local file="$1"
  jq -rs '
    map(select(.phase == "runStarted" or .phase == "runFinished"))
    | group_by(.sequence)
    | map(select(length == 2
        and any(.[]; .phase == "runStarted")
        and any(.[]; .phase == "runFinished")))
    | map(
        ((.[] | select(.phase == "runFinished") | .timestampNanos)
         - (.[] | select(.phase == "runStarted") | .timestampNanos)))
    | . as $deltas
    | [($deltas | length), ('"$METRIC_FILTER"')] | @tsv
  ' "$file"
}

IFS=$'\t' read -r BASELINE_MATCHED_RUNS BASELINE_METRIC <<< "$(compute_summary "$BASELINE")"
IFS=$'\t' read -r CURRENT_MATCHED_RUNS CURRENT_METRIC <<< "$(compute_summary "$CURRENT")"

# Guard against zero baseline (insufficient signal in fixture). Treat as
# pass-through — a new fixture has to be refreshed manually.
if [[ -z "$BASELINE_MATCHED_RUNS" || "$BASELINE_MATCHED_RUNS" == "0" ]]; then
  echo "[compare-effect-timings] baseline has no matched runs — regenerate fixture" >&2
  exit 0
fi

if [[ -z "$CURRENT_MATCHED_RUNS" || "$CURRENT_MATCHED_RUNS" == "0" ]]; then
  echo "[compare-effect-timings] current capture has no matched runs — incomplete capture or missing runFinished events" >&2
  exit 1
fi

# Use `awk` (POSIX, no jq math) for the ratio comparison. jq's floats are
# IEEE-754 which is fine but `awk` keeps the script dependency light and
# mirrors the rest of the shell math used by `principle-gates.sh`.
RATIO="$(awk -v c="$CURRENT_METRIC" -v b="$BASELINE_METRIC" 'BEGIN { printf "%.6f", (c - b) / b }')"
RATIO_OK="$(awk -v r="$RATIO" -v t="$TOLERANCE" 'BEGIN { print (r <= t) ? 1 : 0 }')"

SUMMARY=$(printf '[compare-effect-timings] metric=%s baselineRuns=%s currentRuns=%s baseline=%sns current=%sns ratio=%s tolerance=%s' \
  "$METRIC" "$BASELINE_MATCHED_RUNS" "$CURRENT_MATCHED_RUNS" "$BASELINE_METRIC" "$CURRENT_METRIC" "$RATIO" "$TOLERANCE")

if [[ "$RATIO_OK" == "1" ]]; then
  echo "$SUMMARY PASS"
  exit 0
else
  {
    echo "$SUMMARY FAIL"
    jq -n --arg metric "$METRIC" \
      --arg baselineRuns "$BASELINE_MATCHED_RUNS" \
      --arg currentRuns "$CURRENT_MATCHED_RUNS" \
      --arg baseline "$BASELINE_METRIC" \
      --arg current  "$CURRENT_METRIC" \
      --arg ratio    "$RATIO" \
      --arg tolerance "$TOLERANCE" \
      '{regression: {metric: $metric, baselineRuns: $baselineRuns, currentRuns: $currentRuns, baselineNanos: $baseline, currentNanos: $current, ratio: $ratio, tolerance: $tolerance}}'
  } >&2
  exit 1
fi
