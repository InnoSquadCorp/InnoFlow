#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT
mkdir -p "$fixture_root/bin"

head_sha="0123456789abcdef0123456789abcdef01234567"
digest="sha256:$(printf 'a%.0s' {1..64})"
cat >"$fixture_root/run.json" <<JSON
{"id":42,"run_attempt":2,"head_sha":"$head_sha","head_branch":"release/6.0.0","status":"completed","conclusion":"success","event":"workflow_dispatch","path":".github/workflows/release-evidence.yml@refs/heads/release/6.0.0","repository":{"full_name":"InnoSquad/InnoFlow"}}
JSON
cat >"$fixture_root/artifacts.json" <<JSON
{"artifacts":[{"id":77,"name":"innoflow-release-evidence-$head_sha","expired":false,"created_at":"2026-09-11T00:00:00Z","expires_at":"2026-10-11T00:00:00Z","digest":"$digest"}]}
JSON
"$script_dir/write-github-evidence-provenance.rb" \
  "$fixture_root/run.json" "$fixture_root/artifacts.json" \
  "innoflow-release-evidence-$head_sha" InnoSquad/InnoFlow "$head_sha" \
  refs/heads/release/6.0.0 \
  "$fixture_root/context.json" >/dev/null

cat >"$fixture_root/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == api ]]
case "$2" in
  */artifacts\?per_page=100) cat "$GH_FIXTURE_ROOT/artifacts.json" ;;
  */actions/runs/42) cat "$GH_FIXTURE_ROOT/run.json" ;;
  *) exit 64 ;;
esac
SH
chmod +x "$fixture_root/bin/gh"

PATH="$fixture_root/bin:$PATH" GH_FIXTURE_ROOT="$fixture_root" \
  INNOFLOW_TRUSTED_PRODUCER_CONTEXT="$fixture_root/context.json" \
  "$script_dir/verify-github-evidence-run.sh" >/dev/null

jq '.conclusion = "failure"' "$fixture_root/run.json" >"$fixture_root/failed-run.json"
mv "$fixture_root/failed-run.json" "$fixture_root/run.json"
if PATH="$fixture_root/bin:$PATH" GH_FIXTURE_ROOT="$fixture_root" \
  INNOFLOW_TRUSTED_PRODUCER_CONTEXT="$fixture_root/context.json" \
  "$script_dir/verify-github-evidence-run.sh" >/dev/null 2>&1; then
  echo "A failed producer run must be rejected" >&2
  exit 1
fi

if PATH="$fixture_root/bin:$PATH" GH_FIXTURE_ROOT="$fixture_root" \
  INNOFLOW_TRUSTED_PRODUCER_CONTEXT="$fixture_root/missing.json" \
  "$script_dir/verify-github-evidence-run.sh" >/dev/null 2>&1; then
  echo "A missing trusted context must be rejected" >&2
  exit 1
fi

echo "[verify-github-evidence-run-selftest] All checks passed"
