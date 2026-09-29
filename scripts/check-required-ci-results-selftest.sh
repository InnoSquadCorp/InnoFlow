#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
checker="$script_dir/check-required-ci-results.rb"
jobs=(
  coverage lint tests release-tests api-compatibility thread-sanitizer
  sample-tests package-builds focused-runtime-tests principle-gates
  sample-package-builds sample-build address-sanitizer sample-ui-tests
)

success_args=()
for job in "${jobs[@]}"; do success_args+=("$job=success"); done
ruby "$checker" push "${success_args[@]}" >/dev/null

pr_args=("${success_args[@]}")
for index in "${!pr_args[@]}"; do
  [[ "${pr_args[$index]}" == address-sanitizer=* ]] || continue
  pr_args[$index]="address-sanitizer=skipped"
done
ruby "$checker" pull_request "${pr_args[@]}" >/dev/null

expect_failure() {
  local description="$1"; shift
  if ruby "$checker" "$@" >/dev/null 2>&1; then
    echo "Expected CI result failure: $description" >&2
    exit 1
  fi
}

for result in failure cancelled skipped; do
  mutated=("${success_args[@]}")
  mutated[0]="coverage=$result"
  expect_failure "coverage $result" push "${mutated[@]}"
done

expect_failure "push ASan skipped" push "${pr_args[@]}"
pr_failed=("${success_args[@]}")
for index in "${!pr_failed[@]}"; do
  [[ "${pr_failed[$index]}" == address-sanitizer=* ]] || continue
  pr_failed[$index]="address-sanitizer=failure"
done
expect_failure "PR ASan failure" pull_request "${pr_failed[@]}"
expect_failure "missing result" push "${success_args[@]:1}"
expect_failure "unknown job" push "${success_args[@]}" unknown=success
expect_failure "duplicate result" push "${success_args[@]}" coverage=success

echo "[check-required-ci-results-selftest] All checks passed"
