#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

mkdir -p "$fixture_root/docs/contracts" "$fixture_root/Tests/InnoFlowTests" "$fixture_root/scripts"
cp "$root_dir/docs/contracts/release-evidence-policy.json" "$fixture_root/docs/contracts/"
cp "$root_dir/docs/contracts/runtime-test-inventory.json" "$fixture_root/docs/contracts/"
cp "$root_dir/Tests/InnoFlowTests/CompileContractTests.swift" "$fixture_root/Tests/InnoFlowTests/"
cp "$root_dir/scripts/run-focused-platform-runtime-tests.sh" "$fixture_root/scripts/"
cp "$root_dir/scripts/run-release-preflight.sh" "$root_dir/scripts/run-release-preflight.rb" "$fixture_root/scripts/"
cp "$root_dir/scripts/check-sample-swift63.sh" "$fixture_root/scripts/"
cp "$root_dir/scripts/check-doc-swift-syntax.rb" "$fixture_root/scripts/"
cp "$root_dir/scripts/check-doc-copyable-examples.rb" "$fixture_root/scripts/"

ruby "$script_dir/check-release-evidence-policy.rb" "$fixture_root" >/dev/null

expect_mutation_failure() {
  local name="$1" expression="$2"
  cp "$root_dir/docs/contracts/release-evidence-policy.json" "$fixture_root/docs/contracts/release-evidence-policy.json"
  ruby -rjson -e "$expression" "$fixture_root/docs/contracts/release-evidence-policy.json"
  if ruby "$script_dir/check-release-evidence-policy.rb" "$fixture_root" >/dev/null 2>&1; then
    echo "Policy mutation passed: $name" >&2
    exit 1
  fi
}

expect_mutation_failure stale-maximum \
  'p=ARGV.fetch(0); j=JSON.parse(File.read(p)); c=j.fetch("checks").find { |x| x.fetch("id")=="external-macro-consumer" }; c["maximumTestCount"]=1; File.write(p,JSON.generate(j)+"\n")'
expect_mutation_failure missing-test \
  'p=ARGV.fetch(0); j=JSON.parse(File.read(p)); c=j.fetch("checks").find { |x| x.fetch("id")=="external-macro-consumer" }; c.fetch("expectedTestNames").pop; c["minimumTestCount"]-=1; c["maximumTestCount"]-=1; File.write(p,JSON.generate(j)+"\n")'
expect_mutation_failure substituted-test \
  'p=ARGV.fetch(0); j=JSON.parse(File.read(p)); c=j.fetch("checks").find { |x| x.fetch("id")=="external-macro-consumer" }; c.fetch("expectedTestNames")[0]="Phantom compile contract"; File.write(p,JSON.generate(j)+"\n")'
expect_mutation_failure partial-filter \
  'p=ARGV.fetch(0); j=JSON.parse(File.read(p)); c=j.fetch("checks").find { |x| x.fetch("id")=="external-macro-consumer" }; c.fetch("commandContract").fetch("exclusiveOptionValues")["--filter"]="CompileContractTests/exportedMacroFeaturesWorkAcrossTargetBoundaries"; File.write(p,JSON.generate(j)+"\n")'
expect_mutation_failure package-redirection \
  'p=ARGV.fetch(0); j=JSON.parse(File.read(p)); c=j.fetch("checks").find { |x| x.fetch("id")=="external-macro-consumer" }; c.fetch("commandContract").fetch("forbiddenArgumentPrefixes").delete("--package-path"); File.write(p,JSON.generate(j)+"\n")'
expect_mutation_failure swift63-incorrect-run-count \
  'p=ARGV.fetch(0); j=JSON.parse(File.read(p)); c=j.fetch("checks").find { |x| x.fetch("id")=="swift-6.3-toolchain" }; c["expectedTestRunCount"]=2; File.write(p,JSON.generate(j)+"\n")'
