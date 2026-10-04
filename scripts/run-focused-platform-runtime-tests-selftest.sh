#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_ROOT="$(mktemp -d)"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/package"
printf '%s\n' '// swift-tools-version: 6.0' >"$TMP_ROOT/package/Package.swift"
mkdir -p "$TMP_ROOT/package/docs/contracts"
cp "$SCRIPT_DIR/../docs/contracts/runtime-test-inventory.json" \
  "$TMP_ROOT/package/docs/contracts/runtime-test-inventory.json"
cp "$SCRIPT_DIR/../docs/contracts/release-evidence-policy.json" \
  "$TMP_ROOT/package/docs/contracts/release-evidence-policy.json"

cat >"$TMP_ROOT/bin/xcodebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-version" ]]; then
  printf '%s\n' 'Xcode selftest'
  exit 0
fi
printf '%s\n' "$@" >"$FOCUSED_RUNTIME_COMMAND_LOG"
original_arguments=( "$@" )
discovery_output=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-test-enumeration-output-path" ]]; then
    discovery_output="${2:-}"
    shift 2
    continue
  fi
  if [[ "$1" == "-resultBundlePath" ]]; then
    mkdir -p "$2"
    if [[ "${FOCUSED_RUNTIME_FIXTURE_MODE:-}" == xcode-failure* ]]; then
      exit 65
    fi
    break
  fi
  shift
done
if [[ -n "$discovery_output" ]]; then
  printf '%s\n' "${original_arguments[@]}" >"$FOCUSED_RUNTIME_DISCOVERY_LOG"
  if [[ "$(printf '%s\n' "${original_arguments[@]}" | grep -c '^\-only-testing:' || true)" != 1 ]] ||
      ! printf '%s\n' "${original_arguments[@]}" | grep -Fx -- '-only-testing:InnoFlowTests' >/dev/null; then
    echo "Discovery attempted host-only InnoFlowMacrosTests.xctest without the runtime target restriction" >&2
    exit 65
  fi
  /usr/bin/python3 - "$discovery_output" <<'PY'
import json
import os
import sys

with open(os.environ["FOCUSED_RUNTIME_INVENTORY"], encoding="utf-8") as stream:
    inventory = json.load(stream)
    identifiers = inventory["expectedTestIdentifiers"]
mode = os.environ.get("FOCUSED_RUNTIME_FIXTURE_MODE", "complete")
if mode == "partial":
    identifiers = identifiers[:4]
elif mode == "missing":
    identifiers = identifiers[1:]
elif mode == "renamed":
    identifiers[0] = "OtherSuite/" + identifiers[0].split("/", 1)[1]
elif mode == "duplicate":
    identifiers[-1] = identifiers[0]
elif mode == "zero":
    identifiers = []
elif mode == "unreviewed-consistency":
    identifiers.append("NewConsistencyTests/newContract()")
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump({"errors": [], "values": [{
        "disabledTests": [],
        "enabledTests": [{"identifier": "InnoFlowTests/" + identifier}
                         for identifier in identifiers],
    }]}, stream)
PY
fi
EOF
chmod +x "$TMP_ROOT/bin/xcodebuild"

cat >"$TMP_ROOT/bin/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "swift" ]]; then
  printf '%s\n' 'Apple Swift version selftest'
  exit 0
fi
if [[ "${1:-}" == "xcresulttool" && "${2:-}" == "get" && "${3:-}" == "test-results" ]]; then
  if [[ "${FOCUSED_RUNTIME_FIXTURE_MODE:-}" == "xcode-failure-unreadable" ]]; then
    exit 42
  fi
  /usr/bin/python3 - "${4:-}" <<'PY'
import json
import os
import sys

with open(os.environ["FOCUSED_RUNTIME_INVENTORY"], encoding="utf-8") as stream:
    inventory = json.load(stream)
    identifiers = inventory["expectedTestIdentifiers"]
mode = os.environ.get("FOCUSED_RUNTIME_FIXTURE_MODE", "complete")
if mode == "partial":
    identifiers = identifiers[:4]
elif mode == "missing":
    identifiers = identifiers[1:]
elif mode == "renamed":
    identifiers[0] = "OtherSuite/" + identifiers[0].split("/", 1)[1]
elif mode == "duplicate":
    identifiers[-1] = identifiers[0]
elif mode == "zero":
    identifiers = []
