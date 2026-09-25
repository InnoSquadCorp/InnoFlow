#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
snapshot="$root_dir/scripts/release-candidate-snapshot.rb"
policy="$root_dir/docs/contracts/release-evidence-policy.json"
included_root=""

if [[ $# -gt 0 ]]; then
  if [[ "$1" != "--include-git-root" || $# -ne 2 ]]; then
    echo "Usage: $0 [--include-git-root <consumer-repository>]" >&2
    exit 64
  fi
  included_root="$(cd "$2" && pwd)"
fi

arguments=(--repository "primary=$root_dir" --policy "$policy" --digest-only)
if [[ -n "$included_root" ]]; then
  arguments+=(--repository "consumer=$included_root")
fi
exec "$snapshot" "${arguments[@]}"
