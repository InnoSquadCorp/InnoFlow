#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
if [[ "$(uname -s)" != Darwin ]]; then
  echo "SwiftUI consumer requires a real Apple SDK; Linux is not a passing substitute" >&2
  exit 2
fi
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
INNOFLOW_PACKAGE_PATH="${INNOFLOW_PACKAGE_PATH:-$root}" swift build \
  --package-path "$root/Tests/Fixtures/SwiftUIConsumer" --scratch-path "$scratch/build" \
  --jobs "${SWIFT_JOBS:-1}" -Xswiftc -warnings-as-errors