diagnostics = inventory.get("expectedFailureTestIdentifiers", [])
results = {identifier: "Expected Failure" if identifier in diagnostics else "Passed"
           for identifier in identifiers}
if mode == "diagnostic-missing":
    results[diagnostics[0]] = "Passed"
elif mode == "diagnostic-extra":
    results[next(item for item in identifiers if item not in diagnostics)] = "Expected Failure"
elif mode == "diagnostic-swapped":
    results[diagnostics[0]] = "Passed"
    results[next(item for item in identifiers if item not in diagnostics)] = "Expected Failure"
elif mode == "diagnostic-failed":
    results[diagnostics[0]] = "Failed"
elif mode == "diagnostic-skipped":
    results[diagnostics[0]] = "Skipped"
if sys.argv[1] == "summary":
    if mode == "xcode-failure":
        print(json.dumps({"result": "Failed", "failedTests": 1,
                          "testFailures": [{"failureText": "fixture assertion details"}]}))
        raise SystemExit(0)
    summary = {
        "result": "Passed", "failedTests": list(results.values()).count("Failed"),
        "skippedTests": list(results.values()).count("Skipped"),
        "passedTests": list(results.values()).count("Passed"),
        "expectedFailures": list(results.values()).count("Expected Failure"), "runtimeWarnings": [],
        "totalTestCount": len(identifiers),
    }
    if mode == "diagnostic-duplicate-issue":
        summary["expectedFailures"] += 1
    elif mode == "diagnostic-wrong-passed-count":
        summary["passedTests"] = len(identifiers)
    elif mode == "diagnostic-warning":
        summary["runtimeWarnings"] = ["unexpected warning"]
    print(json.dumps(summary))
elif sys.argv[1] == "tests":
    print(json.dumps({"tests": [
        {"nodeType": "Test Case", "nodeIdentifier": identifier, "result": results[identifier]}
        for identifier in identifiers
    ]}))
else:
    raise SystemExit(64)
PY
  exit 0
fi
printf 'unexpected xcrun arguments: %s\n' "$*" >&2
exit 64
EOF
chmod +x "$TMP_ROOT/bin/xcrun"

export PATH="$TMP_ROOT/bin:$PATH"
export FOCUSED_RUNTIME_COMMAND_LOG="$TMP_ROOT/command.log"
export FOCUSED_RUNTIME_DISCOVERY_LOG="$TMP_ROOT/discovery-command.log"
export FOCUSED_RUNTIME_INVENTORY="$TMP_ROOT/package/docs/contracts/runtime-test-inventory.json"

run_probe() {
  rm -f "$FOCUSED_RUNTIME_COMMAND_LOG" "$FOCUSED_RUNTIME_DISCOVERY_LOG"
  "$SCRIPT_DIR/run-focused-platform-runtime-tests.sh" \
    --destination "platform=iOS Simulator,id=FAKE-DEVICE-ID" \
    --package-root "$TMP_ROOT/package" || return $?
  [[ -s "$FOCUSED_RUNTIME_COMMAND_LOG" ]]
}

run_probe
grep -Fx -- '-only-testing:InnoFlowTests' "$FOCUSED_RUNTIME_DISCOVERY_LOG" >/dev/null
if grep -F -- '-only-testing:InnoFlowMacrosTests' "$FOCUSED_RUNTIME_DISCOVERY_LOG" >/dev/null; then
  echo "Simulator discovery attempted host-only macro tests" >&2
  exit 1
fi
# A regression that removes only the discovery restriction must fail before
# runtime execution, just as the hosted 27.0 runtime diagnostic did.
cp "$SCRIPT_DIR/run-focused-platform-runtime-tests.sh" "$TMP_ROOT/unrestricted-runtime.sh"
sed '/^  -only-testing:InnoFlowTests$/d' "$TMP_ROOT/unrestricted-runtime.sh" >"$TMP_ROOT/unrestricted-runtime.tmp"
mv "$TMP_ROOT/unrestricted-runtime.tmp" "$TMP_ROOT/unrestricted-runtime.sh"
chmod +x "$TMP_ROOT/unrestricted-runtime.sh"
status=0
"$TMP_ROOT/unrestricted-runtime.sh" \
  --destination "platform=iOS Simulator,id=FAKE-DEVICE-ID" \
  --package-root "$TMP_ROOT/package" >"$TMP_ROOT/unrestricted.log" 2>&1 || status=$?
