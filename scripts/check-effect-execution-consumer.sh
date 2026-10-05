#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$ROOT/Tests/Fixtures/EffectExecutionConsumer"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PACKAGE="${INNOFLOW_CONSUMER_PACKAGE_PATH:-$ROOT}"
JOBS="${INNOFLOW_CONSUMER_JOBS:-1}"
INNOFLOW_CONSUMER_PACKAGE_PATH="$PACKAGE" INNOFLOW_EFFECT_CONSUMER_NEGATIVE='' \
  swift run --package-path "$FIXTURE" --scratch-path "$TMP/build" --jobs "$JOBS" -Xswiftc -warnings-as-errors Consumer \
  >"$TMP/positive.log" 2>&1 || { cat "$TMP/positive.log"; exit 1; }
cat "$TMP/positive.log"
for variant in capacity admission removed-case; do
  if INNOFLOW_CONSUMER_PACKAGE_PATH="$PACKAGE" INNOFLOW_EFFECT_CONSUMER_NEGATIVE="$variant" \
    swift build --package-path "$FIXTURE" --scratch-path "$TMP/build" --jobs "$JOBS" -Xswiftc -warnings-as-errors \
    >"$TMP/$variant.log" 2>&1; then
    echo "error: negative effect consumer unexpectedly compiled: $variant" >&2
    exit 1
  fi
  case "$variant" in
    capacity) expected="negative integer.*overflows.*UInt" ;;
    admission) expected="switch must be exhaustive" ;;
    removed-case) expected="has no member 'invalidCapacity'" ;;
  esac
  if ! grep -Eq "$expected" "$TMP/$variant.log"; then
    cat "$TMP/$variant.log" >&2
    echo "error: negative consumer failed for an unrelated reason: $variant" >&2
    exit 1
  fi
  echo "Expected effect consumer rejection verified: $variant"
done
