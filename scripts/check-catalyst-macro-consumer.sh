#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$root_dir/Tests/InnoFlowTests/Fixtures/CatalystMacroConsumer"
derived_data="${INNOFLOW_CATALYST_DERIVED_DATA:-$root_dir/.build/catalyst-macro-consumer-derived}"
(
  cd "$fixture"
  xcodebuild -quiet \
    -scheme CatalystMacroConsumer \
    -destination 'generic/platform=macOS,variant=Mac Catalyst' \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build
)

negative_log="$derived_data-negative.log"
set +e
(
  cd "$fixture"
  xcodebuild -quiet \
    -scheme CatalystMacroConsumer \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$derived_data-negative" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    'OTHER_SWIFT_FLAGS=$(inherited) -DINNOFLOW_NEGATIVE_IOS_AVAILABILITY' \
    build
) >"$negative_log" 2>&1
negative_status=$?
set -e
if [[ "$negative_status" -eq 0 ]]; then
  echo "The iOS availability-negative consumer unexpectedly compiled" >&2
  exit 1
fi
if ! grep -Eq "catalystOnlyCasePath.*unavailable|unavailable.*catalystOnlyCasePath" "$negative_log"; then
  echo "The iOS negative failed without the required native availability diagnostic" >&2
  tail -80 "$negative_log" >&2
  exit 1
fi
echo "[check-catalyst-macro-consumer] OK"
