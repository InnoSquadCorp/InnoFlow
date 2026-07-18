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
# Newline-separated "name sha location" records, used to reject the same
# action pinned to different SHAs in different workflows (drift reads as
# "updated everywhere" during review when it was not). A flat string keeps
# the script compatible with the bash 3.2 shipped on macOS — `declare -A`
# is unavailable there.
seen_pins=""

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

    display_path="${workflow#"$ROOT_DIR"/}"
    name="${action%@*}"
    ref="${action##*@}"
    if [[ "$action" == "$ref" || ! "$ref" =~ ^[0-9a-f]{40}$ ]]; then
      echo "[workflow-action-pins] $display_path:$line_number must pin '$action' to a full 40-character commit SHA" >&2
      status=1
      continue
    fi

    # A SHA alone is unreviewable; require the human-readable release tag
    # alongside it (e.g. `@<sha> # v6.0.3`).
    if [[ ! "$body" =~ @${ref}[[:space:]]+#[[:space:]]*v[0-9] ]]; then
      echo "[workflow-action-pins] $display_path:$line_number must annotate '$name' with its release tag (append '# vX.Y.Z' after the SHA)" >&2
      status=1
    fi

    previous_record="$(printf '%s\n' "$seen_pins" | grep -m1 "^$name " || true)"
    if [[ -n "$previous_record" ]]; then
      previous_sha="$(printf '%s' "$previous_record" | cut -d' ' -f2)"
      previous_where="$(printf '%s' "$previous_record" | cut -d' ' -f3)"
      if [[ "$previous_sha" != "$ref" ]]; then
        echo "[workflow-action-pins] $display_path:$line_number pins '$name' to $ref but $previous_where pins it to $previous_sha — keep one SHA per action across workflows" >&2
        status=1
      fi
    else
      seen_pins="${seen_pins}${name} ${ref} ${display_path}:${line_number}
"
    fi
  done < <(grep -nE '^[[:space:]]*(-[[:space:]]*)?uses:[[:space:]]*' "$workflow" || true)
done < <(find "$WORKFLOW_DIR" -type f \( -name '*.yml' -o -name '*.yaml' \) -print | sort)

if [[ "$status" -ne 0 ]]; then
  exit "$status"
fi

echo "[workflow-action-pins] All external actions use consistent, tag-annotated commit SHA pins"
