#!/usr/bin/env bash
set -euo pipefail

context="${INNOFLOW_TRUSTED_PRODUCER_CONTEXT:-}"
if [[ -z "$context" || ! -f "$context" || -L "$context" ]]; then
  echo "INNOFLOW_TRUSTED_PRODUCER_CONTEXT must name a regular provenance JSON file" >&2
  exit 64
fi
if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI is required to verify the evidence producer" >&2
  exit 69
fi

repository="$(jq -er '.repository' "$context")"
head_sha="$(jq -er '.headSha' "$context")"
run_id="$(jq -er '.runId' "$context")"
artifact_name="$(jq -er '.artifactName' "$context")"
producer_ref="$(jq -er '.ref' "$context")"
case "$repository" in
  */*) ;;
  *) echo "Trusted producer repository is invalid" >&2; exit 65 ;;
esac
[[ "$head_sha" =~ ^[0-9a-f]{40}$ ]] || { echo "Trusted producer head SHA is invalid" >&2; exit 65; }
[[ "$run_id" =~ ^[1-9][0-9]*$ ]] || { echo "Trusted producer run ID is invalid" >&2; exit 65; }
[[ -n "$artifact_name" ]] || { echo "Trusted producer artifact name is missing" >&2; exit 65; }

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
gh api "repos/$repository/actions/runs/$run_id" >"$temporary_root/run.json"
gh api "repos/$repository/actions/runs/$run_id/artifacts?per_page=100" >"$temporary_root/artifacts.json"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$script_dir/write-github-evidence-provenance.rb" \
  "$temporary_root/run.json" \
  "$temporary_root/artifacts.json" \
  "$artifact_name" \
  "$repository" \
  "$head_sha" \
  "$producer_ref" \
  "$temporary_root/live-context.json" >/dev/null

if ! cmp -s "$context" "$temporary_root/live-context.json"; then
  echo "Trusted producer provenance no longer matches the live GitHub run and artifact" >&2
  exit 1
fi

echo "[verify-github-evidence-run] OK repository=$repository run=$run_id artifact=$artifact_name"
