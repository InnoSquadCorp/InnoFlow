#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 --candidate-hash <sha256> --candidate-snapshot <json> --evidence-root <dir> --manifest <tsv> [--attempt-index <relative-tsv>] [--trusted-producer-context <json>] [--policy <json>] [--stage local-preflight|pre-publication|post-publication]"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
policy="$script_dir/../docs/contracts/release-evidence-policy.json"
candidate_hash=""; candidate_snapshot=""; evidence_root=""; manifest=""; stage="local-preflight"; trusted_context=""; attempt_index="attempts.tsv"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --candidate-hash) candidate_hash="${2:-}"; shift 2 ;;
    --candidate-snapshot) candidate_snapshot="${2:-}"; shift 2 ;;
    --evidence-root) evidence_root="${2:-}"; shift 2 ;;
    --manifest) manifest="${2:-}"; shift 2 ;;
    --attempt-index) attempt_index="${2:-}"; shift 2 ;;
    --policy) policy="${2:-}"; shift 2 ;;
    --stage) stage="${2:-}"; shift 2 ;;
    --trusted-producer-context) trusted_context="${2:-}"; shift 2 ;;
    *) usage; exit 64 ;;
  esac
done
if [[ -z "$candidate_hash" || -z "$candidate_snapshot" || -z "$evidence_root" || -z "$manifest" ]]; then
  usage
  exit 64
fi

arguments=(verify --policy "$policy" --stage "$stage" \
  --candidate "$candidate_hash" --candidate-snapshot "$candidate_snapshot" \
  --evidence-root "$evidence_root" --manifest "$manifest" --attempt-index "$attempt_index")
if [[ -n "$trusted_context" ]]; then
  arguments+=(--trusted-producer-context "$trusted_context")
fi
"$script_dir/release-evidence-tool.rb" "${arguments[@]}"
