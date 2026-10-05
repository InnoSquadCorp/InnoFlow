#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
fixture_root="$(mktemp -d)"
# macOS TMPDIR can pass through /var -> /private/var. Match the runner's
# realpath evidence roots without relaxing the fixture-only df boundary.
fixture_root="$(cd "$fixture_root" && pwd -P)"
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
for script in run-release-preflight.sh run-release-preflight.rb release-runtime-catalog.rb release-candidate-snapshot.rb \
  release-evidence-tool.rb release-evidence-output-parser.rb swift-test-conditions.rb swift_test_conditions.py record-release-evidence.sh \
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
    "command": {"evidenceKind": "automated", "resultFormat": "command-exit", "artifactContent": "non-empty"},
    "tests": {"evidenceKind": "automated", "resultFormat": "xcresult-summary", "artifactContent": "non-empty", "requiresRawArtifact": true, "minimumTestCount": 1}
  },
  "checks": [
    {"id": "static-innoflow-diff", "stage": "local-preflight", "requirement": "required", "profile": "static", "allowedCommand": "git diff --check", "component": "innoflow", "commandContract": {"executable": "git", "exactArguments": ["diff", "--check"]}},
    {"id": "static-principle", "stage": "local-preflight", "requirement": "required", "profile": "command", "allowedCommand": "scripts/principle-gates.sh --static", "component": "innoflow", "commandContract": {"executable": "scripts/principle-gates.sh", "exactArguments": ["--static"]}},
    {"id": "runtime-visionos-2.5", "stage": "local-preflight", "requirement": "required", "profile": "tests", "allowedCommand": "scripts/run-focused-platform-runtime-tests.sh", "component": "innoflow", "commandContract": {"executable": "scripts/run-focused-platform-runtime-tests.sh", "requiredArguments": ["--destination", "--derived-data", "--result-bundle"]}, "environment": {"platform": "visionOS Simulator", "os": "2.5"}}
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
for mode in execute resume; do
  if GITHUB_ACTIONS=false scripts/run-release-preflight.sh "$mode" \
    --evidence-root "$fixture_root/local-forbidden-$mode" >"$fixture_root/local-$mode.log" 2>&1; then
    echo "Local release preflight was accepted: $mode" >&2
    exit 1
  fi
  grep -q 'CI-only' "$fixture_root/local-$mode.log"
  [[ ! -e "$fixture_root/local-forbidden-$mode" ]]
done
# Emulate Actions only inside this isolated fixture; never run real release checks locally.
export GITHUB_ACTIONS=true
# Toolchain identity is part of every receipt, even for the fake static gate.
# Keep toolchain and disk reads inside the fixture too. No actual build or
# runtime allocation occurs here; the low-space control below overrides df.
# Unexpected compiler/build/disk commands must fail instead of reaching the host.
mkdir -p "$fixture_root/toolchainbin"
cat >"$fixture_root/toolchainbin/swift" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 1 && "$1" == "--version" ]] || { echo 'unexpected fixture swift command' >&2; exit 64; }
[[ "${INNOFLOW_FIXTURE_TOOLCHAIN_FAIL:-}" != "swift" ]] || { echo 'intentional Swift identity failure' >&2; exit 65; }
echo 'Swift version 6.4.0 (isolated preflight selftest)'
SH
cat >"$fixture_root/toolchainbin/xcodebuild" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 1 && "$1" == "-version" ]] || { echo 'unexpected fixture xcodebuild command' >&2; exit 64; }
[[ "${INNOFLOW_FIXTURE_TOOLCHAIN_FAIL:-}" != "xcodebuild" ]] || { echo 'intentional Xcode identity failure' >&2; exit 65; }
printf 'Xcode 27.0\nBuild version ISOLATED-SELFTEST\n'
SH
cat >"$fixture_root/toolchainbin/df" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 2 && "$1" == "-Pk" && -d "$2" && "$2" == "${INNOFLOW_PREFLIGHT_FIXTURE_ROOT:?}/"* ]] || {
  echo 'unexpected fixture df command' >&2
  exit 64
}
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'fixture 52428800 1048576 51380224 2%% /\n'
SH
chmod +x "$fixture_root/toolchainbin/"*
export INNOFLOW_PREFLIGHT_FIXTURE_ROOT="$fixture_root"
export PATH="$fixture_root/toolchainbin:$PATH"
for tool in swift xcodebuild; do
  if "$tool" test >"$fixture_root/unexpected-$tool.log" 2>&1; then
    echo "Unexpected toolchain command was accepted: $tool test" >&2
    exit 1
  fi
  grep -q "unexpected fixture $tool command" "$fixture_root/unexpected-$tool.log"
