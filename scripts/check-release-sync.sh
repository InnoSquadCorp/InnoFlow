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

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y) return 0 ;;
    *) return 1 ;;
  esac
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

require_published_tag_version() {
  local version="$1"

  if ! is_truthy "${INNOFLOW_REQUIRE_RELEASE_TAG:-0}"; then
    return
  fi

  local tag_version
  tag_version="$(latest_tag_version || true)"
  if [[ -z "$tag_version" ]]; then
    echo "[check-release-sync] Failed: INNOFLOW_REQUIRE_RELEASE_TAG=1 but no semantic release tag exists" >&2
    exit 1
  fi

  if [[ "$tag_version" != "$version" ]]; then
    echo "[check-release-sync] Failed: staged release surface targets ${version}, but latest published tag is ${tag_version}" >&2
    echo "[check-release-sync] Create/pull tag v${version} or rerun without INNOFLOW_REQUIRE_RELEASE_TAG for staged-doc sync" >&2
    exit 1
  fi
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

require_published_tag_version "$version"

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
  "select\\(dependingOn:\\).+for a single explicit state slice" \
  "SelectedStore single-slice selection contract"

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
  "select\\(dependingOn:\\).*select\\(dependingOnAll:\\).*always-refresh fallback" \
  "English SelectedStore selection guidance"

require_pattern \
  README.kr.md \
  "select\\(dependingOn:\\).*select\\(dependingOnAll:\\).*always-refresh fallback" \
  "Korean SelectedStore selection guidance"

require_pattern \
  README.jp.md \
  "select\\(dependingOn:\\).*select\\(dependingOnAll:\\).*always-refresh fallback" \
  "Japanese SelectedStore selection guidance"

require_pattern \
  README.cn.md \
  "select\\(dependingOn:\\).*select\\(dependingOnAll:\\).*always-refresh fallback" \
  "Chinese SelectedStore selection guidance"

echo "[check-release-sync] OK: release surface matches ${version}"