expect_mutation_failure swift64-incorrect-run-count \
  'p=ARGV.fetch(0); j=JSON.parse(File.read(p)); c=j.fetch("checks").find { |x| x.fetch("id")=="swift-6.4-toolchain" }; c["expectedTestRunCount"]=1; File.write(p,JSON.generate(j)+"\n")'
expect_mutation_failure sdk-direct-build \
  'p=ARGV.fetch(0); j=JSON.parse(File.read(p)); c=j.fetch("checks").find { |x| x.fetch("id")=="sdk-macos" }; c.fetch("commandContract")["executable"]="xcodebuild"; File.write(p,JSON.generate(j)+"\n")'
expect_mutation_failure sdk-unstructured-result \
  'p=ARGV.fetch(0); j=JSON.parse(File.read(p)); j.fetch("profiles").fetch("build")["resultFormat"]="command-exit"; File.write(p,JSON.generate(j)+"\n")'
expect_mutation_failure retired-product-check \
  'p=ARGV.fetch(0); j=JSON.parse(File.read(p)); j.fetch("checks") << {"id"=>"mulbyul-returned","stage"=>"local-preflight"}; File.write(p,JSON.generate(j)+"\n")'
expect_mutation_failure migration-command-bypass \
  'p=ARGV.fetch(0); j=JSON.parse(File.read(p)); c=j.fetch("checks").find { |x| x.fetch("id")=="migration-consumer" }; c.fetch("commandContract")["executable"]="true"; File.write(p,JSON.generate(j)+"\n")'
expect_mutation_failure sample-swift63-count-bypass \
  'p=ARGV.fetch(0); j=JSON.parse(File.read(p)); c=j.fetch("checks").find { |x| x.fetch("id")=="sample-swift-6.3" }; c["minimumTestCount"]=1; File.write(p,JSON.generate(j)+"\n")'
expect_mutation_failure doc-syntax-bypass \
  'p=ARGV.fetch(0); j=JSON.parse(File.read(p)); c=j.fetch("checks").find { |x| x.fetch("id")=="doc-swift-syntax" }; c.fetch("commandContract")["executable"]="true"; File.write(p,JSON.generate(j)+"\n")'
expect_mutation_failure doc-copyable-bypass \
  'p=ARGV.fetch(0); j=JSON.parse(File.read(p)); c=j.fetch("checks").find { |x| x.fetch("id")=="doc-copyable-examples" }; c.fetch("commandContract")["executable"]="true"; File.write(p,JSON.generate(j)+"\n")'
expect_mutation_failure unpinned-runtime-inventory \
  'p=ARGV.fetch(0); j=JSON.parse(File.read(p)); c=j.fetch("checks").find { |x| x.fetch("id")=="runtime-ios-18.5" }; c.delete("testIdentifierInventorySha256"); File.write(p,JSON.generate(j)+"\n")'

command_repository="$fixture_root/command-repository"
command_snapshot="$fixture_root/command-candidate.json"
mkdir -p "$command_repository/docs/contracts" "$command_repository/Tests/InnoFlowTests"
cp "$root_dir/docs/contracts/release-evidence-policy.json" "$command_repository/docs/contracts/"
cp "$root_dir/docs/contracts/runtime-test-inventory.json" "$command_repository/docs/contracts/"
cp "$root_dir/Tests/InnoFlowTests/CompileContractTests.swift" "$command_repository/Tests/InnoFlowTests/"
git -C "$command_repository" init -q
git -C "$command_repository" config user.name selftest
git -C "$command_repository" config user.email selftest@example.invalid
git -C "$command_repository" add docs Tests
git -C "$command_repository" commit -qm candidate
"$script_dir/release-candidate-snapshot.rb" \
  --repository "innoflow=$command_repository" \
  --policy "$command_repository/docs/contracts/release-evidence-policy.json" >"$command_snapshot"
command_candidate="$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("aggregateDigest")' "$command_snapshot")"

validate_external_macro_command() {
  "$script_dir/release-evidence-tool.rb" validate-command \
    --policy "$command_repository/docs/contracts/release-evidence-policy.json" \
    --check-id external-macro-consumer \
    --candidate "$command_candidate" \
    --candidate-snapshot "$command_snapshot" \
    --component-label innoflow -- "$@"
}

