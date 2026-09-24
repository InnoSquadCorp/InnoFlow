#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
fixture_root="$(mktemp -d)"
cleanup() {
  if [[ "${INNOFLOW_KEEP_PREFLIGHT_FIXTURE:-0}" == "1" ]]; then
    echo "[release-preflight-selftest] fixture=$fixture_root" >&2
  else
    rm -rf "$fixture_root"
  fi
}
trap cleanup EXIT
repo="$fixture_root/repo"
evidence="$fixture_root/evidence"
mkdir -p "$repo/scripts" "$repo/docs/contracts"
for script in run-release-preflight.sh run-release-preflight.rb release-candidate-snapshot.rb \
  release-evidence-tool.rb release-evidence-output-parser.rb record-release-evidence.sh \
  verify-release-evidence.sh; do
  cp "$script_dir/$script" "$repo/scripts/$script"
done
chmod +x "$repo/scripts/"*.sh "$repo/scripts/"*.rb
cat >"$repo/scripts/principle-gates.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "--static" ]] || exit 64
if [[ "${INNOFLOW_FIXTURE_FAIL:-0}" == "1" ]]; then
  echo 'intentional fixture failure'
  exit 7
fi
if [[ "${INNOFLOW_FIXTURE_WAIT:-0}" == "1" ]]; then
  printf 'ready\n' >"${INNOFLOW_FIXTURE_READY:?}"
  sleep 20
fi
echo 'fixture static gate passed'
SH
chmod +x "$repo/scripts/principle-gates.sh"
cat >"$repo/docs/contracts/release-evidence-policy.json" <<'JSON'
{
  "schema": "inno-flow-release-evidence-policy-v3",
  "stageOrder": ["local-preflight", "pre-publication", "post-publication"],
  "profiles": {
    "static": {"evidenceKind": "automated", "resultFormat": "command-exit", "artifactContent": "allow-empty"},
    "command": {"evidenceKind": "automated", "resultFormat": "command-exit", "artifactContent": "non-empty"}
  },
  "checks": [
    {"id": "static-innoflow-diff", "stage": "local-preflight", "requirement": "required", "profile": "static", "allowedCommand": "git diff --check", "component": "innoflow", "commandContract": {"executable": "git", "exactArguments": ["diff", "--check"]}},
    {"id": "static-principle", "stage": "local-preflight", "requirement": "required", "profile": "command", "allowedCommand": "scripts/principle-gates.sh --static", "component": "innoflow", "commandContract": {"executable": "scripts/principle-gates.sh", "exactArguments": ["--static"]}}
  ],
  "matrices": []
}
JSON
git -C "$repo" init -q
git -C "$repo" config user.name "InnoFlow Preflight Test"
git -C "$repo" config user.email "preflight@example.invalid"
git -C "$repo" add scripts docs
git -C "$repo" commit -qm fixture

cd "$repo"
scripts/run-release-preflight.sh plan --evidence-root "$evidence" --check-id static-innoflow-diff |
  grep -q 'git diff --check'
scripts/run-release-preflight.sh execute --evidence-root "$evidence" --check-id static-innoflow-diff |
  grep -q 'PASS static-innoflow-diff'
scripts/run-release-preflight.sh report --evidence-root "$evidence" --check-id static-innoflow-diff |
  grep -q 'PASS_VERIFIED'
scripts/run-release-preflight.sh resume --evidence-root "$evidence" --check-id static-innoflow-diff |
  grep -q 'REUSED static-innoflow-diff'
[[ "$(wc -l <"$evidence/attempts.tsv")" -eq 2 ]]

if INNOFLOW_FIXTURE_FAIL=1 scripts/run-release-preflight.sh execute --evidence-root "$evidence" --check-id static-principle >"$fixture_root/failure.log" 2>&1; then
  echo "Failed gate was accepted" >&2
  exit 1
fi
grep -q 'static-principle failed' "$fixture_root/failure.log"
scripts/run-release-preflight.sh resume --evidence-root "$evidence" --check-id static-principle |
  grep -q 'PASS static-principle'
scripts/run-release-preflight.sh report --evidence-root "$evidence" --check-id static-principle |
  grep -q 'PASS_VERIFIED.*attempts=2'
[[ "$(wc -l <"$evidence/attempts.tsv")" -eq 4 ]]

