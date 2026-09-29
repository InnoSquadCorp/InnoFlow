#!/usr/bin/env bash
set -euo pipefail

usage() { echo "Usage: $0 --run-id <id> --artifact-name <name> --output <json>"; }
run_id=""; artifact_name=""; output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) run_id="${2:-}"; shift 2 ;;
    --artifact-name) artifact_name="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    *) usage; exit 64 ;;
  esac
done
if [[ -z "$run_id" || -z "$artifact_name" || -z "$output" || -z "${GITHUB_REPOSITORY:-}" || -z "${GITHUB_SHA:-}" || -z "${GITHUB_REF:-}" ]]; then
  usage
  exit 64
fi
case "$run_id" in *[!0-9]*|"") echo "Run ID must be numeric" >&2; exit 64 ;; esac

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
gh api "repos/$GITHUB_REPOSITORY/actions/runs/$run_id" >"$temporary_root/run.json"
gh api "repos/$GITHUB_REPOSITORY/actions/runs/$run_id/artifacts?per_page=100" >"$temporary_root/artifacts.json"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$script_dir/write-github-evidence-provenance.rb" \
  "$temporary_root/run.json" "$temporary_root/artifacts.json" "$artifact_name" \
  "$GITHUB_REPOSITORY" "$GITHUB_SHA" "$GITHUB_REF" "$output"
