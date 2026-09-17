#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <tag>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
source "$SCRIPT_DIR/release-tag-policy.sh"

tag="$1"
if ! is_strict_release_tag "$tag"; then
  echo "invalid release tag '$tag': expected strict numeric SemVer without a v prefix, prerelease, metadata, or leading zero" >&2
  exit 1
fi
changelog="CHANGELOG.md"

if [[ ! -f "$changelog" ]]; then
  echo "missing $changelog" >&2
  exit 1
fi

awk_status=0
notes="$(
  awk -v tag="$tag" '
    $0 == "## " tag || $0 ~ ("^## \\[" tag "\\]") { found = 1; next }
    found && /^## / { exit }
    found { print }
    END {
      if (!found) {
        exit 2
      }
    }
  ' "$changelog"
)" || awk_status=$?

if [[ $awk_status -eq 2 ]]; then
  echo "no release notes found for tag $tag in $changelog" >&2
  exit 1
elif [[ $awk_status -ne 0 ]]; then
  exit "$awk_status"
fi

if [[ ! "$notes" =~ [^[:space:]] ]]; then
  echo "no release notes found for tag $tag in $changelog" >&2
  exit 1
fi

printf '%s\n' "$notes"