validate_external_macro_command swift test --filter CompileContractTests >/dev/null
if validate_external_macro_command swift test --filter CompileContractTests \
  --package-path "$fixture_root/foreign-package" >/dev/null 2>&1; then
  echo "Package redirection command passed: split option" >&2
  exit 1
fi
if validate_external_macro_command swift test --filter CompileContractTests \
  "--package-path=$fixture_root/foreign-package" >/dev/null 2>&1; then
  echo "Package redirection command passed: joined option" >&2
  exit 1
fi

validate_sdk_command() {
  "$script_dir/release-evidence-tool.rb" validate-command \
    --policy "$command_repository/docs/contracts/release-evidence-policy.json" \
    --check-id sdk-macos \
    --candidate "$command_candidate" \
    --candidate-snapshot "$command_snapshot" \
    --component-label innoflow -- "$@"
}

sdk_command=(scripts/run-sdk-platform-build.sh --platform macOS --derived-data "$fixture_root/Derived" --result-bundle "$fixture_root/build.xcresult")
validate_sdk_command "${sdk_command[@]}" >/dev/null
if validate_sdk_command scripts/run-sdk-platform-build.sh --platform iOS --derived-data "$fixture_root/Derived" --result-bundle "$fixture_root/build.xcresult" >/dev/null 2>&1; then
  echo "Wrong SDK platform command passed" >&2
  exit 1
fi
for bypass in -version -list -showBuildSettings; do
  if validate_sdk_command "${sdk_command[@]}" "$bypass" >/dev/null 2>&1; then
    echo "Non-build SDK command passed: $bypass" >&2
    exit 1
  fi
done
if validate_sdk_command scripts/run-sdk-platform-build.sh --platform macOS --derived-data "$fixture_root/Derived" >/dev/null 2>&1; then
  echo "SDK command without result bundle passed" >&2
  exit 1
fi
if validate_sdk_command "${sdk_command[@]}" --project "$fixture_root/Foreign.xcodeproj" >/dev/null 2>&1; then
  echo "Project redirection command passed" >&2
  exit 1
fi

validate_runtime_command() {
  "$script_dir/release-evidence-tool.rb" validate-command \
    --policy "$command_repository/docs/contracts/release-evidence-policy.json" \
    --check-id runtime-ios-18.5 \
    --candidate "$command_candidate" \
    --candidate-snapshot "$command_snapshot" \
    --component-label innoflow -- "$@"
}
runtime_command=(scripts/run-focused-platform-runtime-tests.sh --destination 'platform=iOS Simulator,OS=18.5,name=iPhone 16' --derived-data "$fixture_root/Derived" --result-bundle "$fixture_root/runtime.xcresult")
validate_runtime_command "${runtime_command[@]}" >/dev/null
if validate_runtime_command "${runtime_command[@]}" --package-root "$fixture_root/foreign-package" >/dev/null 2>&1; then
  echo "Runtime command accepted a foreign package root" >&2
  exit 1
fi

validate_swift_command() {
  "$script_dir/release-evidence-tool.rb" validate-command \
    --policy "$command_repository/docs/contracts/release-evidence-policy.json" \
    --check-id swift-6.4-toolchain \
    --candidate "$command_candidate" \
    --candidate-snapshot "$command_snapshot" \
    --component-label innoflow -- "$@"
}
swift_command=(scripts/run-swift-toolchain-evidence.sh --expected-prefix 6.4 -- swift test --jobs 1 --no-parallel -Xswiftc -warnings-as-errors)
validate_swift_command "${swift_command[@]}" >/dev/null
if validate_swift_command scripts/run-swift-toolchain-evidence.sh --expected-prefix 6.4 -- swift test >/dev/null 2>&1; then
  echo "Swift command without deterministic flags passed" >&2
  exit 1
fi

echo "[check-release-evidence-policy-selftest] All checks passed"
