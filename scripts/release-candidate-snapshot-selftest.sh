#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
snapshot="$script_dir/release-candidate-snapshot.rb"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

make_repository() {
  local path="$1" value="$2"
  mkdir -p "$path"
  git -C "$path" init -q
  git -C "$path" config user.email selftest@example.invalid
  git -C "$path" config user.name Selftest
  printf '%s\n' "$value" >"$path/input.txt"
  git -C "$path" add input.txt
  git -C "$path" commit -qm initial
}

make_repository "$fixture_root/one/primary" primary
make_repository "$fixture_root/one/consumer" consumer
mkdir -p "$fixture_root/two"
cp -R "$fixture_root/one/primary" "$fixture_root/two/primary"
cp -R "$fixture_root/one/consumer" "$fixture_root/two/consumer"
printf '%s\n' '{"schema":"inno-flow-release-evidence-policy-v3","checks":[]}' >"$fixture_root/policy.json"

digest() {
  "$snapshot" \
    --repository "primary=$1" \
    --repository "consumer=$2" \
    --policy "$3" \
    --digest-only
}

first="$(digest "$fixture_root/one/primary" "$fixture_root/one/consumer" "$fixture_root/policy.json")"
second="$(digest "$fixture_root/two/primary" "$fixture_root/two/consumer" "$fixture_root/policy.json")"
[[ "$first" == "$second" ]] || { echo "Absolute paths changed the content digest" >&2; exit 1; }

printf '%s\n' changed >"$fixture_root/two/consumer/input.txt"
changed="$(digest "$fixture_root/two/primary" "$fixture_root/two/consumer" "$fixture_root/policy.json")"
[[ "$first" != "$changed" ]] || { echo "Consumer content change was not detected" >&2; exit 1; }

printf '%s\n' '{"schema":"inno-flow-release-evidence-policy-v3","checks":[],"revision":2}' >"$fixture_root/policy-2.json"
policy_changed="$(digest "$fixture_root/one/primary" "$fixture_root/one/consumer" "$fixture_root/policy-2.json")"
[[ "$first" != "$policy_changed" ]] || { echo "Policy change was not detected" >&2; exit 1; }

snapshot_json="$fixture_root/snapshot.json"
"$snapshot" --repository "primary=$fixture_root/one/primary" \
  --repository "consumer=$fixture_root/one/consumer" --policy "$fixture_root/policy.json" >"$snapshot_json"
ruby -rjson -e '
  snapshot = JSON.parse(File.read(ARGV.fetch(0)))
  abort "missing revision" unless snapshot.fetch("components").all? { |component| component.fetch("headRevision").match?(/\A[0-9a-f]{40}\z/) }
  abort "missing files" unless snapshot.fetch("components").all? { |component| !component.fetch("files").empty? }
' "$snapshot_json"

"$script_dir/verify-candidate-component.sh" --candidate-snapshot "$snapshot_json" \
  --label primary --repository "$fixture_root/one/primary" --policy "$fixture_root/policy.json" >/dev/null
printf 'untracked\n' >"$fixture_root/one/primary/untracked.txt"
if "$script_dir/verify-candidate-component.sh" --candidate-snapshot "$snapshot_json" \
  --label primary --repository "$fixture_root/one/primary" --policy "$fixture_root/policy.json" >/dev/null 2>&1; then
  echo "Dirty candidate component must not match a clean snapshot" >&2
  exit 1
fi

echo "[release-candidate-snapshot-selftest] All checks passed"
