#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 --destination <xcodebuild-destination> [--package-root <dir>] [--derived-data <dir>] [--result-bundle <path>]"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
package_root="$(cd "$script_dir/.." && pwd -P)"
invocation_root="$(pwd)"
destination=""
derived_data=""
result_bundle=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --destination)
      destination="${2:-}"
      shift 2
      ;;
    --package-root)
      package_root="$(cd "${2:-}" && pwd -P)"
      shift 2
      ;;
    --derived-data)
      derived_data="${2:-}"
      shift 2
      ;;
    --result-bundle)
      result_bundle="${2:-}"
      shift 2
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done

if [[ -z "$destination" || ! -f "$package_root/Package.swift" ]]; then
  usage
  exit 64
fi
inventory_file="$package_root/docs/contracts/runtime-test-inventory.json"
if [[ ! -f "$inventory_file" ]]; then
  echo "Reviewed runtime test inventory is missing: $inventory_file" >&2
  exit 65
fi
/usr/bin/python3 - "$inventory_file" "$package_root/docs/contracts/release-evidence-policy.json" <<'PY'
import hashlib
import json
import sys

with open(sys.argv[1], "rb") as stream:
    actual = hashlib.sha256(stream.read()).hexdigest()
with open(sys.argv[2], encoding="utf-8") as stream:
    checks = json.load(stream)["checks"]
runtime = [check for check in checks if check["id"].startswith("runtime-")]
if len(runtime) != 8 or any(
    check.get("testIdentifierInventorySha256") != actual
    for check in runtime
):
    raise SystemExit("Runtime inventory is not pinned by every platform policy check")
PY

workspace_args=()
if [[ -d "$package_root/InnoFlow.xcodeproj" ]]; then
  package_workspace="$package_root/.swiftpm/xcode/package.xcworkspace"
  workspace_data="$package_workspace/contents.xcworkspacedata"
  for segment in "$package_root/.swiftpm" "$package_root/.swiftpm/xcode" "$package_workspace"; do
    [[ ! -L "$segment" ]] || {
      echo "Runtime workspace path contains a symlink: $segment" >&2
      exit 65
    }
  done
  if [[ ! -f "$workspace_data" ]]; then
    mkdir -p "$package_workspace"
    printf '%s\n' \
      '<?xml version="1.0" encoding="UTF-8"?>' \
      '<Workspace version="1.0">' \
      '  <FileRef location="self:"></FileRef>' \
      '</Workspace>' > "$workspace_data"
  fi
  [[ ! -L "$workspace_data" && "$(cd "$package_workspace" && pwd -P)" == "$package_workspace" ]] || {
    echo "Runtime workspace is redirected outside the package" >&2
    exit 65
  }
  /usr/bin/python3 - "$workspace_data" <<'PY' || {
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
if (root.tag != "Workspace" or root.attrib != {"version": "1.0"} or
        len(root) != 1 or root[0].tag != "FileRef" or
        root[0].attrib != {"location": "self:"} or len(root[0]) != 0):
    raise SystemExit("Runtime workspace contains an unexpected project reference")
PY
    echo "Runtime workspace contents are not package-only" >&2
    exit 65
  }
  workspace_args=( -workspace "$package_workspace" )
fi

temporary_result_root=""
validation_root="$(mktemp -d)"
if [[ -z "$result_bundle" ]]; then
  temporary_result_root="$(mktemp -d)"
  result_bundle="$temporary_result_root/focused-runtime.xcresult"
fi
cleanup() {
  rm -rf "$validation_root"
  if [[ -n "$temporary_result_root" ]]; then
    rm -rf "$temporary_result_root"
  fi
}
trap cleanup EXIT INT TERM

case "$derived_data" in
  ""|/*) ;;
  *) derived_data="$invocation_root/$derived_data" ;;
esac
case "$result_bundle" in
  ""|/*) ;;
  *) result_bundle="$invocation_root/$result_bundle" ;;
esac
if [[ -e "$result_bundle" ]]; then
  echo "Result bundle already exists: $result_bundle" >&2
  exit 65
fi

command=(
  xcodebuild
  -quiet
  -jobs 1
  -parallel-testing-enabled NO
)
discovery_command=( "${command[@]}" )
if (( ${#workspace_args[@]} > 0 )); then
  command+=( "${workspace_args[@]}" )
  discovery_command+=( "${workspace_args[@]}" )
fi
discovery_command+=(
  -scheme InnoFlow-Package
  -destination "$destination"
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  ONLY_ACTIVE_ARCH=YES
)
command+=(
  -scheme InnoFlow-Package
  -destination "$destination"
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  ONLY_ACTIVE_ARCH=YES
  test
  -only-testing:InnoFlowTests/EffectRunSchedulerTests
  -only-testing:InnoFlowTests/DispatchDiagnosticsTests
  -only-testing:InnoFlowTests/FlowScopeTests
  -only-testing:InnoFlowTests/OutputCasePathTests
  -only-testing:InnoFlowTests/StoreScopeSelectionTests
  -only-testing:InnoFlowTests/CollectionScopeCacheTests
  -only-testing:InnoFlowTests/SingleScopeCacheTests
)
if [[ -n "$derived_data" ]]; then
  command+=( -derivedDataPath "$derived_data" )
  discovery_command+=( -derivedDataPath "$derived_data" )
fi
discovery_file="$validation_root/discovery.json"
discovery_command+=(
  -enumerate-tests
  -test-enumeration-style flat
  -test-enumeration-format json
  -test-enumeration-output-path "$discovery_file"
  test
)
command+=( -resultBundlePath "$result_bundle" )

echo "[focused-runtime] package=$package_root"
echo "[focused-runtime] destination=$destination"
xcodebuild -version
xcrun swift --version

cd "$package_root"
"${discovery_command[@]}"
/usr/bin/python3 "$script_dir/validate-focused-runtime-result.py" \
  discover "$inventory_file" "$discovery_file"
"${command[@]}"

summary_file="$validation_root/summary.json"
tests_file="$validation_root/tests.json"
xcrun xcresulttool get test-results summary --path "$result_bundle" --compact >"$summary_file"
xcrun xcresulttool get test-results tests --path "$result_bundle" --compact >"$tests_file"
cat "$summary_file"
/usr/bin/python3 "$script_dir/validate-focused-runtime-result.py" \
  "$inventory_file" "$summary_file" "$tests_file"
