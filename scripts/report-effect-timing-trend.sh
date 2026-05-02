#!/usr/bin/env bash
#
# Non-blocking effect timing trend reporter.
#
# Produces a fresh EffectTimingRecorder JSONL dump (unless --current is
# provided), then reports both mean and p95 deltas against the committed
# baseline. Regressions remain non-blocking, but malformed data or capture
# failures still fail loudly for maintainers.

set -euo pipefail

EXIT_HARD_FAILURE=2
ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
BASELINE="${ROOT_DIR}/Tests/InnoFlowTests/Fixtures/EffectTimings.baseline.jsonl"
CURRENT=""
BUILD_PATH="${ROOT_DIR}/.build-effect-timing-trend"
TEMP_CURRENT=""

print_help() {
  cat <<'HELP'
report-effect-timing-trend.sh — non-blocking mean/p95 reporter for EffectTimingRecorder

Optional:
  --baseline <path>    Baseline JSONL fixture
  --current  <path>    Existing current JSONL; skips the capture step
  --build-path <path>  Build path used when capturing a fresh JSONL
  --help               Print this help

Behavior:
  If --current is omitted, the script captures a fresh JSONL by running:
    INNOFLOW_WRITE_EFFECT_BASELINE=<tmp> swift test -c release --filter EffectTimingBaselineGate

  The script then reports both:
  - mean    (matches the release-gate trend metric)
  - p95     (stricter local percentile signal)

Exit codes:
  0  report completed, even if a metric regressed
  2  usage error, capture failure, or malformed/incomplete data

Examples:
  ./scripts/report-effect-timing-trend.sh
  ./scripts/report-effect-timing-trend.sh --current /tmp/current-effect-timings.jsonl
HELP
}

cleanup() {
  if [[ -n "$TEMP_CURRENT" && -f "$TEMP_CURRENT" ]]; then
    rm -f "$TEMP_CURRENT"
  fi
}

capture_current_if_needed() {
  if [[ -n "$CURRENT" ]]; then
    return
  fi

  TEMP_CURRENT="$(mktemp "${TMPDIR:-/tmp}/innoflow-effect-timing-trend.XXXXXX.jsonl")"
  CURRENT="$TEMP_CURRENT"

  (
    cd "$ROOT_DIR"
    INNOFLOW_WRITE_EFFECT_BASELINE="$CURRENT" \
      swift test \
        --package-path "$ROOT_DIR" \
        --build-path "$BUILD_PATH" \
        -c release \
        -Xswiftc -warnings-as-errors \
        --filter EffectTimingBaselineGate >/dev/null
  ) || {
    echo "[report-effect-timing-trend] failed to capture a fresh timing baseline" >&2
    exit "$EXIT_HARD_FAILURE"
  }

  if [[ ! -s "$CURRENT" ]]; then
    echo "[report-effect-timing-trend] capture did not produce JSONL output: $CURRENT" >&2
    exit "$EXIT_HARD_FAILURE"
  fi
}

report_metric() {
  local metric="$1"
  local output
  local status=0

  output="$(
    bash "${ROOT_DIR}/scripts/compare-effect-timings.sh" \
      --baseline "$BASELINE" \
      --current "$CURRENT" \
      --metric "$metric" \
      --tolerance 1.0 2>&1
  )" || status=$?

  if [[ "$status" == "0" ]]; then
    printf '[effect-timing-trend] %s\n' "$output"
    return
  fi

  if [[ "$status" == "1" ]]; then
    printf '[effect-timing-trend] metric=%s NON-BLOCKING_REGRESSION\n' "$metric"
    printf '%s\n' "$output"
    return
  fi

  printf '%s\n' "$output" >&2
  exit "$EXIT_HARD_FAILURE"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline)
      BASELINE="$2"; shift 2 ;;
    --current)
      CURRENT="$2"; shift 2 ;;
    --build-path)
      BUILD_PATH="$2"; shift 2 ;;
    --help|-h)
      print_help
      exit 0 ;;
    *)
      echo "[report-effect-timing-trend] unknown argument: $1" >&2
      print_help >&2
      exit "$EXIT_HARD_FAILURE" ;;
  esac
done

trap cleanup EXIT

if [[ ! -f "$BASELINE" ]]; then
  echo "[report-effect-timing-trend] baseline file not found: $BASELINE" >&2
  exit "$EXIT_HARD_FAILURE"
fi

if [[ -n "$CURRENT" && ! -f "$CURRENT" ]]; then
  echo "[report-effect-timing-trend] current file not found: $CURRENT" >&2
  exit "$EXIT_HARD_FAILURE"
fi

capture_current_if_needed

printf '[effect-timing-trend] baseline=%s current=%s\n' "$BASELINE" "$CURRENT"
report_metric mean
report_metric p95
