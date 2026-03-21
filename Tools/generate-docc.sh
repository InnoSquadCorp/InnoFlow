#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

OUTPUT_DIR="${1:-$ROOT_DIR/.build/docc/InnoFlow}"
TARGET="${2:-InnoFlow}"
HOSTING_BASE_PATH="${3:-InnoFlow}"
TARGET_SLUG="$(printf '%s' "$TARGET" | tr '[:upper:]' '[:lower:]')"
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
  --exclude '.git' \
  "$ROOT_DIR/" "$DOCS_PACKAGE_DIR/"

python3 - "$DOCS_MANIFEST_PATH" <<'PY'
import pathlib
import re
import sys

manifest_path = pathlib.Path(sys.argv[1])
text = manifest_path.read_text()
dependency_line = '        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0"),\n'

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

echo "[docc] Generating DocC for target '$TARGET' -> $OUTPUT_DIR"
swift package \
  --package-path "$DOCS_PACKAGE_DIR" \
  --allow-writing-to-directory "$OUTPUT_DIR" \
  generate-documentation \
  --target "$TARGET" \
  --output-path "$OUTPUT_DIR" \
  --disable-indexing \
  --transform-for-static-hosting \
  --hosting-base-path "$HOSTING_BASE_PATH"

cat > "$OUTPUT_DIR/index.html" <<EOF
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta http-equiv="refresh" content="0; url=./documentation/$TARGET_SLUG/" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>${TARGET} Documentation</title>
    <script>
      window.location.replace("./documentation/$TARGET_SLUG/");
    </script>
  </head>
  <body>
    <p>
      Redirecting to
      <a href="./documentation/$TARGET_SLUG/">${TARGET} documentation</a>.
    </p>
  </body>
</html>
EOF

echo "[docc] Done"
