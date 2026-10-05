#!/usr/bin/env bash
# Keep production concurrency contracts explicit and checked by the compiler.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_ROOT="${1:-$ROOT/Sources}"
if [[ ! -d "$SOURCE_ROOT" ]]; then
  echo "error: source directory does not exist: $SOURCE_ROOT" >&2
  exit 2
fi
set +e
matches="$(grep -REn --include='*.swift' '(@unchecked[[:space:]]+Sendable|nonisolated[[:space:]]*\([[:space:]]*unsafe|assumeIsolated|@preconcurrency|uncheckedState[[:space:]]*:|withLock(IfAvailable)?Unchecked)' "$SOURCE_ROOT" 2>&1)"
status=$?
set -e
case "$status" in
  0)
    printf 'error: unchecked concurrency escape in production sources:\n%s\n' "$matches" >&2
    exit 1
    ;;
  1)
    echo 'Concurrency safety gate passed: no unchecked production escapes'
    ;;
  *)
    printf 'error: concurrency source scan failed:\n%s\n' "$matches" >&2
    exit 2
    ;;
esac
