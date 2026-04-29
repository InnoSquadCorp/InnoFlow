#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

cd "$ROOT_DIR"

latest_tag_version() {
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
}

release_notes_version() {
  awk '
    /^## [0-9]+\.[0-9]+\.[0-9]+ Release$/ {
      sub(/^## /, "")
      sub(/ Release$/, "")
      print
      exit
    }
  ' RELEASE_NOTES.md
}

latest_release_version() {
  if [[ -n "${INNOFLOW_RELEASE_VERSION:-}" ]]; then
    printf '%s\n' "${INNOFLOW_RELEASE_VERSION#v}"
    return
  fi

  local release_notes_version
  release_notes_version="$(release_notes_version || true)"
  if [[ -n "$release_notes_version" ]]; then
    printf '%s\n' "$release_notes_version"
    return
  fi

  latest_tag_version
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

for readme in README.md README.kr.md README.jp.md README.cn.md; do
  require_pattern \
    "$readme" \
    "from: \"${escaped_version}\"" \
    "SwiftPM install version ${version}"
done

require_pattern \
  RELEASE_NOTES.md \
  "^## ${escaped_version} Release$" \
  "release notes section for ${version}"

require_pattern \
  CHANGELOG.md \
  "^## \\[${escaped_version}\\] - " \
  "changelog section for ${version}"

require_pattern \
  MIGRATION.md \
  "^## ${escaped_version}$" \
  "migration section for ${version}"

require_pattern \
  RELEASING.md \
  "Current stable public release target: \`${escaped_version}\`" \
  "release target ${version}"

require_pattern \
  ARCHITECTURE_CONTRACT.md \
  "one through six explicit state slices" \
  "SelectedStore fixed-arity selection contract"

require_pattern \
  ARCHITECTURE_CONTRACT.md \
  "select\\(dependingOnAll:\\)" \
  "SelectedStore dependingOnAll contract"

require_pattern \
  ARCHITECTURE_CONTRACT.md \
  "always-refresh fallback" \
  "SelectedStore closure fallback contract"

require_pattern \
  README.md \
  "one through six explicit.*select\\(dependingOnAll:\\).*always-refresh fallback" \
  "English SelectedStore selection guidance"

require_pattern \
  README.kr.md \
  "1~6개.*select\\(dependingOnAll:\\).*always-refresh fallback" \
  "Korean SelectedStore selection guidance"

require_pattern \
  README.jp.md \
  "1〜6 個.*select\\(dependingOnAll:\\).*always-refresh fallback" \
  "Japanese SelectedStore selection guidance"

require_pattern \
  README.cn.md \
  "1 到 6 个.*select\\(dependingOnAll:\\).*always-refresh fallback" \
  "Chinese SelectedStore selection guidance"

echo "[check-release-sync] OK: release surface matches ${version}"
