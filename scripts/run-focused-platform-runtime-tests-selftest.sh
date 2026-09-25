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
discovery_output=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-test-enumeration-output-path" ]]; then
    discovery_output="${2:-}"
    shift 2
    continue
  fi
  if [[ "$1" == "-resultBundlePath" ]]; then
    mkdir -p "$2"
    break
  fi
  shift
done
if [[ -n "$discovery_output" ]]; then
  /usr/bin/python3 - "$discovery_output" <<'PY'
import json
import os
import sys

with open(os.environ["FOCUSED_RUNTIME_INVENTORY"], encoding="utf-8") as stream:
    identifiers = json.load(stream)["expectedTestIdentifiers"]
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
  /usr/bin/python3 - "${4:-}" <<'PY'
import json
import os
import sys

with open(os.environ["FOCUSED_RUNTIME_INVENTORY"], encoding="utf-8") as stream:
    identifiers = json.load(stream)["expectedTestIdentifiers"]
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
if sys.argv[1] == "summary":
    print(json.dumps({
        "result": "Passed", "failedTests": 0, "skippedTests": 0,
        "expectedFailures": 0, "runtimeWarnings": [],
        "totalTestCount": len(identifiers),
    }))
elif sys.argv[1] == "tests":
    print(json.dumps({"tests": [
        {"nodeType": "Test Case", "nodeIdentifier": identifier, "result": "Passed"}
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
export FOCUSED_RUNTIME_INVENTORY="$TMP_ROOT/package/docs/contracts/runtime-test-inventory.json"

run_probe() {
  rm -f "$FOCUSED_RUNTIME_COMMAND_LOG"
  "$SCRIPT_DIR/run-focused-platform-runtime-tests.sh" \
    --destination "platform=iOS Simulator,id=FAKE-DEVICE-ID" \
    --package-root "$TMP_ROOT/package" || return $?
  [[ -s "$FOCUSED_RUNTIME_COMMAND_LOG" ]]
}

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
for suite in StoreScopeSelectionTests CollectionScopeCacheTests SingleScopeCacheTests; do
  grep -Fx -- "-only-testing:InnoFlowTests/$suite" "$FOCUSED_RUNTIME_COMMAND_LOG" >/dev/null
done

for mode in partial missing renamed duplicate zero; do
  export FOCUSED_RUNTIME_FIXTURE_MODE="$mode"
  if run_probe >/dev/null 2>&1; then
    echo "Incomplete runtime fixture unexpectedly passed: $mode" >&2
    exit 1
  fi
done
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
