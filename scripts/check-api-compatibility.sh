#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BASELINE_VERSION="${INNOFLOW_API_BASELINE:-6.0.0}"
STABLE_VERSION_FILE="${INNOFLOW_STABLE_VERSION_FILE:-$ROOT_DIR/STABLE_VERSION}"

if [[ ! "$BASELINE_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "[api-compatibility] Invalid numeric SemVer baseline: $BASELINE_VERSION" >&2
  exit 2
fi

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

echo "[api-compatibility] Comparing public products with $BASELINE_VERSION"
swift package diagnose-api-breaking-changes "$BASELINE_VERSION" \
  --products InnoFlow InnoFlowCore InnoFlowSwiftUI InnoFlowTesting

echo "[api-compatibility] Public API is compatible with $BASELINE_VERSION"
