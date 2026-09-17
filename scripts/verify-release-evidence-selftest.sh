#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
verifier="$script_dir/verify-release-evidence.sh"
recorder="$script_dir/record-release-evidence.sh"
manual_recorder="$script_dir/record-manual-release-evidence.sh"
snapshot_tool="$script_dir/release-candidate-snapshot.rb"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

repository="$fixture_root/repository"
evidence="$fixture_root/evidence"
policy="$fixture_root/policy.json"
snapshot="$fixture_root/candidate.json"
manifest="$fixture_root/manifest.tsv"
fake_bin="$fixture_root/bin"
mkdir -p "$repository" "$evidence" "$fake_bin"
git -C "$repository" init -q
git -C "$repository" config user.name selftest
git -C "$repository" config user.email selftest@example.invalid
printf 'candidate\n' >"$repository/source.txt"
git -C "$repository" add source.txt
git -C "$repository" commit -qm candidate

cat >"$policy" <<'JSON'
{
  "schema":"inno-flow-release-evidence-policy-v3",
  "stageOrder":["local-preflight","pre-publication","post-publication"],
  "profiles":{
    "static":{"evidenceKind":"automated","resultFormat":"command-exit","artifactContent":"allow-empty"},
    "command":{"evidenceKind":"automated","resultFormat":"command-exit","artifactContent":"non-empty"},
    "swift":{"evidenceKind":"automated","resultFormat":"swift-test-output","artifactContent":"non-empty","minimumTestCount":1},
    "tests":{"evidenceKind":"automated","resultFormat":"xcresult-summary","artifactContent":"non-empty","requiresRawArtifact":true,"minimumTestCount":2,"allowsExpectedFailures":false,"allowsRuntimeWarnings":false},
    "manual":{"evidenceKind":"manual-attestation","resultFormat":"manual-observation","artifactContent":"non-empty"}
  },
  "checks":[
    {"id":"static-empty","stage":"local-preflight","requirement":"required","profile":"static","allowedCommand":"true","component":"fixture","commandContract":{"executable":"true","exactArguments":[]}},
    {"id":"core","stage":"local-preflight","requirement":"required","profile":"command","allowedCommand":"printf","component":"fixture","commandContract":{"executable":"printf"}},
    {"id":"swift","stage":"local-preflight","requirement":"required","profile":"swift","allowedCommand":"printf","component":"fixture","commandContract":{"executable":"printf"},"minimumTestCount":2,"maximumTestCount":2,"expectedTestRunCount":1,"expectedResultSuites":["Required suite"]},
    {"id":"ui","stage":"local-preflight","requirement":"required","profile":"tests","allowedCommand":"xcodebuild test","component":"fixture","commandContract":{"executable":"xcodebuild","requiredArguments":["test","-resultBundlePath"]},"expectedTestIdentifiers":["A/testOne","A/testTwo"],"environment":{"platform":"iOS Simulator","os":"18.5"}},
    {"id":"voiceover","stage":"local-preflight","requirement":"required","profile":"manual","environment":{"assistiveTechnology":"VoiceOver"}},
    {"id":"mutator","stage":"local-preflight","requirement":"optional","profile":"command","allowedCommand":"sh -c","component":"fixture","commandContract":{"executable":"sh","exactArguments":["-c","printf mutation >> source.txt"]}},
    {"id":"interruptor","stage":"local-preflight","requirement":"optional","profile":"command","allowedCommand":"sh -c","component":"fixture","commandContract":{"executable":"sh","exactArguments":["-c","kill -TERM \"$PPID\"; sleep 1"]}},
    {"id":"remote","stage":"pre-publication","requirement":"required","profile":"command","allowedCommand":"printf","component":"fixture","commandContract":{"executable":"printf"},"trustedProducerRequired":true}
  ],
  "matrices":[]
}
JSON

