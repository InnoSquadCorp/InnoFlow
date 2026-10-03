#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
package="${INNOFLOW_PACKAGE_PATH:-$root}"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
INNOFLOW_PACKAGE_PATH="$package" swift run \
  --package-path "$root/Tests/Fixtures/LevelOneConsumer" \
  --scratch-path "$temporary/build" --jobs "${SWIFT_JOBS:-1}" \
  -Xswiftc -warnings-as-errors LevelOneConsumer >"$temporary/consumer.log" 2>&1 || {
  cat "$temporary/consumer.log" >&2
  exit 1
}
cat "$temporary/consumer.log"
grep -Fx 'Level 1 consumer passed' "$temporary/consumer.log" >/dev/null
