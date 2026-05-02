#!/usr/bin/env bash
# Verifies that localized READMEs (kr/jp/cn) keep their H2 header counts in
# sync with the baselines recorded in docs/contracts/doc-parity.json. The
# baselines acknowledge the current localization gap; the script exists so
# that future drift — adding an H2 to README.md without bumping the baseline
# and translating, or losing an H2 from a translation — is caught in CI
# instead of slipping through.
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PARITY_FILE="${ROOT_DIR}/docs/contracts/doc-parity.json"

if [[ ! -f "$PARITY_FILE" ]]; then
  echo "[check-doc-parity] Failed: $PARITY_FILE not found" >&2
  exit 1
fi

count_headers() {
  local file="$1"
  local prefix="$2"
  local escaped_prefix
  escaped_prefix="$(printf '%s' "$prefix" | sed 's/[[\.*^$/]/\\&/g')"
  grep -c "^${escaped_prefix}" "$file" || true
}

extract_json_value() {
  # Extracts tab-separated rows from the limited JSON contract shape.
  python3 - "$PARITY_FILE" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)

entries = data.get("localizedHeaderParity")
if not isinstance(entries, list) or not entries:
    raise SystemExit(
        "[check-doc-parity] Failed: docs/contracts/doc-parity.json must define a non-empty localizedHeaderParity array"
    )

for entry in entries:
    source = entry["source"]
    header_level = entry["headerLevel"]
    expected_source = entry["expectedSourceHeaderCount"]
    print(f"SOURCE\t{source}\t{header_level}\t{expected_source}")
    translations = entry.get("translations")
    if not isinstance(translations, list) or not translations:
        raise SystemExit(
            f"[check-doc-parity] Failed: localizedHeaderParity entry for {source} must define a non-empty translations array"
        )
    for translation in translations:
        print(
            f"TRANSLATION\t{translation['file']}\t{header_level}\t{translation['expectedHeaderCount']}"
        )
PY
}

failed=0
parity_rows=""
if ! parity_rows="$(extract_json_value)"; then
  exit 1
fi

while IFS=$'\t' read -r kind file header_level expected; do
  [[ -z "${kind:-}" ]] && continue

  file_path="${ROOT_DIR}/${file}"
  if [[ ! -f "$file_path" ]]; then
    echo "[check-doc-parity] Failed: $file is referenced by doc-parity.json but does not exist" >&2
    failed=1
    continue
  fi

  actual="$(count_headers "$file_path" "$header_level")"

  if [[ "$actual" != "$expected" ]]; then
    role="$( [[ "$kind" == "SOURCE" ]] && echo "source" || echo "translation" )"
    echo "[check-doc-parity] Failed: $file ($role) has $actual lines starting with '${header_level}', expected $expected — update docs/contracts/doc-parity.json after translating, or revert the structural change" >&2
    failed=1
  fi
done <<< "$parity_rows"

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

echo "[check-doc-parity] OK: localized header counts match recorded baselines"