"$snapshot_tool" --repository "fixture=$repository" --policy "$policy" >"$snapshot"
candidate_hash="$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("aggregateDigest")' "$snapshot")"
head_sha="$(git -C "$repository" rev-parse HEAD)"
producer_json="$(printf '{"schema":"inno-flow-github-actions-producer-v1","repository":"InnoSquad/InnoFlow","workflowPath":".github/workflows/release-evidence.yml","ref":"refs/heads/main","headSha":"%s","runId":"123","runAttempt":"1","candidateComponentLabel":"fixture"}' "$head_sha")"
trusted_context="$fixture_root/trusted-context.json"
printf '%s\n' "$(printf '{"schema":"inno-flow-github-actions-producer-v1","repository":"InnoSquad/InnoFlow","workflowPath":".github/workflows/release-evidence.yml","ref":"refs/heads/main","headSha":"%s","runId":"123","runAttempt":"1","candidateComponentLabel":"fixture","conclusion":"success","event":"workflow_dispatch","artifactName":"innoflow-release-evidence-fixture","artifactId":"77","artifactDigest":"sha256:%064d","artifactExpired":false,"artifactCreatedAt":"2026-09-11T00:00:00Z","artifactExpiresAt":"2026-10-11T00:00:00Z"}' "$head_sha" 0)" >"$trusted_context"

cat >"$fake_bin/xcrun" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
raw=""; kind=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    summary|tests) kind="$1" ;;
    --path) raw="${2:-}"; shift ;;
  esac
  shift
done
[[ -n "$raw" && -n "$kind" ]]
cat "$raw/$kind.json"
SH
chmod +x "$fake_bin/xcrun"
cat >"$fake_bin/xcodebuild" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
destination=""; fixture=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -resultBundlePath) destination="${2:-}"; shift ;;
    --fixture) fixture="${2:-}"; shift ;;
  esac
  shift
done
[[ -n "$destination" && -n "$fixture" ]]
cp -R "$SELFTEST_XCRESULT_FIXTURES/$fixture.xcresult" "$destination"
echo "TEST SUCCEEDED"
SH
chmod +x "$fake_bin/xcodebuild"
export PATH="$fake_bin:$PATH"
export SELFTEST_XCRESULT_FIXTURES="$fixture_root/xcresults"

make_xcresult() {
  local name="$1" result="$2" failed="$3" expected="$4" warnings="$5"
  local raw="$SELFTEST_XCRESULT_FIXTURES/$name.xcresult"
  mkdir -p "$raw"
  printf '{"result":"%s","totalTestCount":2,"passedTests":%s,"failedTests":%s,"skippedTests":0,"expectedFailures":%s,"runtimeWarnings":%s,"devicesAndConfigurations":[{"device":{"platform":"iOS Simulator","osVersion":"18.5","deviceId":"fixture-device"}}]}\n' \
    "$result" "$((2 - failed))" "$failed" "$expected" "$warnings" >"$raw/summary.json"
  if [[ "$result" == "Passed" ]]; then
    printf '{"nodes":[{"nodeType":"Test Case","nodeIdentifier":"A/testOne","result":"Passed"},{"nodeType":"Test Case","nodeIdentifier":"A/testTwo","result":"Passed"}]}\n' >"$raw/tests.json"
  else
    printf '{"nodes":[{"nodeType":"Test Case","nodeIdentifier":"A/testOne","result":"Failed"},{"nodeType":"Test Case","nodeIdentifier":"A/testTwo","result":"Failed"}]}\n' >"$raw/tests.json"
  fi
}

record() {
  local check_id="$1" artifact="$2" receipt="$3"; shift 3
  (cd "$repository" && "$recorder" --policy "$policy" --check-id "$check_id" --candidate-hash "$candidate_hash" \
    --candidate-snapshot "$snapshot" --evidence-root "$evidence" --artifact "$artifact" \
    --receipt "$receipt" --toolchain selftest --repository "fixture=$repository" \
    --component-label fixture --manifest manifest.tsv "$@")
}

