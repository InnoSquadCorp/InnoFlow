#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

OUTPUT_DIR="${1:-$ROOT_DIR/.build/docc/InnoFlow}"
TARGET="${2:-InnoFlow}"
HOSTING_BASE_PATH="${3:-InnoFlow}"
DOCC_PLUGIN_VERSION="1.5.0"
DOCS_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/innoflow-docc.XXXXXX")"
DOCS_PACKAGE_DIR="$DOCS_WORK_DIR/package"
DOCS_MANIFEST_PATH="$DOCS_PACKAGE_DIR/Package.swift"

cleanup() {
  rm -rf "$DOCS_WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$OUTPUT_DIR"
mkdir -p "$DOCS_PACKAGE_DIR"

rsync -a \
  --exclude '.build' \
  --exclude '.build-*' \
  --exclude '.git' \
  "$ROOT_DIR/" "$DOCS_PACKAGE_DIR/"

python3 - "$DOCS_MANIFEST_PATH" "$DOCC_PLUGIN_VERSION" <<'PY'
import pathlib
import re
import sys

manifest_path = pathlib.Path(sys.argv[1])
plugin_version = sys.argv[2]
text = manifest_path.read_text()
dependency_line = f'        .package(url: "https://github.com/swiftlang/swift-docc-plugin", exact: "{plugin_version}"),\n'

if "swift-docc-plugin" in text:
    raise SystemExit(0)

pattern = re.compile(
    r'(dependencies:\s*\[\n(?:\s*\.package\(url: "https://github\.com/swiftlang/swift-syntax\.git", from: "602\.0\.0"\),\n)?)',
    re.MULTILINE,
)
match = pattern.search(text)
if not match:
    raise SystemExit("Unable to locate dependencies section in Package.swift")

replacement = match.group(1) + dependency_line
manifest_path.write_text(text[:match.start(1)] + replacement + text[match.end(1):])
PY

echo "[docc] Using swift-docc-plugin $DOCC_PLUGIN_VERSION (exact)"

generate_documentation() {
  local target="$1"
  local output_dir="$2"
  local hosting_base_path="$3"

  mkdir -p "$output_dir"
  echo "[docc] Generating DocC for target '$target' -> $output_dir"
  swift package \
    --package-path "$DOCS_PACKAGE_DIR" \
    --allow-writing-to-directory "$output_dir" \
    generate-documentation \
    --target "$target" \
    --output-path "$output_dir" \
    --disable-indexing \
    --warnings-as-errors \
    --transform-for-static-hosting \
    --hosting-base-path "$hosting_base_path"
}

generate_combined_documentation() {
  local output_dir="$1"
  local hosting_base_path="$2"
  shift 2

  local target_arguments=()
  local target
  for target in "$@"; do
    target_arguments+=(--target "$target")
  done

  mkdir -p "$output_dir"
  echo "[docc] Generating combined DocC for targets '$*' -> $output_dir"
  swift package \
    --package-path "$DOCS_PACKAGE_DIR" \
    --allow-writing-to-directory "$output_dir" \
    generate-documentation \
    "${target_arguments[@]}" \
    --enable-experimental-combined-documentation \
    --output-path "$output_dir" \
    --disable-indexing \
    --warnings-as-errors \
    --transform-for-static-hosting \
    --hosting-base-path "$hosting_base_path"
}

write_redirect_index() {
  local output_dir="$1"
  local target="$2"
  local target_slug
  target_slug="$(printf '%s' "$target" | tr '[:upper:]' '[:lower:]')"

  cat > "$output_dir/index.html" <<EOF
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta http-equiv="refresh" content="0; url=./documentation/$target_slug/" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>${target} Documentation</title>
    <script>
      window.location.replace("./documentation/$target_slug/");
    </script>
  </head>
  <body>
    <p>
      Redirecting to
      <a href="./documentation/$target_slug/">${target} documentation</a>.
    </p>
  </body>
</html>
EOF
}

verify_documentation_entry() {
  local output_dir="$1"
  local target="$2"
  local hosting_base_path="$3"
  local target_slug
  local normalized_base_path
  local entry_path

  target_slug="$(printf '%s' "$target" | tr '[:upper:]' '[:lower:]')"
  normalized_base_path="${hosting_base_path#/}"
  normalized_base_path="${normalized_base_path%/}"
  entry_path="$output_dir/documentation/$target_slug/index.html"

  if [[ ! -f "$entry_path" ]]; then
    echo "[docc] Missing generated entry point: $entry_path" >&2
    return 1
  fi

  if [[ -n "$normalized_base_path" ]]; then
    normalized_base_path="/$normalized_base_path/"
  else
    normalized_base_path="/"
  fi

  if ! grep -Fq "var baseUrl = \"$normalized_base_path\"" "$entry_path"; then
    echo "[docc] Generated entry point does not use base path '$normalized_base_path': $entry_path" >&2
    return 1
  fi
}

if [[ "$TARGET" == "InnoFlow" ]]; then
  generate_combined_documentation \
    "$OUTPUT_DIR" \
    "$HOSTING_BASE_PATH" \
    "InnoFlowCore" \
    "InnoFlow"
else
  generate_documentation "$TARGET" "$OUTPUT_DIR" "$HOSTING_BASE_PATH"
fi
write_redirect_index "$OUTPUT_DIR" "$TARGET"
verify_documentation_entry "$OUTPUT_DIR" "$TARGET" "$HOSTING_BASE_PATH"
if [[ "$TARGET" == "InnoFlow" ]]; then
  verify_documentation_entry "$OUTPUT_DIR" "InnoFlowCore" "$HOSTING_BASE_PATH"
fi

# The public testing product has its own symbol graph. Keep the existing
# InnoFlow site and release artifact root stable while publishing that graph
# alongside it under a nested hosting base path.
if [[ "$TARGET" == "InnoFlow" ]]; then
  TESTING_OUTPUT_DIR="$OUTPUT_DIR/testing"
  TESTING_HOSTING_BASE_PATH="${HOSTING_BASE_PATH%/}/testing"

  generate_documentation \
    "InnoFlowTesting" \
    "$TESTING_OUTPUT_DIR" \
    "$TESTING_HOSTING_BASE_PATH"
  write_redirect_index "$TESTING_OUTPUT_DIR" "InnoFlowTesting"
  verify_documentation_entry \
    "$TESTING_OUTPUT_DIR" \
    "InnoFlowTesting" \
    "$TESTING_HOSTING_BASE_PATH"
fi

echo "[docc] Done"
