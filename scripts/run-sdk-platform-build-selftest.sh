#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT INT TERM
mkdir -p "$fixture_root/bin"

cat >"$fixture_root/bin/xcodebuild" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"$SDK_BUILD_COMMAND_LOG"
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-resultBundlePath" ]]; then
    mkdir -p "$2"
    exit 0
  fi
  shift
done
exit 64
SH
cat >"$fixture_root/bin/xcrun" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == *"xcresulttool get build-results"* ]]
printf '%s\n' '{"actionTitle":"Building workspace InnoFlow","status":"succeeded","startTime":100,"endTime":101,"destination":{"platform":"macOS","osVersion":"27.0","deviceId":"fixture","deviceName":"Mac"},"errorCount":0,"warningCount":0,"analyzerWarningCount":0,"errors":[],"warnings":[],"analyzerWarnings":[]}'
SH
chmod +x "$fixture_root/bin/xcodebuild" "$fixture_root/bin/xcrun"
export PATH="$fixture_root/bin:$PATH"
export SDK_BUILD_COMMAND_LOG="$fixture_root/command.log"

result="$fixture_root/build.xcresult"
"$script_dir/run-sdk-platform-build.sh" \
  --platform macOS --derived-data "$fixture_root/Derived" \
  --result-bundle "$result" >/dev/null
grep -Fx -- '-workspace' "$SDK_BUILD_COMMAND_LOG" >/dev/null
grep -Fx -- "$script_dir/../.swiftpm/xcode/package.xcworkspace" "$SDK_BUILD_COMMAND_LOG" >/dev/null ||
  grep -F -- '/.swiftpm/xcode/package.xcworkspace' "$SDK_BUILD_COMMAND_LOG" >/dev/null
grep -Fx -- 'generic/platform=macOS' "$SDK_BUILD_COMMAND_LOG" >/dev/null
grep -Fx -- 'build' "$SDK_BUILD_COMMAND_LOG" >/dev/null
if "$script_dir/run-sdk-platform-build.sh" \
  --platform macOS --derived-data "$fixture_root/Derived" \
  --result-bundle "$result" >/dev/null 2>&1; then
  echo "Preexisting SDK result bundle was accepted" >&2
  exit 1
fi
if "$script_dir/run-sdk-platform-build.sh" \
  --platform iOS --derived-data relative \
  --result-bundle "$fixture_root/other.xcresult" >/dev/null 2>&1; then
  echo "Relative SDK derived data was accepted" >&2
  exit 1
fi
if "$script_dir/run-sdk-platform-build.sh" \
  --platform invalid --derived-data "$fixture_root/Derived" \
  --result-bundle "$fixture_root/other.xcresult" >/dev/null 2>&1; then
  echo "Invalid SDK platform was accepted" >&2
  exit 1
fi
mkdir -p "$fixture_root/package/scripts" "$fixture_root/foreign"
cp "$script_dir/run-sdk-platform-build.sh" "$fixture_root/package/scripts/"
printf '%s\n' '// swift-tools-version: 6.0' >"$fixture_root/package/Package.swift"
ln -s "$fixture_root/foreign" "$fixture_root/package/.swiftpm"
rm -f "$SDK_BUILD_COMMAND_LOG"
if "$fixture_root/package/scripts/run-sdk-platform-build.sh" \
  --platform macOS --derived-data "$fixture_root/Derived" \
  --result-bundle "$fixture_root/other.xcresult" >/dev/null 2>&1; then
  echo "Symlinked SDK workspace path was accepted" >&2
  exit 1
fi
[[ ! -e "$SDK_BUILD_COMMAND_LOG" ]] || {
  echo "SDK build ran after workspace redirection" >&2
  exit 1
}
echo "[run-sdk-platform-build-selftest] All checks passed"
