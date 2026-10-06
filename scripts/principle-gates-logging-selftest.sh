#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/selftests" "$fixture/logs"

# Match the real Swift 6.4 driver: compiler identity on stdout, driver text
# without a trailing newline on stderr. No installed compiler is invoked.
cat >"$fixture/bin/swift" <<'SH'
#!/usr/bin/env bash
[[ "$*" == '--version' ]] || exit 64
printf 'Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)\n'
printf 'Target: arm64-apple-macosx27.0.0\n'
printf 'swift-driver version: 1.168.6 ' >&2
SH
cat >"$fixture/bin/uname" <<'SH'
#!/usr/bin/env bash
[[ "$*" == '-s' ]] || exit 64
printf 'Darwin\n'
SH
cat >"$fixture/bin/sw_vers" <<'SH'
#!/usr/bin/env bash
[[ "$*" == '-productVersion' ]] || exit 64
printf '27.0\n'
SH

for script in principle-gates-selftest.sh check-concurrency-safety-selftest.sh; do
  cat >"$fixture/selftests/$script" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
name="$(basename "$0")"
printf '%s\n' "$name" >>"$FIXTURE_CALLS"
printf '[swift-test-inventory] compiler: Apple Swift version 6.4.0 (selftest)\n'
printf '[swift-test-inventory] runtime: {"deviceId":"FAKE-DEVICE-ID"}\n'
printf '[swift-test-inventory] host-runtime: {"platform":"fixture"}\n' >&2
printf '◇ Test run started.\n✔ Test run with 999 tests passed.\n'
printf 'error: Exited with unexpected signal code 6\n' >&2
printf "Test Suite 'fixture' failed at synthetic-time.\n" >&2
printf '%s stdout diagnostic\n' "$name"
printf '%s stderr diagnostic\n' "$name" >&2
if [[ "$name" == "${FIXTURE_FAIL_SCRIPT:-}" ]]; then
  exit "${FIXTURE_FAIL_STATUS:?}"
fi
SH
done
chmod +x "$fixture/bin/"* "$fixture/selftests/"*

cat >"$fixture/run.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "$1"
SCRIPT_DIR="$2/selftests"
run_workflow_security_checks() { :; }
run_authoring_surface_checks() { :; }
run_sample_static_contract_checks() { :; }
run_doc_contract_checks() { :; }
run_authoring_policy_checks() { :; }
run_macro_operations_checks() { :; }
run_community_health_checks() { :; }
run_release_build_checks() { echo real-builds >>"$FIXTURE_CALLS"; }
run_sample_runtime_contract_checks() { echo sample-builds >>"$FIXTURE_CALLS"; }
trap 'printf "caller cleanup\n" >>"$FIXTURE_TRAP"' EXIT
before="$(trap -p EXIT)"
if [[ "${FIXTURE_CONDITIONAL:-0}" == 1 ]]; then
  status=0
  run_gate_negative_controls || status=$?
  [[ "$(trap -p EXIT)" == "$before" ]]
  exit "$status"
fi
run_principle_gates
[[ "$(trap -p EXIT)" == "$before" ]]
SH

export PATH="$fixture/bin:$PATH"
export FIXTURE_CALLS="$fixture/calls.log" FIXTURE_TRAP="$fixture/trap.log"
export TMPDIR="$fixture/logs"

run_fixture() {
  : >"$FIXTURE_CALLS"
  : >"$FIXTURE_TRAP"
  bash "$fixture/run.sh" "$SCRIPT_DIR/principle-gates-lib.sh" "$fixture"
}

run_fixture >"$fixture/success.log" 2>&1
marker_count="$(grep -c '^\[swift-test-inventory\] compiler: ' "$fixture/success.log" || true)"
[[ "$marker_count" == 1 ]] || { echo "Expected one real compiler marker, found $marker_count" >&2; exit 1; }
grep -Fx '[swift-test-inventory] compiler: Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)' "$fixture/success.log" >/dev/null
[[ "$(grep -c '^\[swift-test-inventory\] host-runtime: ' "$fixture/success.log")" == 1 ]]
if grep -E '\(selftest\)|FAKE-DEVICE-ID|999 tests|unexpected signal|Test Suite|stdout diagnostic|stderr diagnostic' "$fixture/success.log"; then
  echo 'Synthetic selftest evidence leaked into the parent output' >&2
  exit 1
