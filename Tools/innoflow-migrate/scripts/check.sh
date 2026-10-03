#!/usr/bin/env bash
# Independent external-package gate. Source files are copied, then changed ONLY by the CLI.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
tool_root="$(cd "$script_dir/.." && pwd -P)"
root="$(cd "$tool_root/../.." && pwd -P)"
tool_package="${INNOFLOW_MIGRATE_TOOL_PACKAGE:-$tool_root}"
candidate="${INNOFLOW_MIGRATION_PACKAGE_PATH:-$root}"
temporary="$(mktemp -d)"
cleanup() {
  if [[ "${INNOFLOW_KEEP_CODEMOD_FIXTURE:-0}" == 1 ]]; then
    echo "[innoflow-migrate] preserved=$temporary" >&2
  else
    rm -rf "$temporary"
  fi
}
trap cleanup EXIT

echo "[innoflow-migrate] tool=$tool_package candidate=$candidate"
swift test --package-path "$tool_package" --scratch-path "$temporary/tool-build" --jobs 1 -Xswiftc -warnings-as-errors
swift build --package-path "$tool_package" --scratch-path "$temporary/tool-build" --jobs 1 -Xswiftc -warnings-as-errors
bin_path="$(swift build --package-path "$tool_package" --scratch-path "$temporary/tool-build" --show-bin-path)"
binary="$bin_path/innoflow-migrate"
python3 "$script_dir/check-cli.py" "$binary"

mkdir -p "$temporary/consumer" "$temporary/semantics"
cp -R "$root/Tests/Fixtures/MigrationConsumer/." "$temporary/consumer/"
cp -R "$tool_root/Fixtures/SemanticsConsumer/." "$temporary/semantics/"
inputs=(
  "$temporary/consumer/Sources/V5Consumer/main.swift"
  "$temporary/consumer/Tests/TestingCompat/V5Semantics.swift"
  "$temporary/consumer/Tests/TestingCompat/TestingCompat.swift"
  "$temporary/semantics/Tests/MigrationSemantics/Semantics.swift"
)
cmp "${inputs[0]}" "$root/Tests/Fixtures/MigrationConsumer/Sources/V5Consumer/main.swift"
cmp "${inputs[1]}" "$root/Tests/Fixtures/MigrationConsumer/Tests/TestingCompat/V5Semantics.swift"
"$binary" "${inputs[@]}" >"$temporary/migration.patch" 2>"$temporary/migration-report.txt"
if "$binary" --check "${inputs[@]}" >/dev/null 2>&1; then
  echo 'Expected pending V5 migration edits, but check reported clean' >&2
  exit 1
else
  [[ "$?" == 1 ]] || { cat "$temporary/migration-report.txt" >&2; exit 1; }
fi
"$binary" --write "${inputs[@]}" >>"$temporary/applied.patch" 2>>"$temporary/migration-report.txt"
"$binary" --check "${inputs[@]}" >"$temporary/idempotent.patch" 2>>"$temporary/migration-report.txt"
[[ ! -s "$temporary/idempotent.patch" ]]
cmp "${inputs[0]}.innoflow-migrate.bak" "$root/Tests/Fixtures/MigrationConsumer/Sources/V5Consumer/main.swift"
cmp "${inputs[1]}.innoflow-migrate.bak" "$root/Tests/Fixtures/MigrationConsumer/Tests/TestingCompat/V5Semantics.swift"
# SPM warns about retained backups in target directories. Move originals to the artifact directory.
mkdir -p "$temporary/originals"
for i in "${!inputs[@]}"; do
  [[ ! -f "${inputs[$i]}.innoflow-migrate.bak" ]] || mv "${inputs[$i]}.innoflow-migrate.bak" "$temporary/originals/$i.swift"
done
export INNOFLOW_MIGRATION_PACKAGE_PATH="$candidate"
export INNOFLOW_MIGRATION_VARIANT=V5Consumer
swift run --package-path "$temporary/consumer" --scratch-path "$temporary/consumer-build" --jobs 1 \
  -Xswiftc -warnings-as-errors V5Consumer >"$temporary/consumer.log" 2>&1 || { tail -100 "$temporary/consumer.log"; exit 1; }
grep '^MIGRATION_COMMON count=2 selected=2$' "$temporary/consumer.log"
swift test --package-path "$temporary/consumer" --scratch-path "$temporary/consumer-build" --jobs 1 --no-parallel \
  -Xswiftc -warnings-as-errors >>"$temporary/consumer.log" 2>&1 || { tail -100 "$temporary/consumer.log"; exit 1; }
grep 'Test run with 3 tests' "$temporary/consumer.log"
swift test --package-path "$temporary/semantics" --scratch-path "$temporary/semantics-build" --jobs 1 --no-parallel \
  -Xswiftc -warnings-as-errors >"$temporary/semantics.log" 2>&1 || { tail -100 "$temporary/semantics.log"; exit 1; }
grep 'Test run with 2 tests' "$temporary/semantics.log"
echo '[innoflow-migrate] actual V5Consumer: zero manual source edits, external compile/run and 3 tests passed'
echo '[innoflow-migrate] typed output, legacy EffectTask promotion and terminal finish: 2 tests passed'
