#!/usr/bin/env bash
set -euo pipefail

# Read-only last-mile check. Server-side immutable-tag rules must still close
# the race between this observation and the GitHub Release API request.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/release-tag-policy.sh"

if [[ "$#" != 2 ]]; then
  echo "Usage: verify-release-publication.sh <tag> <exact-commit-sha>" >&2
  exit 1
fi
tag="$1"
expected_sha="$2"
if ! is_strict_release_tag "$tag" || [[ ! "$expected_sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Publication requires strict release SemVer and an exact commit SHA." >&2
  exit 1
fi
[[ "$(git rev-parse HEAD)" == "$expected_sha" ]] || {
  echo "Publication checkout differs from the validated candidate SHA." >&2
  exit 1
}
INNOFLOW_TRIGGER_TAG="$tag" require_release_tag_at_head "$tag"

remote_tags="$(git ls-remote --exit-code --tags origin "refs/tags/$tag" "refs/tags/$tag^{}")"
remote_sha="$(printf '%s\n' "$remote_tags" | awk -v ref="refs/tags/$tag" '
  $2 == ref { direct = $1; direct_count++ }
  $2 == ref "^{}" { peeled = $1; peeled_count++ }
  END {
    if (direct_count != 1 || peeled_count > 1) exit 1
    print peeled_count == 1 ? peeled : direct
  }
')"
if [[ "$remote_sha" != "$expected_sha" ]]; then
  echo "Remote release tag no longer targets the validated candidate SHA." >&2
  exit 1
fi
echo "[verify-release-publication] Exact remote tag and checkout match $expected_sha"
