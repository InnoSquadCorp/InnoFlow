#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
package="${INNOFLOW_CONSUMER_PACKAGE_PATH:-$root}"
scratch="$(mktemp -d)"
cleanup() {
  if [[ -n "${INNOFLOW_CONSUMER_ARTIFACT_DIR:-}" ]]; then
    mkdir -p "$INNOFLOW_CONSUMER_ARTIFACT_DIR"
    for file in "$scratch"/*.log "$scratch"/*.jsonl; do
      [[ ! -f "$file" ]] || cp "$file" "$INNOFLOW_CONSUMER_ARTIFACT_DIR/"
    done
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT
export INNOFLOW_CONSUMER_PACKAGE_PATH="$package"
args=(--package-path "$root/Tests/Fixtures/DispatchIdentityConsumer" --scratch-path "$scratch/build" --jobs "${INNOFLOW_CONSUMER_JOBS:-1}" -Xswiftc -warnings-as-errors)
cat >"$scratch/legacy.jsonl" <<'JSONL'
{"phase":"runStarted","sequence":1,"timestampNanos":10,"dispatchID":"00000000-0000-0000-0000-000000000001"}
{"phase":"runStarted","sequence":2,"timestampNanos":20,"dispatchID":"00000000-0000-0000-0000-000000000002"}
{"phase":"runFinished","sequence":1,"timestampNanos":30,"dispatchID":"00000000-0000-0000-0000-000000000001"}
JSONL
python3 "$root/scripts/migrate-effect-timing-jsonl.py" --input "$scratch/legacy.jsonl" --output "$scratch/migrated.jsonl"
swift run "${args[@]}" Consumer "$scratch/migrated.jsonl" >"$scratch/positive.log" 2>&1 || { cat "$scratch/positive.log" >&2; exit 1; }
cat "$scratch/positive.log"
grep -Fx 'Dispatch identity consumer passed' "$scratch/positive.log" >/dev/null
for control in RawValue UUIDRecord; do
  if INNOFLOW_IDENTITY_NEGATIVE="$control" swift build "${args[@]}" >"$scratch/$control.log" 2>&1; then
    echo "Unexpectedly accepted removed API: $control" >&2; exit 1
  fi
  case "$control" in
    RawValue) expected='argument passed to call that takes no arguments|extra argument.*rawValue' ;;
    UUIDRecord) expected='cannot convert value of type.*UUID.*UInt64' ;;
  esac
  if ! grep -Eq "$expected" "$scratch/$control.log"; then
    cat "$scratch/$control.log" >&2
    echo "Negative identity consumer failed for an unrelated reason: $control" >&2
    exit 1
  fi
  grep -E 'error:' "$scratch/$control.log"
  echo "Expected API rejection: $control"
done
