#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" != "--scratch-path" || -z "${2:-}" || $# -ne 2 ]]; then
  echo "Usage: check-sample-swift63.sh --scratch-path <isolated-build-path>" >&2
  exit 64
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(cd "$script_dir/.." && pwd -P)"
sample="$root/Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage"
scratch="$2"

if [[ ! -f "$sample/Package.swift" ]]; then
  echo "Canonical sample package is missing" >&2
  exit 66
fi
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
if [[ ! -d "$SDKROOT" ]]; then
  echo "The selected Swift 6.3 Xcode has no macOS SDK" >&2
  exit 65
fi

# The CLI consumer does not require PreviewsMacros. This flag excludes only
# source-level #Preview declarations; the unflagged Xcode sample build is a
# separate required gate and verifies that previews remain compilable.
exec "$script_dir/run-swift-toolchain-evidence.sh" --expected-prefix 6.3 -- \
  swift test --package-path "$sample" --scratch-path "$scratch" \
    --disable-automatic-resolution --jobs 1 --no-parallel -Xswiftc -warnings-as-errors \
    -Xswiftc -DINNOFLOW_DISABLE_PREVIEWS
