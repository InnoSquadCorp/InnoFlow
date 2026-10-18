#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

required_files=(
  "contracts/SEMANTICS.md"
  "contracts/conformance/counter-v1.json"
  "contracts/conformance/runtime-v1.json"
  "docs/MULTIPLATFORM.md"
  "docs/RELEASING_MULTIPLATFORM.md"
  "kotlin/inno-flow-core/src/main/kotlin/com/innosquad/innoflow/FlowStore.kt"
  "kotlin/inno-flow-core/api/inno-flow-core.api"
  "kotlin/inno-flow-android/src/main/kotlin/com/innosquad/innoflow/android/ViewModelFlowStore.kt"
  "kotlin/inno-flow-compose/src/main/kotlin/com/innosquad/innoflow/compose/FlowStoreCompose.kt"
  "kotlin/inno-flow-android/api/inno-flow-android.api"
  "kotlin/inno-flow-compose/api/inno-flow-compose.api"
  "kotlin/android-consumer-fixture/build.gradle.kts"
  "kotlin/ksp-fixtures/build.gradle.kts"
  "kotlin/inno-flow-testing/src/main/kotlin/com/innosquad/innoflow/testing/TestStore.kt"
  "kotlin/inno-flow-ksp/src/main/resources/META-INF/services/com.google.devtools.ksp.processing.SymbolProcessorProvider"
  "kotlin/consumer-fixture/src/main/kotlin/com/example/CounterFeature.kt"
  "kotlin/android-sample/src/main/AndroidManifest.xml"
  "typescript/packages/core/src/store.ts"
  "typescript/packages/react/src/index.ts"
  "typescript/packages/testing/src/index.ts"
  "typescript/examples/react-consumer/vite.config.ts"
  "typescript/scripts/test-packed-consumer.mjs"
  "typescript/scripts/check-packed-consumer-selftest.mjs"
  "scripts/check-ksp-fixtures.py"
  "scripts/check-multiplatform-ci.py"
  "scripts/check-android-restoration.py"
  "scripts/check-android-restoration-selftest.py"
  ".github/workflows/ci-multiplatform.yml"
  ".github/workflows/release-kotlin.yml"
  ".github/workflows/release-typescript.yml"
)

for relative_path in "${required_files[@]}"; do
  if [[ ! -f "$ROOT_DIR/$relative_path" ]]; then
    echo "[multiplatform-contract] Missing $relative_path" >&2
    exit 1
  fi
done

python3 - "$ROOT_DIR/contracts/conformance/counter-v1.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    fixture = json.load(handle)

assert fixture.get("version") == 1, "counter conformance version must be 1"
scenarios = fixture.get("scenarios")
assert isinstance(scenarios, list) and scenarios, "counter scenarios must be non-empty"
for scenario in scenarios:
    assert isinstance(scenario.get("name"), str) and scenario["name"]
    assert isinstance(scenario.get("initial"), int)
    assert isinstance(scenario.get("expected"), int)
    assert scenario.get("actions") and all(
        action in {"increment", "decrement", "reset"}
        for action in scenario["actions"]
    )
PY

python3 - "$ROOT_DIR/contracts/conformance/runtime-v1.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    fixture = json.load(handle)
assert fixture["version"] == 1
assert len(fixture["scenarios"]) >= 6
allowed = {"increment", "later", "emit", "failReducer", "failEffect", "startDelayed", "cancel", "release", "close"}
for scenario in fixture["scenarios"]:
    assert scenario["name"] and scenario["steps"]
    assert all(step in allowed for step in scenario["steps"])
    assert isinstance(scenario["state"], int) and isinstance(scenario["failures"], int)
    assert isinstance(scenario["outputs"], list)
PY

python3 - "$ROOT_DIR" <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
gradle = (root / "kotlin/build.gradle.kts").read_text(encoding="utf-8")
match = re.search(r'^\s*version\s*=\s*"([^"]+)"', gradle, re.MULTILINE)
assert match and match.group(1) == "1.0.0", "Kotlin release version must be 1.0.0"

for relative in (
    "typescript/packages/core/package.json",
    "typescript/packages/react/package.json",
    "typescript/packages/testing/package.json",
):
    package = json.loads((root / relative).read_text(encoding="utf-8"))
    assert package["version"] == "1.0.0", f"{relative} must be 1.0.0"
PY

grep -F "@InnoFlow" "$ROOT_DIR/contracts/SEMANTICS.md" >/dev/null
grep -F "defineFlow" "$ROOT_DIR/contracts/SEMANTICS.md" >/dev/null
grep -F "FlowFeature" "$ROOT_DIR/contracts/SEMANTICS.md" >/dev/null
grep -F "collectStateWithLifecycle()" "$ROOT_DIR/docs/MULTIPLATFORM.md" >/dev/null
grep -F "useSyncExternalStore" "$ROOT_DIR/docs/MULTIPLATFORM.md" >/dev/null
grep -F "kotlin/v*.*.*" "$ROOT_DIR/.github/workflows/release-kotlin.yml" >/dev/null
grep -F "npm/v*.*.*" "$ROOT_DIR/.github/workflows/release-typescript.yml" >/dev/null

echo "[multiplatform-contract] 1.0 contracts, adapters, versions, and release boundaries are present"