ruby -e 'File.open(ARGV[0], "w") { |lock| lock.flock(File::LOCK_EX); File.write(ARGV[1], "ready"); sleep 10 }' \
  "$evidence/.runner.lock" "$fixture_root/lock-ready" &
lock_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -f "$fixture_root/lock-ready" ]] && break
  sleep 0.1
done
[[ -f "$fixture_root/lock-ready" ]]
if scripts/run-release-preflight.sh resume --evidence-root "$evidence" --check-id static-principle >"$fixture_root/lock.log" 2>&1; then
  echo "Concurrent runner was accepted" >&2
  kill "$lock_pid"
  exit 1
fi
grep -q 'Another preflight runner' "$fixture_root/lock.log"
kill "$lock_pid"
wait "$lock_pid" 2>/dev/null || true

interrupt_evidence="$fixture_root/interrupted-evidence"
INNOFLOW_FIXTURE_WAIT=1 INNOFLOW_FIXTURE_READY="$fixture_root/interrupt-ready" \
  scripts/run-release-preflight.sh execute --evidence-root "$interrupt_evidence" \
    --check-id static-principle >"$fixture_root/interrupt.log" 2>&1 &
runner_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [[ -f "$fixture_root/interrupt-ready" ]] && break
  sleep 0.1
done
[[ -f "$fixture_root/interrupt-ready" ]]
kill -TERM "$runner_pid"
if wait "$runner_pid" 2>/dev/null; then
  echo "Interrupted runner returned success" >&2
  exit 1
fi
grep -q $'\tINTERRUPTED\t' "$interrupt_evidence/attempts.tsv"
scripts/run-release-preflight.sh resume --evidence-root "$interrupt_evidence" --check-id static-principle |
  grep -q 'PASS static-principle'
scripts/run-release-preflight.sh report --evidence-root "$interrupt_evidence" --check-id static-principle |
  grep -q 'PASS_VERIFIED.*attempts=2'

mkdir -p "$fixture_root/fakebin"
cat >"$fixture_root/fakebin/df" <<'SH'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'fixture 100 99 1 99%% /\n'
SH
chmod +x "$fixture_root/fakebin/df"
if PATH="$fixture_root/fakebin:$PATH" scripts/run-release-preflight.sh execute \
  --evidence-root "$fixture_root/low-space-evidence" --check-id static-principle \
  >"$fixture_root/low-space.log" 2>&1; then
  echo "Low-disk preflight was accepted" >&2
  exit 1
fi
grep -q 'Insufficient free space' "$fixture_root/low-space.log"
[[ ! -f "$fixture_root/low-space-evidence/attempts.tsv" ]]

artifact="$(find "$evidence/runs" -name output.log -type f -print -quit)"
printf 'tampered\n' >>"$artifact"
if scripts/run-release-preflight.sh resume --evidence-root "$evidence" --check-id static-innoflow-diff >"$fixture_root/tamper.log" 2>&1; then
  echo "Tampered receipt was reused" >&2
  exit 1
fi
grep -q 'stale or damaged' "$fixture_root/tamper.log"
[[ "$(wc -l <"$evidence/attempts.tsv")" -eq 4 ]]

printf 'candidate changed\n' >"$repo/candidate-marker.txt"
git -C "$repo" add candidate-marker.txt
git -C "$repo" commit -qm changed-candidate
if scripts/run-release-preflight.sh resume --evidence-root "$evidence" --check-id static-principle >"$fixture_root/candidate.log" 2>&1; then
  echo "Changed candidate was accepted" >&2
  exit 1
fi
grep -q 'Candidate snapshot changed' "$fixture_root/candidate.log"
scripts/run-release-preflight.sh report --evidence-root "$evidence" --check-id static-principle |
  grep -q 'STALE_CANDIDATE'

printf 'dirty\n' >"$repo/dirty-file"
if scripts/run-release-preflight.sh execute --evidence-root "$fixture_root/dirty-evidence" --check-id static-innoflow-diff >"$fixture_root/dirty.log" 2>&1; then
  echo "Dirty candidate was accepted" >&2
  exit 1
fi
grep -q 'clean isolated candidate' "$fixture_root/dirty.log"
echo '[release-preflight-selftest] plan, execute, verified report, reuse, fail/retry, lock, interrupt/retry, disk, tamper, candidate-change, dirty controls passed'
