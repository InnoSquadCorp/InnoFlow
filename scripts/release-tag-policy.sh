#!/usr/bin/env bash

# Shared strict release-tag validation. Keep this file side-effect free so
# release tooling and self-tests can source it safely.

is_strict_release_tag() {
  local tag="${1:-}"
  [[ "$tag" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

require_release_tag_at_head() {
  local expected_version="$1"
  local trigger_tag="${INNOFLOW_TRIGGER_TAG:-}"

  if [[ "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
    trigger_tag="${GITHUB_REF_NAME:-}"
  elif [[ -z "$trigger_tag" ]]; then
    trigger_tag="$expected_version"
  fi

  if ! is_strict_release_tag "$trigger_tag"; then
    echo "[release-tag-policy] Failed: release tag '$trigger_tag' must be strict numeric SemVer without a v prefix, prerelease, metadata, or leading zero" >&2
    return 1
  fi

  if [[ "$trigger_tag" != "$expected_version" ]]; then
    echo "[release-tag-policy] Failed: triggering tag $trigger_tag does not match staged release $expected_version" >&2
    return 1
  fi

  if ! git show-ref --verify --quiet "refs/tags/$trigger_tag"; then
    echo "[release-tag-policy] Failed: exact tag refs/tags/$trigger_tag does not exist locally" >&2
    return 1
  fi

  local tag_commit
  local head_commit
  tag_commit="$(git rev-parse "refs/tags/$trigger_tag^{commit}")"
  head_commit="$(git rev-parse "HEAD^{commit}")"
  if [[ "$tag_commit" != "$head_commit" ]]; then
    echo "[release-tag-policy] Failed: tag $trigger_tag points to $tag_commit but the release checkout is $head_commit" >&2
    return 1
  fi
}
