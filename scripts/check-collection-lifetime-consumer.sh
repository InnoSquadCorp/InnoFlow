#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$ROOT/Tests/Fixtures/CollectionLifetimeConsumer"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PACKAGE="${INNOFLOW_CONSUMER_PACKAGE_PATH:-$ROOT}"
JOBS="${INNOFLOW_CONSUMER_JOBS:-1}"
INNOFLOW_CONSUMER_PACKAGE_PATH="$PACKAGE" INNOFLOW_COLLECTION_CONSUMER_NEGATIVE=0 \
  swift run --package-path "$FIXTURE" --scratch-path "$TMP/build" --jobs "$JOBS" \
  -Xswiftc -warnings-as-errors Consumer >"$TMP/positive.log" 2>&1 \
  || { cat "$TMP/positive.log"; exit 1; }
cat "$TMP/positive.log"
if INNOFLOW_CONSUMER_PACKAGE_PATH="$PACKAGE" INNOFLOW_COLLECTION_CONSUMER_NEGATIVE=1 \
  swift build --package-path "$FIXTURE" --scratch-path "$TMP/build" --jobs "$JOBS" \
  -Xswiftc -warnings-as-errors >"$TMP/negative.log" 2>&1; then
  echo "error: previous IfCaseLet initializer function unexpectedly compiled" >&2
  exit 1
fi
if ! grep -Eq "PreviousInitializer.swift:.*error: cannot convert value of type" "$TMP/negative.log" \
  || ! grep -q "StaticString" "$TMP/negative.log"; then
  cat "$TMP/negative.log" >&2
  echo "error: initializer consumer failed for an unrelated reason" >&2
  exit 1
fi
echo "Expected old IfCaseLet initializer function rejection verified"
for boundary in scope iflet foreach identified optional phase; do
  for kind in erased capture; do
    if INNOFLOW_CONSUMER_PACKAGE_PATH="$PACKAGE" \
      INNOFLOW_COLLECTION_CONSUMER_NEGATIVE="$boundary-$kind" \
      swift build --package-path "$FIXTURE" --scratch-path "$TMP/build" --jobs "$JOBS" \
      -Xswiftc -warnings-as-errors >"$TMP/$boundary-$kind.log" 2>&1; then
      echo "error: $boundary accepted a $kind non-Sendable key path" >&2
      exit 1
    fi
    if ! grep -Eq "NonSendableKeyPath.swift:.*error:.*does not conform to the 'Sendable' protocol" \
      "$TMP/$boundary-$kind.log"; then
      cat "$TMP/$boundary-$kind.log" >&2
      echo "error: $boundary $kind consumer failed for an unrelated reason" >&2
      exit 1
    fi
    echo "Expected $boundary $kind key-path rejection verified"
  done
done