fi
[[ "$(wc -l <"$FIXTURE_CALLS" | tr -d ' ')" == 4 ]]
[[ "$(cat "$FIXTURE_TRAP")" == 'caller cleanup' ]]
[[ -z "$(find "$fixture/logs" -type f -print)" ]]

for failure in principle-gates-selftest.sh:42 check-concurrency-safety-selftest.sh:13; do
  export FIXTURE_FAIL_SCRIPT="${failure%:*}" FIXTURE_FAIL_STATUS="${failure##*:}"
  status=0
  run_fixture >"$fixture/failure.log" 2>&1 || status=$?
  [[ "$status" == "$FIXTURE_FAIL_STATUS" ]]
  grep -F "$FIXTURE_FAIL_SCRIPT stdout diagnostic" "$fixture/failure.log" >/dev/null
  grep -F "$FIXTURE_FAIL_SCRIPT stderr diagnostic" "$fixture/failure.log" >/dev/null
  ! grep -F 'builds' "$FIXTURE_CALLS" >/dev/null
  expected_calls=1
  [[ "$FIXTURE_FAIL_SCRIPT" == principle-gates-selftest.sh ]] || expected_calls=2
  [[ "$(wc -l <"$FIXTURE_CALLS" | tr -d ' ')" == "$expected_calls" ]]
  [[ "$(cat "$FIXTURE_TRAP")" == 'caller cleanup' ]]
  [[ -z "$(find "$fixture/logs" -type f -print)" ]]
  # Conditional callers disable errexit; a first failure must still stop the
  # second selftest and must not be replaced by a later successful status.
  status=0
  FIXTURE_CONDITIONAL=1 run_fixture >"$fixture/conditional.log" 2>&1 || status=$?
  [[ "$status" == "$FIXTURE_FAIL_STATUS" ]]
  [[ "$(wc -l <"$FIXTURE_CALLS" | tr -d ' ')" == "$expected_calls" ]]
  [[ "$(cat "$FIXTURE_TRAP")" == 'caller cleanup' ]]
  [[ -z "$(find "$fixture/logs" -type f -print)" ]]
done

# Exercise the unchanged production identity checker against the actual
# emitted parent log, and retain strict missing/build/conflict rejection.
ruby - "$SCRIPT_DIR/release-evidence-tool.rb" "$fixture/success.log" "$fixture" <<'RUBY'
source, log, root = ARGV
eval(File.read(source).split(/^command_name = /, 2).first, TOPLEVEL_BINDING, source)
identity = "Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)"
check = {"id" => "logging-fixture", "runtimeInventory" => {
  "expectedTestIdentifiers" => ["FixtureTests/value()"],
  "conditionalContextsByIdentifier" => {"FixtureTests/value()" => ["#if compiler(>=6.4)"]},
}}
selected = compiler_check(check, identity, log)
abort "Wrong compiler selection" unless selected["expectedTestIdentifiers"] == ["FixtureTests/value()"]
output = File.read(log)
variants = {
  "missing" => [identity, output.lines.reject { |line| line.start_with?("[swift-test-inventory] compiler:") }.join],
  "recorded build mismatch" => [identity.sub("swiftlang-6.4.0.34.1", "different-build"), output],
  "conflicting build" => [identity, output + "[swift-test-inventory] compiler: Apple Swift version 6.4 (different-build)\n"],
}
variants.each do |name, (recorded, content)|
  path = File.join(root, "negative.log")
  File.write(path, content)
  child = fork do
    $stderr.reopen(File::NULL, "w")
    compiler_check(check, recorded, path)
  end
  _, status = Process.wait2(child)
  abort "Accepted #{name}" if status.success?
end
RUBY
echo '[principle-gates-logging-selftest] Compiler framing, fixture isolation, failure status and cleanup passed'
