#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bash "$SCRIPT_DIR/check-ruby-version.sh"
for bad in Unreleased 2026-02-30 2026-1-01 '2026-10-03 trailing'; do
  printf '## [6.0.0] - %s\n' "$bad" > "$tmp/CHANGELOG.md"
  if ruby "$SCRIPT_DIR/check-release-date.rb" "$tmp/CHANGELOG.md" 6.0.0 > "$tmp/out" 2>&1; then
    echo "invalid release date accepted: $bad" >&2; exit 1
  fi
done
printf '## [6.0.0] - 2026-10-03\n' > "$tmp/CHANGELOG.md"
ruby "$SCRIPT_DIR/check-release-date.rb" "$tmp/CHANGELOG.md" 6.0.0
printf '## [6.0.0] - 2026-10-03\n' >> "$tmp/CHANGELOG.md"
if ruby "$SCRIPT_DIR/check-release-date.rb" "$tmp/CHANGELOG.md" 6.0.0 > "$tmp/out" 2>&1; then
  echo 'duplicate release heading accepted' >&2; exit 1
fi
mkdir "$tmp/bin"
cat > "$tmp/bin/ruby" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == '--version' ]]; then echo 'ruby 2.6.10'; exit 0; fi
exit 1
MOCK
chmod +x "$tmp/bin/ruby"
if PATH="$tmp/bin:$PATH" bash "$SCRIPT_DIR/check-ruby-version.sh" > "$tmp/out" 2>&1; then
  echo 'Ruby 2.6 accepted' >&2; exit 1
fi
grep -q 'Ruby >= 2.7 is required' "$tmp/out"
echo '[validation-prerequisites] positive and negative controls passed'
