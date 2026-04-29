#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

cd "$ROOT_DIR"

latest_release_version() {
  if [[ -n "${INNOFLOW_RELEASE_VERSION:-}" ]]; then
    printf '%s\n' "${INNOFLOW_RELEASE_VERSION#v}"
    return
  fi

  if git rev-parse --git-dir >/dev/null 2>&1; then
    local latest_tag
    latest_tag="$(
      git tag --list --sort=-v:refname \
        | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' \
        | head -n 1 \
        || true
    )"
    if [[ -n "$latest_tag" ]]; then
      printf '%s\n' "${latest_tag#v}"
      return
    fi
  fi

  awk '
    /^## [0-9]+\.[0-9]+\.[0-9]+ Release$/ {
      sub(/^## /, "")
      sub(/ Release$/, "")
      print
      exit
    }
  ' RELEASE_NOTES.md
}

require_pattern() {
  local file="$1"
  local pattern="$2"
  local label="$3"

  if [[ ! -f "$file" ]]; then
    echo "[check-release-sync] Failed: $file not found" >&2
    exit 1
  fi

  if ! grep -E -q -- "$pattern" "$file"; then
    echo "[check-release-sync] Failed: $file must contain $label" >&2
    exit 1
  fi
}

version="$(latest_release_version)"

if [[ -z "$version" ]]; then
  echo "[check-release-sync] Failed: could not determine latest release version" >&2
  exit 1
fi

escaped_version="${version//./\\.}"

require_pattern \
  README.md \
  "from: \"${escaped_version}\"" \
  "SwiftPM install version ${version}"

require_pattern \
  RELEASE_NOTES.md \
  "^## ${escaped_version} Release$" \
  "release notes section for ${version}"

require_pattern \
  CHANGELOG.md \
  "^## \\[${escaped_version}\\] - " \
  "changelog section for ${version}"

echo "[check-release-sync] OK: release surface matches ${version}"
