#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STABLE_VERSION_FILE="${INNOFLOW_STABLE_VERSION_FILE:-$ROOT_DIR/STABLE_VERSION}"

if [[ ! -f "$STABLE_VERSION_FILE" ]]; then
  echo "[api-compatibility] Stable-version metadata is unavailable: $STABLE_VERSION_FILE" >&2
  exit 2
fi

if [[ "$(awk 'END { print NR }' "$STABLE_VERSION_FILE")" != "1" ]]; then
  echo "[api-compatibility] STABLE_VERSION must contain exactly one line" >&2
  exit 2
fi

STABLE_VERSION="$(sed -n '1p' "$STABLE_VERSION_FILE")"
if [[ ! "$STABLE_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "[api-compatibility] Invalid numeric SemVer in STABLE_VERSION: $STABLE_VERSION" >&2
  exit 2
fi

BASELINE_VERSION="${INNOFLOW_API_BASELINE:-$STABLE_VERSION}"

if [[ ! "$BASELINE_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "[api-compatibility] Invalid numeric SemVer baseline: $BASELINE_VERSION" >&2
  exit 2
fi

if [[ -n "${INNOFLOW_REQUIRE_API_BASELINE+x}" ]]; then
  REQUIRE_BASELINE="$INNOFLOW_REQUIRE_API_BASELINE"
elif [[ "${STABLE_VERSION%%.*}" == "${BASELINE_VERSION%%.*}" ]]; then
  REQUIRE_BASELINE=1
else
  REQUIRE_BASELINE=0
fi

if [[ "$REQUIRE_BASELINE" != "0" && "$REQUIRE_BASELINE" != "1" ]]; then
  echo "[api-compatibility] INNOFLOW_REQUIRE_API_BASELINE must be 0 or 1" >&2
  exit 2
fi

cd "$ROOT_DIR"

if ! git show-ref --verify --quiet "refs/tags/$BASELINE_VERSION"; then
  if [[ "$REQUIRE_BASELINE" == "1" ]]; then
    echo "[api-compatibility] Required baseline tag $BASELINE_VERSION is unavailable" >&2
    exit 2
  fi
  echo "[api-compatibility] Baseline tag $BASELINE_VERSION is not published yet; gate is staged while stable is $STABLE_VERSION"
  exit 0
fi

# The digester also reports package-access declarations, which no consumer
# can reach. Each such diagnostic must be reviewed in the allowlist, and the
# validator proves from the baseline source that it is not public.
ALLOWLIST="${INNOFLOW_API_BREAKAGE_ALLOWLIST:-$ROOT_DIR/docs/contracts/api-breakage-allowlist.json}"
allowlist_arguments=()
if [[ -f "$ALLOWLIST" ]]; then
  RESOLVED_ALLOWLIST="$(mktemp)"
  trap 'rm -f "$RESOLVED_ALLOWLIST"' EXIT
  python3 -B "$SCRIPT_DIR/check-api-breakage-allowlist.py" \
    --root "$ROOT_DIR" --allowlist "$ALLOWLIST" \
    --baseline "$BASELINE_VERSION" --output "$RESOLVED_ALLOWLIST"
  if [[ -s "$RESOLVED_ALLOWLIST" ]]; then
    allowlist_arguments=(--breakage-allowlist-path "$RESOLVED_ALLOWLIST")
  fi
fi

echo "[api-compatibility] Comparing public products with $BASELINE_VERSION"
swift package diagnose-api-breaking-changes \
  ${allowlist_arguments[@]+"${allowlist_arguments[@]}"} "$BASELINE_VERSION" \
  --products InnoFlow InnoFlowCore InnoFlowSwiftUI InnoFlowTesting InnoFlowInspector

echo "[api-compatibility] Public API is compatible with $BASELINE_VERSION"