done
if df -h "$fixture_root" >"$fixture_root/unexpected-df.log" 2>&1; then
  echo 'Unexpected disk command was accepted' >&2
  exit 1
fi
grep -q 'unexpected fixture df command' "$fixture_root/unexpected-df.log"
if df -Pk / >"$fixture_root/outside-fixture-df.log" 2>&1; then
  echo 'Disk read outside the fixture was accepted' >&2
  exit 1
fi
grep -q 'unexpected fixture df command' "$fixture_root/outside-fixture-df.log"
ruby -r ./scripts/release-runtime-catalog -e '
  {
    "ios" => ["iOS", "iOS Simulator", "18.5"],
    "tvos" => ["tvOS", "tvOS Simulator", "18.5"],
    "watchos" => ["watchOS", "watchOS Simulator", "11.5"],
    "visionos" => ["xrOS", "visionOS Simulator", "2.5"],
  }.each do |id, (runtime_platform, destination, version)|
    check = {"id" => "runtime-#{id}-#{version}", "environment" => {"os" => version, "platform" => destination}}
    runtime, device_types, actual_destination = ReleaseRuntimeCatalog.runtime_info(check)
    expected = "com.apple.CoreSimulator.SimRuntime.#{runtime_platform}-#{version.tr(".", "-")}"
    abort "incorrect runtime #{id}: #{runtime}" unless runtime == expected
    abort "missing device type #{id}" if device_types.empty?
    abort "incorrect destination #{id}" unless actual_destination == destination
  end
  abort "unexpected runtime entry" unless ReleaseRuntimeCatalog.runtime_info({"id" => "sdk-ios"}).nil?
'
scripts/run-release-preflight.sh plan --evidence-root "$evidence" --check-id static-innoflow-diff |
  grep -q 'git diff --check'
for tool in swift xcodebuild; do
  identity_evidence="$fixture_root/failed-identity-$tool"
  if INNOFLOW_FIXTURE_TOOLCHAIN_FAIL="$tool" scripts/run-release-preflight.sh execute \
    --evidence-root "$identity_evidence" --check-id static-innoflow-diff \
    >"$fixture_root/failed-identity-$tool.log" 2>&1; then
    echo "Failed toolchain identity was accepted: $tool" >&2
    exit 1
  fi
  option='--version'
  if [[ "$tool" == xcodebuild ]]; then option='-version'; fi
  grep -q "$tool $option failed" "$fixture_root/failed-identity-$tool.log"
  [[ ! -f "$identity_evidence/attempts.tsv" ]]
done
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

mkdir -p "$fixture_root/runtimebin"
cat >"$fixture_root/runtimebin/xcrun" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "simctl" ]] || exit 64
shift
printf '%s\n' "$*" >>"${INNOFLOW_RUNTIME_CALLS:?}"
case "${1:-}" in
  list)
    printf '%s\n' '{"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.xrOS-2-5","isAvailable":true}]}'
    ;;
  create)
    case "${3:-}" in
      *Apple-Vision-Pro-4K) printf '%s\n' 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA' ;;
      *Apple-Vision-Pro) printf '%s\n' 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB' ;;
      *) exit 65 ;;
    esac
    ;;
  boot)
    [[ "${2:-}" == 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB' ]] || { echo 'incompatible 4K device' >&2; exit 65; }
    ;;
  bootstatus)
    echo 'stop after testing fallback selection' >&2
    exit 65
    ;;
  shutdown|delete) ;;
  *) exit 64 ;;
