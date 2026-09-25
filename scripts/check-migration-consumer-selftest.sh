#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT
mkdir -p "$fixture_root/scripts" "$fixture_root/Tests/Fixtures/MigrationConsumer"
cp "$script_dir/check-migration-consumer.sh" "$fixture_root/scripts/"
printf '// fixture\n' >"$fixture_root/Tests/Fixtures/MigrationConsumer/Package.swift"
git -C "$fixture_root" init -q
git -C "$fixture_root" config user.name "Migration Test"
git -C "$fixture_root" config user.email "migration@example.invalid"
git -C "$fixture_root" add .
git -C "$fixture_root" commit -qm fixture
git -C "$fixture_root" tag -a 5.1.1 -m wrong-baseline
if "$fixture_root/scripts/check-migration-consumer.sh" >"$fixture_root/output.log" 2>&1; then
  echo "Moved 5.1.1 baseline was accepted" >&2
  exit 1
fi
grep -q '5.1.1 baseline ref changed' "$fixture_root/output.log"
echo '[migration-consumer-selftest] moved annotated baseline rejected'
