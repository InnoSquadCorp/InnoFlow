#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
package="${INNOFLOW_CONSUMER_PACKAGE_PATH:-$root}"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
export INNOFLOW_CONSUMER_PACKAGE_PATH="$package"
args=(--package-path "$root/Tests/Fixtures/TestFlowTaskConsumer" --scratch-path "$scratch/build" --jobs "${INNOFLOW_CONSUMER_JOBS:-1}" -Xswiftc -warnings-as-errors)
INNOFLOW_TESTFLOWTASK_NEGATIVE=0 INNOFLOW_FLOWSCOPE_NEGATIVE=0 \
  swift run "${args[@]}" Consumer >"$scratch/positive.log" 2>&1 || {
  cat "$scratch/positive.log" >&2
  exit 1
}
cat "$scratch/positive.log"
echo 'Test dispatch public consumer passed'
for control in legacy-void direct-scope; do
  legacy=0
  scope=0
  [[ "$control" != legacy-void ]] || legacy=1
  [[ "$control" != direct-scope ]] || scope=1
  if INNOFLOW_TESTFLOWTASK_NEGATIVE="$legacy" INNOFLOW_FLOWSCOPE_NEGATIVE="$scope" \
    swift build "${args[@]}" >"$scratch/$control.log" 2>&1; then
    echo "Unexpectedly accepted removed API: $control" >&2
    exit 1
  fi
  case "$control" in
    legacy-void) expected='cannot convert value of type.*TestStoreDispatch.*to specified type.*Void' ;;
    direct-scope) expected="'FlowScope' initializer is inaccessible" ;;
  esac
  if ! grep -Eq "$expected" "$scratch/$control.log"; then
    cat "$scratch/$control.log" >&2
    echo "Negative test dispatch consumer failed for an unrelated reason: $control" >&2
    exit 1
  fi
  echo "Expected public API rejection: $control"
done
