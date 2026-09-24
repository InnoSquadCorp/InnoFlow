#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 --platform <iOS|tvOS|watchOS|visionOS> [--runtime <latest|runtime-id>] [runtime-test-options]"
  echo "Runtime test options: --package-root <dir> --derived-data <dir> --result-bundle <path>"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
platform=""
runtime="latest"
forwarded=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform)
      platform="${2:-}"
      shift 2
      ;;
    --runtime)
      runtime="${2:-}"
      shift 2
      ;;
    --package-root|--derived-data|--result-bundle)
      forwarded+=( "$1" "${2:-}" )
      shift 2
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done

case "$platform" in
  iOS)
    runtime_prefix="com.apple.CoreSimulator.SimRuntime.iOS-"
    device_types=( "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro" )
    destination_platform="iOS Simulator"
    ;;
  tvOS)
    runtime_prefix="com.apple.CoreSimulator.SimRuntime.tvOS-"
    device_types=( "com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-4K" )
    destination_platform="tvOS Simulator"
    ;;
  watchOS)
    runtime_prefix="com.apple.CoreSimulator.SimRuntime.watchOS-"
    device_types=( "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-10-46mm" )
    destination_platform="watchOS Simulator"
    ;;
  visionOS)
    runtime_prefix="com.apple.CoreSimulator.SimRuntime.xrOS-"
    device_types=(
      "com.apple.CoreSimulator.SimDeviceType.Apple-Vision-Pro-4K"
      "com.apple.CoreSimulator.SimDeviceType.Apple-Vision-Pro"
    )
    destination_platform="visionOS Simulator"
    ;;
  *)
    usage
    exit 64
    ;;
esac

if [[ "$runtime" == "latest" ]]; then
  runtime="$({ xcrun simctl list runtimes -j; } | /usr/bin/python3 -c '
import json
import re
import sys

prefix = sys.argv[1]
candidates = []
for runtime in json.load(sys.stdin).get("runtimes", []):
    identifier = runtime.get("identifier", "")
    if not runtime.get("isAvailable", False) or not identifier.startswith(prefix):
        continue
    version = tuple(int(part) for part in re.findall(r"\d+", runtime.get("version", "")))
    candidates.append((version, identifier))
if not candidates:
    sys.exit(1)
print(max(candidates)[1])
' "$runtime_prefix")"
fi

if ! xcrun simctl list runtimes -j | /usr/bin/python3 -c '
import json
import sys

identifier = sys.argv[1]
if not any(
    runtime.get("identifier") == identifier and runtime.get("isAvailable", False)
    for runtime in json.load(sys.stdin).get("runtimes", [])
):
    sys.exit(1)
' "$runtime"; then
  echo "Requested simulator runtime is unavailable: $runtime" >&2
  exit 69
fi

device_name="InnoFlow-Focused-${platform}-$$"
device_id=""
for device_type in "${device_types[@]}"; do
  if device_id="$(xcrun simctl create "$device_name" "$device_type" "$runtime" 2>/dev/null)"; then
    break
  fi
done
if [[ -z "$device_id" ]]; then
  echo "No compatible simulator device type for platform=$platform runtime=$runtime" >&2
  exit 69
fi
cleanup() {
  xcrun simctl shutdown "$device_id" >/dev/null 2>&1 || true
  xcrun simctl delete "$device_id" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

echo "[focused-runtime] created=$device_name id=$device_id runtime=$runtime"
xcrun simctl boot "$device_id"
xcrun simctl bootstatus "$device_id" -b
if (( ${#forwarded[@]} > 0 )); then
  "$script_dir/run-focused-platform-runtime-tests.sh" \
    --destination "platform=$destination_platform,id=$device_id" \
    "${forwarded[@]}"
else
  "$script_dir/run-focused-platform-runtime-tests.sh" \
    --destination "platform=$destination_platform,id=$device_id"
fi
