#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 --platform <macOS|iOS|tvOS|watchOS|visionOS> --derived-data <absolute-dir> --result-bundle <absolute-xcresult>" >&2
  exit 64
}

[[ $# -eq 6 && "$1" == "--platform" && "$3" == "--derived-data" && "$5" == "--result-bundle" ]] || usage
platform="$2"
derived_data="$4"
result_bundle="$6"
case "$platform" in macOS|iOS|tvOS|watchOS|visionOS) ;; *) usage ;; esac
[[ "$derived_data" == /* && "$result_bundle" == /* ]] || usage
[[ ! -e "$result_bundle" && ! -L "$result_bundle" ]] || {
  echo "SDK result bundle already exists: $result_bundle" >&2
  exit 65
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package_root="$(cd "$script_dir/.." && pwd -P)"
[[ -f "$package_root/Package.swift" ]] || {
  echo "InnoFlow package is missing" >&2
  exit 65
}
workspace="$package_root/.swiftpm/xcode/package.xcworkspace"
for segment in "$package_root/.swiftpm" "$package_root/.swiftpm/xcode" "$workspace"; do
  [[ ! -L "$segment" ]] || {
    echo "SDK workspace path contains a symlink: $segment" >&2
    exit 65
  }
done
mkdir -p "$workspace"
workspace_data="$workspace/contents.xcworkspacedata"
if [[ ! -e "$workspace_data" ]]; then
  printf '%s\n' \
    '<?xml version="1.0" encoding="UTF-8"?>' \
    '<Workspace version="1.0">' \
    '  <FileRef location="self:"></FileRef>' \
    '</Workspace>' >"$workspace_data"
fi
[[ ! -L "$workspace" && ! -L "$workspace_data" ]] || {
  echo "SDK workspace must not be a symlink" >&2
  exit 65
}
[[ "$(cd "$workspace" && pwd -P)" == "$workspace" ]] || {
  echo "SDK workspace is redirected outside the package" >&2
  exit 65
}
/usr/bin/python3 - "$workspace_data" <<'PY' || {
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
if (root.tag != "Workspace" or root.attrib != {"version": "1.0"} or
        len(root) != 1 or root[0].tag != "FileRef" or
        root[0].attrib != {"location": "self:"} or len(root[0]) != 0):
    raise SystemExit("SDK workspace contains an unexpected project reference")
PY
  echo "SDK workspace contents are not the package-only workspace" >&2
  exit 65
}

echo "[sdk-build] platform=$platform package=$package_root"
xcodebuild \
  -quiet \
  -jobs 1 \
  -workspace "$workspace" \
  -scheme InnoFlow-Package \
  -destination "generic/platform=$platform" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$result_bundle" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
xcrun xcresulttool get build-results --path "$result_bundle" --compact |
  /usr/bin/python3 -c '
import json
import re
import sys

expected = sys.argv[1]
result = json.load(sys.stdin)
print(json.dumps(result, sort_keys=True))
if (result.get("status") != "succeeded" or
        not re.match(r"^Build(?:ing)?\b", result.get("actionTitle", ""), re.I) or
        result.get("destination", {}).get("platform") != expected or
        any(result.get(key) != 0 for key in
            ("errorCount", "warningCount", "analyzerWarningCount")) or
        any(result.get(key) != [] for key in
            ("errors", "warnings", "analyzerWarnings"))):
    raise SystemExit("SDK build result is not a complete clean build")
' "$platform"
