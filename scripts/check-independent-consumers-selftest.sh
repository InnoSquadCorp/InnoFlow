#!/usr/bin/env bash
# Shell-only controls: the real external builds remain separate CI evidence.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/scripts" "$root/Tools/innoflow-migrate/scripts"
cp "$SCRIPT_DIR/check-independent-consumers.sh" "$SCRIPT_DIR/principle-gates-lib.sh" "$root/scripts/"
cat >"$root/scripts/check-level-one-consumer.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$INNOFLOW_PACKAGE_PATH" == "$ROOT_DIR" && "$SWIFT_JOBS" == 1 ]]
echo level-one >>"$ROOT_DIR/order"
echo level-one-output
[[ "${CONSUMER_FAILURE:-}" != level-one ]]
STUB
for entry in test-dispatch dispatch-identity effect-execution collection-lifetime; do
  cat >"$root/scripts/check-$entry-consumer.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$INNOFLOW_CONSUMER_PACKAGE_PATH" == "$ROOT_DIR" && "$INNOFLOW_CONSUMER_JOBS" == 1 ]]
entry="$(basename "$0" | sed 's/^check-//; s/-consumer.sh$//')"
echo "$entry" >>"$ROOT_DIR/order"
echo "$entry-output"
[[ "${CONSUMER_FAILURE:-}" != "$entry" ]]
STUB
  chmod +x "$root/scripts/check-$entry-consumer.sh"
done
cat >"$root/scripts/check-swiftui-consumer.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$INNOFLOW_PACKAGE_PATH" == "$ROOT_DIR" && "$SWIFT_JOBS" == 1 ]]
echo swiftui >>"$ROOT_DIR/order"
echo swiftui-output
[[ "${CONSUMER_FAILURE:-}" != swiftui ]]
STUB
cat >"$root/Tools/innoflow-migrate/scripts/check.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$INNOFLOW_MIGRATION_PACKAGE_PATH" == "$ROOT_DIR" ]]
echo codemod >>"$ROOT_DIR/order"
echo codemod-output
[[ "${CONSUMER_FAILURE:-}" != codemod ]]
STUB
chmod +x "$root/scripts/check-level-one-consumer.sh" "$root/scripts/check-swiftui-consumer.sh" "$root/Tools/innoflow-migrate/scripts/check.sh"
export ROOT_DIR="$root" PRINCIPLE_GATES_NICE=0 PRINCIPLE_GATES_SWIFTPM_JOBS=1
"$root/scripts/check-independent-consumers.sh" >"$root/pass.log" 2>&1
[[ "$(cat "$root/order")" == $'level-one\ntest-dispatch\ndispatch-identity\neffect-execution\ncollection-lifetime\nswiftui\ncodemod' ]]
# The successful nested Swift Testing log must stay outside root-suite counts.
! grep -E 'level-one-output|test-dispatch-output|dispatch-identity-output|effect-execution-output|collection-lifetime-output|swiftui-output|codemod-output' "$root/pass.log" >/dev/null
for failure in level-one test-dispatch dispatch-identity effect-execution collection-lifetime swiftui codemod; do
  : >"$root/order"
  if CONSUMER_FAILURE="$failure" "$root/scripts/check-independent-consumers.sh" >"$root/fail.log" 2>&1; then
    echo "[independent-consumers-selftest] Masked $failure failure" >&2
    exit 1
  fi
  grep -Fx "$failure-output" "$root/fail.log" >/dev/null
  if [[ "$failure" == level-one ]]; then
    [[ "$(cat "$root/order")" == level-one ]]
  fi
done
# Verify the complete principle entry point retains the consumer stage, while
# stubbing every expensive command. No compiler or runtime test is launched.
bash -c '
  set -euo pipefail
  SCRIPT_DIR="$1"
  source "$SCRIPT_DIR/principle-gates-lib.sh"
  run_low_priority() { :; }
  run_independent_consumer_checks() { echo integrated >>"$ROOT_DIR/order"; }
  run_release_configuration_checks() { :; }
  run_release_build_checks >/dev/null
' bash "$root/scripts"
grep -Fx integrated "$root/order" >/dev/null
echo '[independent-consumers-selftest] Dispatch, environment, failure and integration controls passed'
