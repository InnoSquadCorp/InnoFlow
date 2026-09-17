#!/usr/bin/env bash
set -euo pipefail

usage() { echo "Usage: $0 --candidate-snapshot <json> --label <name> --repository <path> [--policy <json>]"; }
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
policy="$script_dir/../docs/contracts/release-evidence-policy.json"
snapshot=""; label=""; repository=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --candidate-snapshot) snapshot="${2:-}"; shift 2 ;;
    --label) label="${2:-}"; shift 2 ;;
    --repository) repository="${2:-}"; shift 2 ;;
    --policy) policy="${2:-}"; shift 2 ;;
    *) usage; exit 64 ;;
  esac
done
if [[ -z "$snapshot" || -z "$label" || -z "$repository" ]]; then usage; exit 64; fi

temporary="$(mktemp)"
trap 'rm -f "$temporary"' EXIT
"$script_dir/release-candidate-snapshot.rb" --repository "$label=$repository" --policy "$policy" >"$temporary"
ruby -rjson -e '
  expected = JSON.parse(File.read(ARGV.fetch(0)))
  actual = JSON.parse(File.read(ARGV.fetch(1))).fetch("components").fetch(0)
  component = expected.fetch("components").find { |item| item.fetch("label") == ARGV.fetch(2) }
  abort "Candidate component is missing: #{ARGV.fetch(2)}" unless component
  abort "Published candidate component may not be dirty" if component.fetch("dirty")
  %w[headRevision contentDigest files].each do |key|
    abort "Candidate component mismatch: #{key}" unless component.fetch(key) == actual.fetch(key)
  end
' "$snapshot" "$temporary" "$label"
echo "[verify-candidate-component] OK label=$label"
