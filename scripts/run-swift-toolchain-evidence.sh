#!/usr/bin/env bash
set -euo pipefail

usage() { echo "Usage: $0 --expected-prefix <major.minor> -- <swift command> [args...]"; }
expected=""
if [[ "${1:-}" == "--expected-prefix" ]]; then
  expected="${2:-}"
  shift 2
fi
if [[ "${1:-}" != "--" || -z "$expected" ]]; then usage; exit 64; fi
shift
if [[ $# -eq 0 || "$(basename "$1")" != "swift" ]]; then usage; exit 64; fi
case "$expected" in *[!0-9.]*|*.*.*|.*|*.) usage; exit 64 ;; esac
version_output="$("$1" --version)"
version="$(printf '%s\n' "$version_output" | awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "version") { print $(i + 1); exit } }')"
case "$version" in "$expected"|"$expected".*) ;; *) echo "Swift toolchain mismatch: expected $expected.x, found ${version:-unknown}" >&2; exit 1 ;; esac
printf '%s\n' "$version_output"
exec "$@"
