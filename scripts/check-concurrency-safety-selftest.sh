#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf 'struct Safe: Sendable {}\n' > "$TMP/Fixture.swift"
"$ROOT/scripts/check-concurrency-safety.sh" "$TMP" >/dev/null
for escape in '@unchecked Sendable' 'nonisolated(unsafe)' 'MainActor.assumeIsolated' '@preconcurrency' 'OSAllocatedUnfairLock(uncheckedState: value)' 'lock.withLockUnchecked' 'lock.withLockIfAvailableUnchecked'; do
  printf '%s\n' "$escape" > "$TMP/Fixture.swift"
  if "$ROOT/scripts/check-concurrency-safety.sh" "$TMP" >/dev/null 2>&1; then
    echo "error: concurrency gate accepted negative control: $escape" >&2
    exit 1
  fi
done
if "$ROOT/scripts/check-concurrency-safety.sh" "$TMP/missing" >/dev/null 2>&1; then
  echo 'error: concurrency gate accepted a missing source tree' >&2
  exit 1
fi
echo 'Concurrency safety gate selftest passed: positive and all negative controls'