esac
SH
chmod +x "$fixture_root/runtimebin/xcrun"
if INNOFLOW_RUNTIME_CALLS="$fixture_root/runtime-calls" PATH="$fixture_root/runtimebin:$PATH" \
  scripts/run-release-preflight.sh execute --evidence-root "$fixture_root/runtime-evidence" \
    --check-id runtime-visionos-2.5 >"$fixture_root/runtime.log" 2>&1; then
  echo "Stopped fixture runtime was accepted" >&2
  exit 1
fi
grep -q 'simctl bootstatus BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB -b failed' "$fixture_root/runtime.log"
grep -q 'delete AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA' "$fixture_root/runtime-calls"
grep -q 'delete BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB' "$fixture_root/runtime-calls"
[[ ! -f "$fixture_root/runtime-evidence/attempts.tsv" ]]

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
set -euo pipefail
[[ $# -eq 2 && "$1" == "-Pk" && -d "$2" && "$2" == "${INNOFLOW_PREFLIGHT_FIXTURE_ROOT:?}/"* ]] || {
  echo 'unexpected fixture df command' >&2
  exit 64
}
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

aggregate_repo="$fixture_root/aggregate-repo"
git clone -q "$repo" "$aggregate_repo"
git -C "$aggregate_repo" config user.name "InnoFlow Preflight Test"
git -C "$aggregate_repo" config user.email "preflight@example.invalid"
ruby -rjson -e '
  path = ARGV.fetch(0)
  policy = JSON.parse(File.read(path))
  policy.fetch("checks").reject! { |check| check.fetch("id").start_with?("runtime-") }
  File.write(path, JSON.pretty_generate(policy) + "\n")
' "$aggregate_repo/docs/contracts/release-evidence-policy.json"
git -C "$aggregate_repo" add -- docs/contracts/release-evidence-policy.json
git -C "$aggregate_repo" commit -qm aggregate-fixture
"$aggregate_repo/scripts/run-release-preflight.sh" resume \
  --evidence-root "$fixture_root/aggregate-evidence" >"$fixture_root/aggregate.log"
grep -q 'RELEASE_EVIDENCE_COMPLETE.*rows=2 expected=2' "$fixture_root/aggregate.log"
verify_aggregate_manifest() {
  ruby -e '
    lines = File.readlines(ARGV.fetch(0), chomp: true)
    abort "Wrong manifest header" unless lines.shift == "check_id\tstatus\tcandidate_hash\treceipt_path"
    rows = lines.map { |line| line.split("\t", -1) }
    abort "Expected exactly two complete PASS rows" unless rows.length == 2 &&
      rows.all? { |row| row.length == 4 && row[1] == "PASS" } &&
      rows.map(&:first).sort == %w[static-innoflow-diff static-principle]
  ' "$1"
}
verify_aggregate_manifest "$fixture_root/aggregate-evidence/manifest.tsv"
for mutation in missing duplicate extra; do
  mutated_manifest="$fixture_root/aggregate-$mutation.tsv"
  ruby -e '
    source, destination, mutation = ARGV
    lines = File.readlines(source)
    case mutation
    when "missing" then lines.delete_at(1)
    when "duplicate" then lines[2] = lines[1]
    when "extra" then lines << lines[1]
    else abort "Unknown manifest mutation"
    end
    File.write(destination, lines.join)
  ' "$fixture_root/aggregate-evidence/manifest.tsv" "$mutated_manifest" "$mutation"
  if verify_aggregate_manifest "$mutated_manifest" >"$fixture_root/aggregate-$mutation.log" 2>&1; then
    echo "Invalid aggregate manifest was accepted: $mutation" >&2
    exit 1
  fi
  grep -q 'Expected exactly two complete PASS rows' "$fixture_root/aggregate-$mutation.log"
done

echo '[release-preflight-selftest] isolated version-only toolchains and disk, identity failure, plan, execute, exact aggregate manifest and missing/duplicate/extra controls, verified report, reuse, fail/retry, runtime fallback/cleanup, lock, interrupt/retry, disk, tamper, candidate-change, dirty controls passed'
