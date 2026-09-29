#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
mkdir -p "$ROOT_DIR/.build/coverage"
output="$(mktemp -d "$ROOT_DIR/.build/coverage/run.XXXXXX")"
printf 'RUNNING\n' > "$output/status.txt"
finish() {
  local result=$?
  if [[ "$result" -eq 0 ]]; then
    printf 'PASS\n' > "$output/status.txt"
  else
    printf 'FAIL exit=%s\n' "$result" > "$output/status.txt"
  fi
}
trap finish EXIT
echo "[coverage] Evidence directory: $output"

# Bind the run to the complete local candidate, including untracked source.
snapshot=(ruby scripts/release-candidate-snapshot.rb --repository "innoflow=$ROOT_DIR"
  --policy docs/contracts/release-evidence-policy.json)
"${snapshot[@]}" > "$output/candidate-before.json"
swift test --enable-code-coverage --jobs 2 --no-parallel -Xswiftc -warnings-as-errors \
  2>&1 | tee "$output/tests.log"
scripts/generate-coverage-report.sh "$output/coverage.lcov"
"${snapshot[@]}" > "$output/candidate-after.json"
cmp "$output/candidate-before.json" "$output/candidate-after.json" || {
  echo '[coverage] Candidate changed during coverage execution' >&2
  exit 1
}
python3 scripts/validate-coverage-report.py "$output/coverage.lcov" \
  --policy docs/contracts/coverage-policy.json --output "$output/summary.json"
