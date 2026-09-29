#!/usr/bin/env bash
set -euo pipefail

required=(
  RELEASE_GATE_RESULT
  RELEASE_PLATFORM_BUILDS_RESULT
  RELEASE_RUNTIME_TESTS_RESULT
  RELEASE_SANITIZERS_RESULT
  RELEASE_COVERAGE_RESULT
)
for name in "${required[@]}"; do
  value="${!name:-}"
  if [[ "$value" != "success" ]]; then
    echo "Required release job did not succeed: $name=${value:-missing}" >&2
    exit 1
  fi
done
echo "[verify-release-prerequisites] OK"
