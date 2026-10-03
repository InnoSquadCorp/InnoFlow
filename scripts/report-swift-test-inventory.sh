#!/usr/bin/env bash
set -euo pipefail

# Emit root host targets, or the separate sample package with --sample.
# This intentionally does not update policy or claim Apple execution evidence.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
sample=0
if [[ "${1:-}" == "--sample" ]]; then sample=1; shift; fi
root="${1:-$(cd "$script_dir/.." && pwd -P)}"
[[ $# -le 1 && -f "$root/Package.swift" ]] || {
  echo "Usage: $0 [--sample] [repository-root]" >&2
  exit 64
}
package_relative="."
targets=( InnoFlowTests InnoFlowMacrosTests )
if (( sample )); then
  package_relative="Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage"
  targets=( InnoFlowSampleAppFeatureTests )
fi
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
host="$(swiftc -print-target-info | python3 -c 'import json,sys; print(json.load(sys.stdin)["paths"]["runtimeResourcePath"] + "/host")')"
[[ -d "$host" ]] || { echo "SwiftSyntax host modules unavailable: $host" >&2; exit 65; }
swiftc "$script_dir/swift-test-inventory.swift" -I "$host" -L "$host" \
  -Xlinker -rpath -Xlinker "$host" -o "$scratch/inventory"
"$scratch/inventory" "$root/$package_relative" "${targets[@]}" >"$scratch/tests.json"
python3 - "$root" "$scratch/tests.json" "$package_relative" "${targets[@]}" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
package_relative = Path(sys.argv[3])
targets = sys.argv[4:]
files = [root / package_relative / "Package.swift"]
for target in targets:
    directory = root / package_relative / "Tests" / target
    files += [path for path in directory.rglob("*.swift")
              if "Fixtures" not in path.relative_to(directory).parts]
tests = json.loads(Path(sys.argv[2]).read_text())
for test in tests:
    test["file"] = str(package_relative / test["file"])
print(json.dumps({
    "schemaVersion": 1,
    "countSemantics": "One Swift Testing declaration per test, including parameterized tests once; XCTest is excluded from this parser count. Source expectation only, never an execution receipt.",
    "hostTargets": targets,
    "sourceFiles": {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in sorted(files)},
    "tests": sorted(tests, key=lambda test: (test["target"], test["identifier"])),
}, indent=2, ensure_ascii=False) + "\n", end="")
PY
