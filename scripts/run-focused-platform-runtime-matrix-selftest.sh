#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/scripts"
cp "$SCRIPT_DIR/run-focused-platform-runtime-matrix.sh" "$TMP_ROOT/scripts/"

cat >"$TMP_ROOT/bin/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-} ${3:-}" in
  "simctl list runtimes")
    printf '%s\n' '{"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-18-5","isAvailable":true,"version":"18.5"}]}'
    ;;
  "simctl create "*)
    printf '%s\n' 'FAKE-DEVICE-ID'
    ;;
  "simctl boot "*|"simctl bootstatus "*|"simctl shutdown "*|"simctl delete "*)
    ;;
  *)
    printf 'unexpected xcrun arguments: %s\n' "$*" >&2
    exit 64
    ;;
esac
EOF
chmod +x "$TMP_ROOT/bin/xcrun"

cat >"$TMP_ROOT/scripts/run-focused-platform-runtime-tests.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"$FOCUSED_RUNTIME_ARGUMENT_LOG"
EOF
chmod +x "$TMP_ROOT/scripts/run-focused-platform-runtime-tests.sh"

export PATH="$TMP_ROOT/bin:$PATH"
export FOCUSED_RUNTIME_ARGUMENT_LOG="$TMP_ROOT/arguments.log"

"$TMP_ROOT/scripts/run-focused-platform-runtime-matrix.sh" \
  --platform iOS \
  --runtime com.apple.CoreSimulator.SimRuntime.iOS-18-5

printf '%s\n' \
  --destination \
  "platform=iOS Simulator,id=FAKE-DEVICE-ID" \
  >"$TMP_ROOT/expected.log"
diff -u "$TMP_ROOT/expected.log" "$FOCUSED_RUNTIME_ARGUMENT_LOG"

"$TMP_ROOT/scripts/run-focused-platform-runtime-matrix.sh" \
  --platform iOS \
  --runtime com.apple.CoreSimulator.SimRuntime.iOS-18-5 \
  --derived-data relative-derived-data

printf '%s\n' \
  --destination \
  "platform=iOS Simulator,id=FAKE-DEVICE-ID" \
  --derived-data \
  relative-derived-data \
  >"$TMP_ROOT/expected.log"
diff -u "$TMP_ROOT/expected.log" "$FOCUSED_RUNTIME_ARGUMENT_LOG"

echo "[run-focused-platform-runtime-matrix-selftest] All checks passed"
