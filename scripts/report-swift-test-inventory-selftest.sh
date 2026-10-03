#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/Tests/InnoFlowTests/Fixtures" "$fixture/Tests/InnoFlowMacrosTests"
printf '// swift-tools-version: 6.3\n' >"$fixture/Package.swift"
cat >"$fixture/Tests/InnoFlowTests/Runtime.swift" <<'SWIFT'
import Testing
// @Test func commentIsNotATest() {}
let template = """
@Test func templateIsNotATest() {}
"""
@Suite struct RuntimeTests {
  @Test("One parameterized declaration", arguments: [1, 2])
  func parameterized(value: Int) {}
  #if os(macOS) || os(Linux)
    @Test func hostConditional() {}
  #endif
}
class XCTestFixture {
  func testXCTestDoesNotInflateSwiftTestingCount() {}
}
SWIFT
cat >"$fixture/Tests/InnoFlowMacrosTests/Macro.swift" <<'SWIFT'
import Testing
@Suite struct MacroTests {
  @Test("Host macro") func macro() {}
}
SWIFT
printf '@Test func resourceIsNotCompiled() {}\n' >"$fixture/Tests/InnoFlowTests/Fixtures/Resource.swift"
"$script_dir/report-swift-test-inventory.sh" "$fixture" >"$fixture/inventory.json"
python3 - "$fixture/inventory.json" <<'PY'
import json
import sys
inventory = json.load(open(sys.argv[1]))
keys = [(test["target"], test["identifier"]) for test in inventory["tests"]]
assert keys == [("InnoFlowMacrosTests", "MacroTests/macro()"),
                ("InnoFlowTests", "RuntimeTests/hostConditional()"),
                ("InnoFlowTests", "RuntimeTests/parameterized(value:)")], keys
assert inventory["tests"][1]["conditionalContexts"] == ["#if os(macOS) || os(Linux)"]
assert len(inventory["sourceFiles"]) == 3
assert not any("Fixtures/" in path for path in inventory["sourceFiles"])
PY
# Determinism is part of the pin: equivalent input cannot churn policy hashes.
"$script_dir/report-swift-test-inventory.sh" "$fixture" >"$fixture/repeated.json"
cmp "$fixture/inventory.json" "$fixture/repeated.json"
sample_relative="Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage"
mkdir -p "$fixture/$sample_relative/Tests/InnoFlowSampleAppFeatureTests"
printf '// swift-tools-version: 6.3\n' >"$fixture/$sample_relative/Package.swift"
printf 'import Testing\n@Test func separateSample() {}\n' >"$fixture/$sample_relative/Tests/InnoFlowSampleAppFeatureTests/Sample.swift"
"$script_dir/report-swift-test-inventory.sh" --sample "$fixture" >"$fixture/sample.json"
python3 - "$fixture/sample.json" <<'PY_SAMPLE'
import json
import sys
inventory = json.load(open(sys.argv[1]))
assert inventory["hostTargets"] == ["InnoFlowSampleAppFeatureTests"]
assert len(inventory["tests"]) == 1
assert inventory["tests"][0]["identifier"] == "separateSample()"
assert all(path.startswith("Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage/")
           for path in inventory["sourceFiles"])
PY_SAMPLE
printf '@Test func malformed( {\n' >"$fixture/Tests/InnoFlowTests/Invalid.swift"
if "$script_dir/report-swift-test-inventory.sh" "$fixture" >"$fixture/invalid.json" 2>"$fixture/invalid.log"; then
  echo "Malformed Swift source produced a usable inventory" >&2
  exit 1
fi
grep -F 'Invalid Swift test source:' "$fixture/invalid.log" >/dev/null
echo "[report-swift-test-inventory-selftest] All checks passed"
