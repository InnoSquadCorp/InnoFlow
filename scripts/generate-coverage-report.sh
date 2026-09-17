#!/usr/bin/env bash
set -euo pipefail

# Adapted from InnoRouter's multi-binary LLVM coverage export (MIT, InnoSquad).
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_PATH="${1:-$ROOT_DIR/.build/coverage/coverage.lcov}"
cd "$ROOT_DIR"

bin_path="$(swift build --show-bin-path)"
prof_data="$bin_path/codecov/default.profdata"
[[ -s "$prof_data" ]] || { echo "[coverage] Missing profile: $prof_data" >&2; exit 1; }

test_bins=()
while IFS= read -r bundle; do
  executable="$bundle/Contents/MacOS/$(basename "$bundle" .xctest)"
  [[ -x "$executable" ]] || { echo "[coverage] Missing test executable: $executable" >&2; exit 1; }
  [[ ! "$executable" -nt "$prof_data" ]] || {
    echo "[coverage] Test executable is newer than the profile; rerun the instrumented tests" >&2
    exit 1
  }
  test_bins+=("$executable")
done < <(find "$bin_path" -maxdepth 1 -type d -name '*.xctest' | sort)
[[ ${#test_bins[@]} -gt 0 ]] || { echo '[coverage] No test executables found' >&2; exit 1; }

cov_args=("${test_bins[0]}")
for ((index = 1; index < ${#test_bins[@]}; index++)); do
  cov_args+=(-object "${test_bins[$index]}")
done

# Explicit source paths include every library module, including SwiftUI and
# macros, without counting dependencies, tests, generated runners or fixtures.
sources=()
while IFS= read -r source; do
  sources+=("$source")
done < <(find "$ROOT_DIR/Sources" -type f -name '*.swift' | sort)
[[ ${#sources[@]} -gt 0 ]] || { echo '[coverage] No library source files found' >&2; exit 1; }

mkdir -p "$(dirname "$OUTPUT_PATH")"
temporary="$(mktemp "${OUTPUT_PATH}.XXXXXX")"
trap 'rm -f "$temporary"' EXIT
xcrun llvm-cov export "${cov_args[@]}" -instr-profile "$prof_data" -format=lcov \
  "${sources[@]}" > "$temporary"
[[ -s "$temporary" ]] || { echo '[coverage] LLVM emitted an empty report' >&2; exit 1; }
mv "$temporary" "$OUTPUT_PATH"
echo "[coverage] Exported ${#test_bins[@]} test executables to $OUTPUT_PATH"
