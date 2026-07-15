#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKFLOW_DIR="${1:-$ROOT_DIR/.github/workflows}"

if [[ ! -d "$WORKFLOW_DIR" ]]; then
  echo "[workflow-action-pins] Missing workflow directory: $WORKFLOW_DIR" >&2
  exit 2
fi

status=0
while IFS= read -r workflow; do
  while IFS= read -r match; do
    line_number="${match%%:*}"
    body="${match#*:}"
    if [[ ! "$body" =~ uses:[[:space:]]*([^[:space:]#]+) ]]; then
      continue
    fi

    action="${BASH_REMATCH[1]}"
    if [[ "$action" == ./* || "$action" == docker://* ]]; then
      continue
    fi

    ref="${action##*@}"
    if [[ "$action" == "$ref" || ! "$ref" =~ ^[0-9a-f]{40}$ ]]; then
      display_path="${workflow#"$ROOT_DIR"/}"
      echo "[workflow-action-pins] $display_path:$line_number must pin '$action' to a full 40-character commit SHA" >&2
      status=1
    fi
  done < <(grep -nE '^[[:space:]]*(-[[:space:]]*)?uses:[[:space:]]*' "$workflow" || true)
done < <(find "$WORKFLOW_DIR" -type f \( -name '*.yml' -o -name '*.yaml' \) -print | sort)

if [[ "$status" -ne 0 ]]; then
  exit "$status"
fi

echo "[workflow-action-pins] All external actions use full commit SHA pins"
