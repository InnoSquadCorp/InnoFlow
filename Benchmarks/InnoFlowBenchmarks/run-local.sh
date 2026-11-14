#!/usr/bin/env bash
# Local relative measurements only. Prints the median nanoseconds per
# iteration of each scenario so a change can be compared before and after on
# the same machine. Never release, adoption or regression evidence: use
# Benchmarks/trend.py and the benchmark-trend workflow for recorded cohorts.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
samples="${SAMPLES:-7}"
scratch="${BENCH_SCRATCH:-$script_dir/.build}"
default_scenarios=(
  "S1 100000" "S2 20000" "S3 2000" "S4 30000" "S5 100000" "S6 2000"
  "S7 2000" "S8 200" "R1 5000" "R2 5000"
)

if (( $# > 0 )); then
  scenarios=("$@")
else
  scenarios=("${default_scenarios[@]}")
fi

swift build -c release --package-path "$script_dir" --scratch-path "$scratch" >&2
binary="$(swift build -c release --package-path "$script_dir" --scratch-path "$scratch" --show-bin-path)/InnoFlowBenchmarks"

# The executable links InnoFlowTesting, which needs the test support
# libraries of the selected toolchain and platform at launch.
toolchain_bin="$(dirname "$(xcrun --find swift)")"
platform_developer="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer"
export DYLD_LIBRARY_PATH="$toolchain_bin/../lib/swift/macosx/testing:$platform_developer/usr/lib"
export DYLD_FRAMEWORK_PATH="$platform_developer/Library/Frameworks:$platform_developer/Library/PrivateFrameworks"

printf '%-6s %10s %14s\n' scenario iterations ns/iteration
for entry in "${scenarios[@]}"; do
  read -r scenario iterations <<<"$entry"
  "$binary" "$scenario" "$iterations" >/dev/null  # warm-up
  values=()
  for (( sample = 0; sample < samples; sample++ )); do
    line="$("$binary" "$scenario" "$iterations")"
    values+=("$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["ns"]/d["iterations"])' "$line")")
  done
  median="$(printf '%s\n' "${values[@]}" | sort -g | sed -n "$(( (samples + 1) / 2 ))p")"
  printf '%-6s %10s %14.0f\n' "$scenario" "$iterations" "$median"
done
