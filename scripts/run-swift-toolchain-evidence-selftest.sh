#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT
fake_swift="$fixture_root/swift"
cat >"$fake_swift" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "Swift version ${FAKE_SWIFT_VERSION:-6.4.2} (swift-6.4.2-RELEASE)"
  exit 0
fi
printf 'executed:%s\n' "$*"
SH
chmod +x "$fake_swift"

output="$(FAKE_SWIFT_VERSION=6.4.2 "$script_dir/run-swift-toolchain-evidence.sh" \
  --expected-prefix 6.4 -- "$fake_swift" test --jobs 1)"
grep -Fq 'Swift version 6.4.2' <<<"$output"
grep -Fq 'executed:test --jobs 1' <<<"$output"
if FAKE_SWIFT_VERSION=6.4.2 "$script_dir/run-swift-toolchain-evidence.sh" \
  --expected-prefix 6.3 -- "$fake_swift" test >/dev/null 2>&1; then
  echo "Mismatched Swift toolchain must fail" >&2
  exit 1
fi
echo "[run-swift-toolchain-evidence-selftest] All checks passed"