verify_local() {
  "$verifier" --policy "$policy" --candidate-hash "$candidate_hash" --candidate-snapshot "$snapshot" \
    --evidence-root "$evidence" --manifest "$manifest" --stage local-preflight >/dev/null
}

expect_failure() {
  local description="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "Expected failure: $description" >&2
    exit 1
  fi
}

empty_row="$(record static-empty static-empty.log static-empty.receipt -- true)"
core_row="$(record core core.log core.receipt -- printf 'PASS\n')"
swift_output='Suite "Required suite" started.
Test "one" passed after 0.001 seconds.
Test "two" passed after 0.001 seconds.
Suite "Required suite" passed after 0.002 seconds.
Test run with 2 tests in 1 suite passed after 0.002 seconds.'
swift_row="$(record swift swift.log swift.receipt -- printf '%s\n' "$swift_output")"
make_xcresult ui Passed 0 0 '[]'
ui_row="$(record ui ui.log ui.receipt --raw-artifact ui.xcresult --environment-json '{"platform":"iOS Simulator","os":"18.5"}' -- xcodebuild test -resultBundlePath "$evidence/ui.xcresult" --fixture ui)"
printf 'VoiceOver traversal evidence\n' >"$evidence/voiceover.txt"
voiceover_row="$("$manual_recorder" --policy "$policy" --check-id voiceover --candidate-hash "$candidate_hash" \
  --candidate-snapshot "$snapshot" --evidence-root "$evidence" --artifact voiceover.txt \
  --receipt voiceover.receipt --manifest manifest.tsv --reviewer selftest --observed-at 2026-09-10T00:00:00Z \
  --environment-json '{"assistiveTechnology":"VoiceOver"}')"

write_manifest() {
  printf 'check_id\tstatus\tcandidate_hash\treceipt_path\n%s\n' "$1" >"$manifest"
}
all_local="$empty_row
$core_row
$swift_row
$ui_row
$voiceover_row"
write_manifest "$all_local"
verify_local

write_manifest "$core_row
$swift_row
$ui_row
$voiceover_row"
expect_failure "missing required row" verify_local
write_manifest "$all_local
$core_row"
expect_failure "duplicate row" verify_local
write_manifest "$all_local
unknown\tPASS\t$candidate_hash\tcore.receipt"
expect_failure "unknown check" verify_local
write_manifest "static-empty\tPASS\tstale\tstatic-empty.receipt
$core_row
$swift_row
$ui_row
$voiceover_row"
expect_failure "stale candidate" verify_local
write_manifest "$all_local"

cp "$evidence/core.log" "$fixture_root/core.log"
printf 'tampered\n' >"$evidence/core.log"
expect_failure "artifact tamper" verify_local
cp "$fixture_root/core.log" "$evidence/core.log"

core_attempt_id="$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("attemptId")' "$evidence/core.receipt")"
cp "$evidence/attempts.tsv" "$fixture_root/attempts.tsv"
awk -F '\t' -v attempt="$core_attempt_id" 'NR == 1 || $1 != attempt' "$evidence/attempts.tsv" >"$fixture_root/attempts-without-core.tsv"
cp "$fixture_root/attempts-without-core.tsv" "$evidence/attempts.tsv"
expect_failure "canonical attempt row missing" verify_local
cp "$fixture_root/attempts.tsv" "$evidence/attempts.tsv"
core_attempt="$evidence/attempts/core/$core_attempt_id.json"
cp "$core_attempt" "$fixture_root/core.attempt.json"
ruby -rjson -e 'p=ARGV.fetch(0); j=JSON.parse(File.read(p)); j["status"]="FAIL"; File.write(p, JSON.pretty_generate(j)+"\n")' "$core_attempt"
expect_failure "attempt receipt tamper" verify_local
cp "$fixture_root/core.attempt.json" "$core_attempt"

