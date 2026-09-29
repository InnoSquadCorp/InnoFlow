#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(cd "$script_dir/.." && pwd -P)"
fixture="$root/Tests/Fixtures/MigrationConsumer"
[[ -f "$fixture/Package.swift" ]] || { echo "Migration fixture is missing" >&2; exit 65; }
[[ "$(git -C "$root" cat-file -t refs/tags/5.1.1)" == tag ]] || {
  echo "Exact annotated 5.1.1 baseline tag is unavailable" >&2
  exit 65
}
expected_tag_object="7782c370bd6c769e1b9fc475146bd1aabce6b97f"
expected_baseline_commit="00a73ed2d2cb94114b0be5c9fbd59c187a4b67c7"
tag_object="$(git -C "$root" rev-parse refs/tags/5.1.1)"
baseline_sha="$(git -C "$root" rev-parse 'refs/tags/5.1.1^{commit}')"
if [[ "$tag_object" != "$expected_tag_object" || "$baseline_sha" != "$expected_baseline_commit" ]]; then
  echo "5.1.1 baseline ref changed: tag=$tag_object commit=$baseline_sha" >&2
  exit 65
fi
temporary="$(mktemp -d)"
cleanup() {
  if [[ "${INNOFLOW_KEEP_MIGRATION_FIXTURE:-0}" == 1 ]]; then
    echo "[migration-consumer] preserved=$temporary" >&2
  else
    rm -rf "$temporary"
  fi
}
trap cleanup EXIT
mkdir -p "$temporary/InnoFlow" "$temporary/consumer"
git -C "$root" archive refs/tags/5.1.1 | tar -x -C "$temporary/InnoFlow"
cp -R "$fixture/." "$temporary/consumer/"

run_consumer() {
  local name="$1" package_path="$2" output="$3"
  if ! INNOFLOW_MIGRATION_PACKAGE_PATH="$package_path" INNOFLOW_MIGRATION_VARIANT="$name" \
    swift run --package-path "$temporary/consumer" \
    --scratch-path "$temporary/build-$name" --jobs 1 \
    -Xswiftc -warnings-as-errors "$name" >"$output" 2>&1; then
    tail -80 "$output" >&2
    return 1
  fi
  grep '^MIGRATION_COMMON count=2 selected=2$' "$output"
  if ! INNOFLOW_MIGRATION_PACKAGE_PATH="$package_path" INNOFLOW_MIGRATION_VARIANT="$name" \
    swift test --package-path "$temporary/consumer" \
    --scratch-path "$temporary/build-$name" --jobs 1 --no-parallel \
    -Xswiftc -warnings-as-errors >>"$output" 2>&1; then
    tail -80 "$output" >&2
    return 1
  fi
  grep -E 'Test run with 3 tests in 2 suites passed' "$output"
  echo "[migration-consumer] $name testing product passed"
}

echo "[migration-consumer] baseline_tag=5.1.1 baseline_commit=$baseline_sha"
run_consumer V5Consumer "$temporary/InnoFlow" "$temporary/v5.log"
run_consumer V6Consumer "$root" "$temporary/v6.log"
grep '^MIGRATION_V6 independent=3,4 named-reused=true scope-released=true output=42$' "$temporary/v6.log"
echo "[migration-consumer] 5.1.1 and current external consumers passed"