[[ "$status" == 65 ]] || {
  echo "Unrestricted runtime discovery did not fail closed: $status" >&2
  exit 1
}
grep -F 'host-only InnoFlowMacrosTests.xctest' "$TMP_ROOT/unrestricted.log" >/dev/null
if grep -Fx -- '-resultBundlePath' "$FOCUSED_RUNTIME_COMMAND_LOG" >/dev/null; then
  echo "Runtime execution proceeded after unrestricted discovery" >&2
  exit 1
fi
run_probe
if grep -Fx -- '-workspace' "$FOCUSED_RUNTIME_COMMAND_LOG" >/dev/null; then
  echo "Unexpected workspace redirect for a plain Swift package" >&2
  exit 1
fi

mkdir -p "$TMP_ROOT/package/InnoFlow.xcodeproj"
run_probe
grep -Fx -- '-workspace' "$FOCUSED_RUNTIME_COMMAND_LOG" >/dev/null
grep -Fx -- "$TMP_ROOT/package/.swiftpm/xcode/package.xcworkspace" \
  "$FOCUSED_RUNTIME_COMMAND_LOG" >/dev/null
for suite in $(/usr/bin/python3 -c 'import json, sys; print(" ".join(json.load(open(sys.argv[1]))["suites"]))' "$FOCUSED_RUNTIME_INVENTORY"); do
  grep -Fx -- "-only-testing:InnoFlowTests/$suite" "$FOCUSED_RUNTIME_COMMAND_LOG" >/dev/null
done

for mode in partial missing renamed duplicate zero unreviewed-consistency \
    diagnostic-missing diagnostic-extra diagnostic-swapped diagnostic-failed diagnostic-skipped \
    diagnostic-duplicate-issue diagnostic-wrong-passed-count diagnostic-warning; do
  export FOCUSED_RUNTIME_FIXTURE_MODE="$mode"
  if run_probe >/dev/null 2>&1; then
    echo "Incomplete runtime fixture unexpectedly passed: $mode" >&2
    exit 1
  fi
done
unset FOCUSED_RUNTIME_FIXTURE_MODE
for mode in xcode-failure xcode-failure-unreadable; do
  export FOCUSED_RUNTIME_FIXTURE_MODE="$mode"
  failure_status=0
  failure_bundle="$TMP_ROOT/$mode.xcresult"
  "$SCRIPT_DIR/run-focused-platform-runtime-tests.sh" \
    --destination "platform=iOS Simulator,id=FAKE-DEVICE-ID" \
    --package-root "$TMP_ROOT/package" \
    --result-bundle "$failure_bundle" >"$TMP_ROOT/$mode.log" 2>&1 || failure_status=$?
  [[ "$failure_status" == 65 ]] || {
    echo "xcodebuild failure status was masked for $mode: $failure_status" >&2
    exit 1
  }
  [[ -d "$failure_bundle" ]] || {
    echo "Explicit failure result bundle was not preserved" >&2
    exit 1
  }
done
grep -F 'fixture assertion details' "$TMP_ROOT/xcode-failure.log" >/dev/null
grep -F 'failure summary could not be extracted' "$TMP_ROOT/xcode-failure-unreadable.log" >/dev/null
unset FOCUSED_RUNTIME_FIXTURE_MODE
mv "$TMP_ROOT/package/.swiftpm" "$TMP_ROOT/workspace-good"
mkdir "$TMP_ROOT/foreign-workspace"
ln -s "$TMP_ROOT/foreign-workspace" "$TMP_ROOT/package/.swiftpm"
if run_probe >/dev/null 2>&1; then
  echo "Symlinked runtime workspace unexpectedly passed" >&2
  exit 1
fi
[[ ! -e "$FOCUSED_RUNTIME_COMMAND_LOG" ]] || {
  echo "Runtime test command ran after workspace redirection" >&2
  exit 1
}
unlink "$TMP_ROOT/package/.swiftpm"
mv "$TMP_ROOT/workspace-good" "$TMP_ROOT/package/.swiftpm"
printf '\n' >>"$FOCUSED_RUNTIME_INVENTORY"
if run_probe >/dev/null 2>&1; then
  echo "Tampered runtime inventory unexpectedly passed" >&2
  exit 1
fi

echo "[run-focused-platform-runtime-tests-selftest] All checks passed"
