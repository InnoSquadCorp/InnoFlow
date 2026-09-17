#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/release-tag-policy.sh"

cd "$ROOT_DIR"

latest_release_tag_name() {
  if git rev-parse --git-dir >/dev/null 2>&1; then
    local latest_tag
    latest_tag="$(
      git tag --list --sort=-v:refname \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
        | head -n 1 \
        || true
    )"
    if [[ -n "$latest_tag" ]]; then
      printf '%s\n' "$latest_tag"
      return
    fi
  fi
}

latest_tag_version() {
  latest_release_tag_name
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

  require_release_tag_at_head "$version"
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

if [[ ! -f STABLE_VERSION ]]; then
  echo "[check-release-sync] Failed: STABLE_VERSION not found" >&2
  exit 1
fi

if [[ "$(awk 'END { print NR }' STABLE_VERSION)" != "1" ]]; then
  echo "[check-release-sync] Failed: STABLE_VERSION must contain exactly one line" >&2
  exit 1
fi

stable_version="$(sed -n '1p' STABLE_VERSION)"
if [[ ! "$stable_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "[check-release-sync] Failed: STABLE_VERSION must be numeric SemVer" >&2
  exit 1
fi

escaped_stable_version="${stable_version//./\\.}"
require_pattern \
  RELEASING.md \
  "Current stable public release: \`${escaped_stable_version}\`" \
  "current stable release ${stable_version} matching STABLE_VERSION"

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

if is_truthy "${INNOFLOW_REQUIRE_RELEASE_TAG:-0}"; then
  require_pattern \
    RELEASING.md \
    "Current stable public release: \`${escaped_version}\`" \
    "current stable release ${version}"
else
  require_pattern \
    RELEASING.md \
    "Current (stable public release|staged release candidate): \`${escaped_version}\`" \
    "stable or staged release ${version}"
fi

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