cp "$evidence/core.receipt" "$fixture_root/core.receipt"
ruby -rjson -e 'p=ARGV.fetch(0); j=JSON.parse(File.read(p)); j["command"]=["false"]; File.write(p, JSON.pretty_generate(j)+"\n")' "$evidence/core.receipt"
expect_failure "command relabel" verify_local
cp "$fixture_root/core.receipt" "$evidence/core.receipt"

cp "$snapshot" "$fixture_root/candidate.good.json"
ruby -rjson -e 'p=ARGV.fetch(0); j=JSON.parse(File.read(p)); j["components"][0]["files"][0]["sha256"]="0"*64; File.write(p, JSON.pretty_generate(j)+"\n")' "$snapshot"
expect_failure "candidate snapshot tamper" verify_local
cp "$fixture_root/candidate.good.json" "$snapshot"

mv "$evidence/ui.xcresult" "$fixture_root/ui.xcresult"
expect_failure "raw xcresult missing" verify_local
mv "$fixture_root/ui.xcresult" "$evidence/ui.xcresult"

make_xcresult all-failed Failed 2 0 '[]'
expect_failure "all tests failed" record ui failed.log failed.receipt --raw-artifact all-failed.xcresult --environment-json '{"platform":"iOS Simulator","os":"18.5"}' -- xcodebuild test -resultBundlePath "$evidence/all-failed.xcresult" --fixture all-failed
make_xcresult expected-failure Passed 0 1 '[]'
expect_failure "expected failure" record ui expected.log expected.receipt --raw-artifact expected-failure.xcresult --environment-json '{"platform":"iOS Simulator","os":"18.5"}' -- xcodebuild test -resultBundlePath "$evidence/expected-failure.xcresult" --fixture expected-failure
make_xcresult warning Passed 0 0 '[{"message":"runtime issue"}]'
expect_failure "runtime warning" record ui warning.log warning.receipt --raw-artifact warning.xcresult --environment-json '{"platform":"iOS Simulator","os":"18.5"}' -- xcodebuild test -resultBundlePath "$evidence/warning.xcresult" --fixture warning
make_xcresult wrong-required Passed 0 0 '[]'
printf '{"nodes":[{"nodeType":"Test Case","nodeIdentifier":"A/testOne","result":"Passed"},{"nodeType":"Test Case","nodeIdentifier":"A/unrelated","result":"Passed"}]}\n' >"$SELFTEST_XCRESULT_FIXTURES/wrong-required.xcresult/tests.json"
expect_failure "missing required test identifier" record ui wrong-required.log wrong-required.receipt --raw-artifact wrong-required.xcresult --environment-json '{"platform":"iOS Simulator","os":"18.5"}' -- xcodebuild test -resultBundlePath "$evidence/wrong-required.xcresult" --fixture wrong-required
make_xcresult stale Passed 0 0 '[]'
cp -R "$SELFTEST_XCRESULT_FIXTURES/stale.xcresult" "$evidence/stale.xcresult"
expect_failure "preexisting xcresult" record ui stale.log stale.receipt --raw-artifact stale.xcresult --environment-json '{"platform":"iOS Simulator","os":"18.5"}' -- xcodebuild test -resultBundlePath "$evidence/stale.xcresult" --fixture stale
[[ ! -e "$evidence/stale.log" ]] || { echo "Command ran with a stale xcresult" >&2; exit 1; }
expect_failure "empty artifact forbidden" record core empty-core.log empty-core.receipt -- true
expect_failure "zero Swift tests" record swift zero-swift.log zero-swift.receipt -- printf 'Test run with 0 tests in 0 suites passed after 0.001 seconds.\n'
expect_failure "hidden Swift failure behind exit zero" record swift hidden-failure.log hidden-failure.receipt -- printf 'Test run with 2 tests in 1 suite failed after 0.001 seconds.\n%s\n' "$swift_output"
expect_failure "hidden Swift skip behind exit zero" record swift hidden-skip.log hidden-skip.receipt -- printf 'Test "ignored" skipped because unavailable.\n%s\n' "$swift_output"
expect_failure "path traversal" record core ../escape.log escape.receipt -- printf 'PASS\n'
expect_failure "unexpected argument rejected before execution" record static-empty should-not-run.log should-not-run.receipt -- true --unexpected
[[ ! -e "$evidence/should-not-run.log" ]] || { echo "Policy-violating command executed" >&2; exit 1; }
expect_failure "candidate mutation during execution" record mutator mutation.log mutation.receipt -- sh -c 'printf mutation >> source.txt'
[[ ! -e "$evidence/mutation.receipt" ]] || { echo "Mutation receipt must not exist" >&2; exit 1; }
expect_failure "interrupted evidence command" record interruptor interrupted.log interrupted.receipt -- sh -c 'kill -TERM "$PPID"; sleep 1'
[[ ! -e "$evidence/interrupted.receipt" ]] || { echo "Interrupted receipt must not become canonical" >&2; exit 1; }
git -C "$repository" checkout -q -- source.txt
printf 'preexisting mutation\n' >>"$repository/source.txt"
expect_failure "candidate mutation before execution" record static-empty before-mutation.log before-mutation.receipt -- true
[[ ! -e "$evidence/before-mutation.log" ]] || { echo "Command ran for stale candidate" >&2; exit 1; }
git -C "$repository" checkout -q -- source.txt

