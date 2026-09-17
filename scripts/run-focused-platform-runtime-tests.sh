#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 --destination <xcodebuild-destination> [--package-root <dir>] [--derived-data <dir>] [--result-bundle <path>]"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package_root="$(cd "$script_dir/.." && pwd)"
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
      package_root="$(cd "${2:-}" && pwd)"
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

workspace_args=()
if [[ -d "$package_root/InnoFlow.xcodeproj" ]]; then
  package_workspace="$package_root/.swiftpm/xcode/package.xcworkspace"
  workspace_data="$package_workspace/contents.xcworkspacedata"
  if [[ ! -f "$workspace_data" ]]; then
    mkdir -p "$package_workspace"
    printf '%s\n' \
      '<?xml version="1.0" encoding="UTF-8"?>' \
      '<Workspace version="1.0">' \
      '  <FileRef location="self:"></FileRef>' \
      '</Workspace>' > "$workspace_data"
  fi
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
  "${workspace_args[@]}"
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
)
if [[ -n "$derived_data" ]]; then
  command+=( -derivedDataPath "$derived_data" )
fi
command+=( -resultBundlePath "$result_bundle" )

echo "[focused-runtime] package=$package_root"
echo "[focused-runtime] destination=$destination"
xcodebuild -version
xcrun swift --version

cd "$package_root"
"${command[@]}"

summary_file="$validation_root/summary.json"
tests_file="$validation_root/tests.json"
xcrun xcresulttool get test-results summary --path "$result_bundle" --compact >"$summary_file"
xcrun xcresulttool get test-results tests --path "$result_bundle" --compact >"$tests_file"
cat "$summary_file"
/usr/bin/python3 - "$summary_file" "$tests_file" <<'PY'
import json
import sys

summary = json.load(open(sys.argv[1], encoding="utf-8"))
tests = json.load(open(sys.argv[2], encoding="utf-8"))
errors = []
result = summary.get("result")
if result != "Passed":
    errors.append("result=%s" % result)
for key in ("failedTests", "skippedTests", "expectedFailures"):
    if summary.get(key, 0) != 0:
        errors.append("%s=%s" % (key, summary.get(key)))
if summary.get("runtimeWarnings"):
    errors.append("runtimeWarnings=%s" % len(summary["runtimeWarnings"]))

cases = []
def collect(node):
    if isinstance(node, dict):
        if node.get("nodeType") == "Test Case":
            cases.append(node)
        for value in node.values():
            collect(value)
    elif isinstance(node, list):
        for value in node:
            collect(value)
collect(tests)

if len(cases) != summary.get("totalTestCount", 0):
    errors.append("discovered=%s summary=%s" % (len(cases), summary.get("totalTestCount", 0)))
if any(case.get("result") != "Passed" for case in cases):
    errors.append("non-passed-test-case")

identifiers = [case.get("nodeIdentifier") or case.get("name") or "" for case in cases]
required_suites = (
    "DispatchDiagnosticsTests/",
    "EffectRunSchedulerTests/",
    "FlowScopeTests/",
    "OutputCasePathTests/",
)
for required in required_suites:
    if not any(required in identifier for identifier in identifiers):
        errors.append("missing-suite=%s" % required)
if errors:
    print("[focused-runtime] FAILED " + " ".join(errors), file=sys.stderr)
    sys.exit(1)
print("[focused-runtime] PASS tests=%s" % summary["totalTestCount"])
PY
