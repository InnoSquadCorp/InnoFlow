#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
checker="$script_dir/verify-release-publication.sh"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT
unset GITHUB_REF_TYPE GITHUB_REF_NAME INNOFLOW_TRIGGER_TAG

git init -q --bare "$fixture_root/remote.git"
git init -q "$fixture_root/candidate"
cd "$fixture_root/candidate"
git config user.name "Release fixture"
git config user.email "release-fixture@example.invalid"
git remote add origin "$fixture_root/remote.git"
git -c commit.gpgsign=false commit --allow-empty -qm candidate
sha="$(git rev-parse HEAD)"
git -c tag.gpgsign=false tag 6.0.0
git -c tag.gpgsign=false tag -a 6.0.1 -m 'Annotated fixture'
git push -q origin refs/tags/6.0.0 refs/tags/6.0.1

"$checker" 6.0.0 "$sha" >/dev/null
"$checker" 6.0.1 "$sha" >/dev/null
expect_failure() {
  local name="$1"
  shift
  if "$@" >"$fixture_root/$name.log" 2>&1; then
    echo "Publication fixture was not rejected: $name" >&2
    exit 1
  fi
}
expect_failure invalid-tag "$checker" v6.0.0 "$sha"
expect_failure invalid-sha "$checker" 6.0.0 main
expect_failure wrong-sha "$checker" 6.0.0 1111111111111111111111111111111111111111
expect_failure missing-tag "$checker" 6.0.2 "$sha"
git -c tag.gpgsign=false tag 6.0.2
expect_failure missing-remote-tag "$checker" 6.0.2 "$sha"
expect_failure wrong-trigger env GITHUB_REF_TYPE=tag GITHUB_REF_NAME=6.0.1 "$checker" 6.0.0 "$sha"

# Simulate a remote-only retarget without altering the candidate checkout.
git -c commit.gpgsign=false commit --allow-empty -qm other
other_sha="$(git rev-parse HEAD)"
git push -q --force origin HEAD:refs/tags/6.0.0
git -c tag.gpgsign=false tag -f -a 6.0.1 -m 'Moved annotated fixture'
git push -q --force origin refs/tags/6.0.1
git checkout -q --detach "$sha"
git -c tag.gpgsign=false tag -f -a 6.0.1 -m 'Original annotated fixture'
expect_failure moved-lightweight-tag "$checker" 6.0.0 "$sha"
expect_failure moved-annotated-tag "$checker" 6.0.1 "$sha"
expect_failure checkout-mismatch "$checker" 6.0.0 "$other_sha"
git remote set-url origin "$fixture_root/missing.git"
expect_failure remote-unavailable "$checker" 6.0.0 "$sha"
echo "[verify-release-publication-selftest] All checks passed"