remote_row="$(record remote remote.log remote.receipt --producer-json "$producer_json" -- printf 'PASS\n')"
write_manifest "$all_local
$remote_row"
expect_failure "trusted context required" "$verifier" --policy "$policy" --candidate-hash "$candidate_hash" \
  --candidate-snapshot "$snapshot" --evidence-root "$evidence" --manifest "$manifest" --stage pre-publication
"$verifier" --policy "$policy" --candidate-hash "$candidate_hash" --candidate-snapshot "$snapshot" \
  --evidence-root "$evidence" --manifest "$manifest" --stage pre-publication \
  --trusted-producer-context "$trusted_context" >/dev/null
ruby -rjson -e 'p=ARGV.fetch(0); j=JSON.parse(File.read(p)); j["runId"]="999"; File.write(p, JSON.generate(j)+"\n")' "$trusted_context"
expect_failure "trusted context mismatch" "$verifier" --policy "$policy" --candidate-hash "$candidate_hash" \
  --candidate-snapshot "$snapshot" --evidence-root "$evidence" --manifest "$manifest" --stage pre-publication \
  --trusted-producer-context "$trusted_context"

"$script_dir/release-evidence-tool.rb" record-attempt --policy "$policy" --check-id core \
  --candidate "$candidate_hash" --attempt-id interrupted-fixture --status INTERRUPTED \
  --evidence-root "$evidence" --attempt-index attempts.tsv --component-label fixture \
  --working-directory "$repository" --started-at 2026-09-10T00:00:00Z \
  --finished-at 2026-09-10T00:00:01Z --exit-code 143 \
  --detail-json '{"signal":"TERM"}' -- sleep 10 >/dev/null
expect_failure "duplicate attempt ID" "$script_dir/release-evidence-tool.rb" record-attempt \
  --policy "$policy" --check-id core --candidate "$candidate_hash" \
  --attempt-id interrupted-fixture --status INTERRUPTED --evidence-root "$evidence" \
  --attempt-index attempts.tsv --component-label fixture --working-directory "$repository" \
  --started-at 2026-09-10T00:00:00Z --finished-at 2026-09-10T00:00:01Z \
  --exit-code 143 --detail-json '{}' -- sleep 10
for status in PASS FAIL BLOCKED INTERRUPTED; do
  awk -F '\t' -v expected="$status" 'NR > 1 && $3 == expected { found = 1 } END { exit found ? 0 : 1 }' \
    "$evidence/attempts.tsv" || { echo "Attempt index is missing $status" >&2; exit 1; }
done

echo "[verify-release-evidence-selftest] All checks passed"
