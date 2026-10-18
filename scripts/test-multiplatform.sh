#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

"$ROOT_DIR/scripts/check-multiplatform-contract.sh"
"$ROOT_DIR/kotlin/gradlew" -p "$ROOT_DIR/kotlin" \
  test \
  :android-sample:assembleDebug \
  :inno-flow-android:lintRelease \
  :inno-flow-compose:lintRelease \
  :inno-flow-core:checkKotlinAbi \
  :inno-flow-testing:checkKotlinAbi \
  :inno-flow-ksp:checkKotlinAbi \
  :inno-flow-android:checkKotlinAbi \
  :inno-flow-compose:checkKotlinAbi \
  :android-sample:assembleRelease \
  publishAllPublicationsToTestRepository
"$ROOT_DIR/kotlin/gradlew" -p "$ROOT_DIR/kotlin/consumer-fixture" test --refresh-dependencies
"$ROOT_DIR/kotlin/gradlew" -p "$ROOT_DIR/kotlin/android-consumer-fixture" testDebugUnitTest assembleRelease --refresh-dependencies
python3 "$ROOT_DIR/scripts/check-ksp-fixtures.py"
python3 "$ROOT_DIR/scripts/check-android-api-selftest.py"
python3 "$ROOT_DIR/scripts/check-multiplatform-ci.py" --self-test
python3 "$ROOT_DIR/scripts/check-android-restoration-selftest.py"

(
  cd "$ROOT_DIR/typescript"
  npm ci
  npm audit --audit-level=moderate
  npm test
  npm run test:packed
  npm run test:packed:selftest
)

echo "[multiplatform] Kotlin/Android/KSP and TypeScript/React 1.0 validation passed"
