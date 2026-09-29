#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT
run="$fixture_root/run.json"; artifacts="$fixture_root/artifacts.json"; output="$fixture_root/output.json"
sha="0123456789abcdef0123456789abcdef01234567"
digest="sha256:$(printf '%064d' 0)"

write_run() {
  local conclusion="$1" path="$2"
  printf '{"id":42,"run_attempt":2,"head_sha":"%s","head_branch":"release/6.0.0","status":"completed","conclusion":"%s","event":"workflow_dispatch","path":"%s@refs/heads/release/6.0.0","repository":{"full_name":"InnoSquad/InnoFlow"}}\n' \
    "$sha" "$conclusion" "$path" >"$run"
}
write_artifact() {
  local name="$1" value="$2"
  printf '{"artifacts":[{"id":77,"name":"%s","expired":false,"created_at":"2026-09-11T00:00:00Z","expires_at":"2026-10-11T00:00:00Z","digest":"%s"}]}\n' "$name" "$value" >"$artifacts"
}
expect_failure() {
  if "$script_dir/write-github-evidence-provenance.rb" "$run" "$artifacts" bundle \
    InnoSquad/InnoFlow "$sha" refs/heads/release/6.0.0 "$output" >/dev/null 2>&1; then
    echo "Invalid provenance was accepted: $1" >&2
    exit 1
  fi
}

write_run success .github/workflows/release-evidence.yml
write_artifact bundle "$digest"
"$script_dir/write-github-evidence-provenance.rb" "$run" "$artifacts" bundle \
  InnoSquad/InnoFlow "$sha" refs/heads/release/6.0.0 "$output" >/dev/null
ruby -rjson -e 'j=JSON.parse(File.read(ARGV.fetch(0))); abort unless j.fetch("runId") == "42" && j.fetch("artifactDigest").start_with?("sha256:")' "$output"

ruby -rjson -e 'body=JSON.parse(File.read(ARGV.fetch(0))); body["head_branch"]="6.0.0"; body["path"]=".github/workflows/release-evidence.yml@refs/tags/6.0.0"; File.write(ARGV.fetch(1), JSON.generate(body)+"\n")' \
  "$run" "$fixture_root/tag-run.json"
"$script_dir/write-github-evidence-provenance.rb" "$fixture_root/tag-run.json" "$artifacts" bundle \
  InnoSquad/InnoFlow "$sha" refs/tags/6.0.0 "$fixture_root/tag-output.json" >/dev/null
jq -e '.ref == "refs/tags/6.0.0"' "$fixture_root/tag-output.json" >/dev/null

write_run failure .github/workflows/release-evidence.yml
expect_failure failed-run
write_run success .github/workflows/untrusted.yml
expect_failure wrong-workflow
write_run success .github/workflows/release-evidence.yml
write_artifact other "$digest"
expect_failure missing-artifact
write_artifact bundle unavailable
expect_failure missing-digest
write_run success .github/workflows/release-evidence.yml
write_artifact bundle "$digest"
jq '.status = "in_progress"' "$run" >"$fixture_root/in-progress.json"
mv "$fixture_root/in-progress.json" "$run"
expect_failure incomplete-run
write_run success .github/workflows/release-evidence.yml
jq '.artifacts[0].expired = true' "$artifacts" >"$fixture_root/expired.json"
mv "$fixture_root/expired.json" "$artifacts"
expect_failure expired-artifact
write_artifact bundle "$digest"
jq '.artifacts += [.artifacts[0]]' "$artifacts" >"$fixture_root/duplicate.json"
mv "$fixture_root/duplicate.json" "$artifacts"
expect_failure duplicate-artifact-name
write_artifact bundle "$digest"
jq 'del(.artifacts[0].id)' "$artifacts" >"$fixture_root/no-id.json"
mv "$fixture_root/no-id.json" "$artifacts"
expect_failure missing-artifact-id

preflight_name="innoflow-release-preflight-$sha"
write_run success .github/workflows/release-preflight.yml
ruby -rjson -e 'p=ARGV[0]; j=JSON.parse(File.read(p)); j["path"]=".github/workflows/release-preflight.yml@refs/heads/main"; j["head_branch"]="main"; File.write(p,JSON.generate(j))' "$run"
write_artifact "$preflight_name" "$digest"
cp "$run" "$fixture_root/preflight-valid.json"
cp "$artifacts" "$fixture_root/preflight-artifacts-valid.json"
verify_preflight() {
  "$script_dir/write-github-evidence-provenance.rb" "$run" "$artifacts" "$preflight_name" \
    InnoSquad/InnoFlow "$sha" refs/heads/main "$output" preflight
}
verify_preflight >/dev/null
jq -e '.workflowPath == ".github/workflows/release-preflight.yml" and .ref == "refs/heads/main"' "$output" >/dev/null
for mutation in \
  '.conclusion="failure"' '.status="in_progress"' '.event="pull_request"' \
  '.head_sha="ffffffffffffffffffffffffffffffffffffffff"' \
  '.repository.full_name="Other/InnoFlow"' '.head_branch="feature"' \
  '.path=".github/workflows/release-evidence.yml@refs/heads/main"' \
  '.path=".github/workflows/release-preflight.yml@refs/heads/feature"'; do
  jq "$mutation" "$fixture_root/preflight-valid.json" >"$run"
  if verify_preflight >/dev/null 2>&1; then
    echo "Invalid CI preflight provenance accepted: $mutation" >&2
    exit 1
  fi
done
cp "$fixture_root/preflight-valid.json" "$run"
for mutation in '.artifacts[0].expired=true' '.artifacts[0].digest="unavailable"' \
  '.artifacts[0].name="unrelated"' '.artifacts += [.artifacts[0]]'; do
  jq "$mutation" "$fixture_root/preflight-artifacts-valid.json" >"$artifacts"
  if verify_preflight >/dev/null 2>&1; then
    echo "Invalid CI preflight artifact accepted: $mutation" >&2
    exit 1
  fi
done
cp "$fixture_root/preflight-artifacts-valid.json" "$artifacts"
if "$script_dir/write-github-evidence-provenance.rb" "$run" "$artifacts" "$preflight_name" \
  InnoSquad/InnoFlow "$sha" refs/heads/main "$output" >/dev/null 2>&1; then
  echo "Preflight run incorrectly accepted as tag evidence producer" >&2
  exit 1
fi
verify_preflight >/dev/null

mkdir -p "$fixture_root/bin"
cat >"$fixture_root/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == api ]] || exit 64
case "$2" in
  repos/InnoSquad/InnoFlow/actions/runs/42) cat "$INNOFLOW_PROVENANCE_FIXTURE/run.json" ;;
  'repos/InnoSquad/InnoFlow/actions/runs/42/artifacts?per_page=100') cat "$INNOFLOW_PROVENANCE_FIXTURE/artifacts.json" ;;
  *) exit 64 ;;
esac
SH
chmod +x "$fixture_root/bin/gh"
INNOFLOW_PROVENANCE_FIXTURE="$fixture_root" PATH="$fixture_root/bin:$PATH" \
  GITHUB_REPOSITORY=InnoSquad/InnoFlow GITHUB_SHA="$sha" GITHUB_REF=refs/tags/6.0.0 \
  "$script_dir/write-github-evidence-provenance.sh" --preflight --run-id 42 \
    --artifact-name "$preflight_name" --output "$fixture_root/shell-preflight.json" >/dev/null
jq -e '.ref == "refs/heads/main" and .runId == "42"' "$fixture_root/shell-preflight.json" >/dev/null

echo "[write-github-evidence-provenance-selftest] All checks passed"
