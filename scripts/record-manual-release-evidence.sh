#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 --check-id <id> --candidate-hash <sha256> --candidate-snapshot <json> --evidence-root <dir> --manifest <relative-tsv-path> --artifact <relative-path> --receipt <relative-json-path> --reviewer <name-or-id> --observed-at <UTC ISO-8601> --environment-json <json> [--attempt-id <id>] [--attempt-index <relative-tsv-path>] [--producer-json <json>] [--policy <json>]"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
policy="$script_dir/../docs/contracts/release-evidence-policy.json"
check_id=""; candidate_hash=""; candidate_snapshot=""; evidence_root=""
artifact_relative=""; receipt_relative=""; reviewer=""; observed_at=""; environment_json=""; producer_json=""; manifest_relative=""
attempt_id=""; attempt_index_relative="attempts.tsv"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-id) check_id="${2:-}"; shift 2 ;;
    --candidate-hash) candidate_hash="${2:-}"; shift 2 ;;
    --candidate-snapshot) candidate_snapshot="${2:-}"; shift 2 ;;
    --evidence-root) evidence_root="${2:-}"; shift 2 ;;
    --manifest) manifest_relative="${2:-}"; shift 2 ;;
    --artifact) artifact_relative="${2:-}"; shift 2 ;;
    --receipt) receipt_relative="${2:-}"; shift 2 ;;
    --reviewer) reviewer="${2:-}"; shift 2 ;;
    --observed-at) observed_at="${2:-}"; shift 2 ;;
    --environment-json) environment_json="${2:-}"; shift 2 ;;
    --attempt-id) attempt_id="${2:-}"; shift 2 ;;
    --attempt-index) attempt_index_relative="${2:-}"; shift 2 ;;
    --producer-json) producer_json="${2:-}"; shift 2 ;;
    --policy) policy="${2:-}"; shift 2 ;;
    *) usage; exit 64 ;;
  esac
done
if [[ -z "$check_id" || -z "$candidate_hash" || -z "$candidate_snapshot" || -z "$evidence_root" || -z "$manifest_relative" || -z "$artifact_relative" || -z "$receipt_relative" || -z "$reviewer" || -z "$observed_at" || -z "$environment_json" ]]; then
  usage
  exit 64
fi

attempt_id="${attempt_id:-${check_id}-manual-$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM}}"
case "$attempt_id" in *[!A-Za-z0-9._-]*|"") echo "Attempt ID is invalid" >&2; exit 64 ;; esac
working_directory="$(pwd -P)"

arguments=(record-manual --policy "$policy" --check-id "$check_id" \
  --candidate "$candidate_hash" --candidate-snapshot "$candidate_snapshot" \
  --evidence-root "$evidence_root" --artifact "$artifact_relative" --receipt "$receipt_relative" \
  --reviewer "$reviewer" --observed-at "$observed_at" --environment-json "$environment_json" \
  --attempt-id "$attempt_id")
if [[ -n "$producer_json" ]]; then
  arguments+=(--producer-json "$producer_json")
fi
"$script_dir/release-evidence-tool.rb" "${arguments[@]}" >/dev/null
manifest_row="$("$script_dir/release-evidence-tool.rb" upsert-manifest --policy "$policy" \
  --check-id "$check_id" --candidate "$candidate_hash" \
  --candidate-snapshot "$candidate_snapshot" --evidence-root "$evidence_root" \
  --manifest "$manifest_relative" --receipt "$receipt_relative")"
"$script_dir/release-evidence-tool.rb" record-attempt --policy "$policy" --check-id "$check_id" \
  --candidate "$candidate_hash" --attempt-id "$attempt_id" --status PASS \
  --evidence-root "$evidence_root" --attempt-index "$attempt_index_relative" \
  --component-label manual --working-directory "$working_directory" \
  --started-at "$observed_at" --finished-at "$observed_at" --exit-code 0 \
  --detail-json '{"kind":"manual-attestation"}' --artifact "$artifact_relative" \
  --receipt "$receipt_relative" -- >/dev/null
printf '%s\n' "$manifest_row"
