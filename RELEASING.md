# Releasing InnoFlow

This document defines the minimum release quality bar for InnoFlow.

Current stable public release target: `5.0.0`

The `main` branch contains the staged 5.0.0 release contract. Installation
snippets and tag-enforced release metadata must remain aligned with the exact
stable tag.

## Stable 5.0.0 release readiness

The 5.0.0 release tag is exactly `5.0.0`; do not create or document a `v5.0.0`
tag. A release is publish-ready only after its exact tag triggers a successful
GitHub Actions `Release Gate`.

For the current development line, and again before creating the next release
tag, run and confirm:

1. Main package tests: `swift test --jobs 1 --no-parallel -Xswiftc -warnings-as-errors`
2. Release package tests: `swift test -c release --jobs 1 --no-parallel -Xswiftc -warnings-as-errors`
3. Sample package tests: `swift test --package-path Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage --jobs 1 -Xswiftc -warnings-as-errors`
4. Macro source fallback: `swift build --disable-experimental-prebuilts --product InnoFlow --jobs 1 -Xswiftc -warnings-as-errors`
5. Macro operations contract: `scripts/check-macro-operations.sh`
6. DocC generation: `Tools/generate-docc.sh` (exact `swift-docc-plugin` 1.5.0)
7. Release sync: `scripts/check-release-sync.sh`
8. Doc parity: `scripts/check-doc-parity.sh`
9. Full principle gates: `scripts/principle-gates.sh`

To audit the currently published stable tag locally, release-tag enforcement
must also pass:

```bash
INNOFLOW_REQUIRE_RELEASE_TAG=1 INNOFLOW_RELEASE_VERSION=5.0.0 scripts/check-release-sync.sh
```

That command intentionally requires the actual local tag name to be `5.0.0`.
It must not normalize or accept `v5.0.0`.

## Release Checklist

Before tagging a release:

1. Update [CHANGELOG.md](CHANGELOG.md).
2. Decide whether [MIGRATION.md](MIGRATION.md) needs a new entry.
3. Run both deterministic main and release package test commands above; keep
   `--jobs 1 --no-parallel` so shared-runner scheduling cannot invalidate
   wall-clock timeout assertions.
4. Run the sample package test suite in `Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage` with `--jobs 1`.
5. Run [scripts/principle-gates.sh](scripts/principle-gates.sh).
6. Generate DocC through [Tools/generate-docc.sh](Tools/generate-docc.sh) and
   confirm the combined `InnoFlowCore` / `InnoFlow` site plus the nested
   `InnoFlowTesting` API reference are present.
7. Confirm the README and localized README installation snippets match the intended public tag.
8. Confirm [ARCHITECTURE_CONTRACT.md](ARCHITECTURE_CONTRACT.md) and localized README selection guidance match the current public contract.
9. Confirm the GitHub Actions `Release Gate` workflow will run from the intended tag.
10. Confirm tag-triggered release gates run [scripts/principle-gates.sh](scripts/principle-gates.sh) with release-tag enforcement enabled.
11. Confirm the matching `## [<tag>]` section exists in [CHANGELOG.md](CHANGELOG.md); the release workflow publishes that body automatically.
12. Confirm the macro source-fallback workflow passes and the consumer runbook in [docs/MACRO_OPERATIONS.md](docs/MACRO_OPERATIONS.md) matches the release toolchain.

## GitHub Release Notes

The tag-driven `Release Gate` workflow automatically runs the principle gate with release-tag enforcement, creates the GitHub Release, and uses the matching changelog section from [CHANGELOG.md](CHANGELOG.md) as the release body.

That changelog section should summarize:

- user-facing package graph or runtime changes
- documentation or release-process changes
- migration impact, if any

## Documentation Expectations

Each release should leave these entrypoints consistent:

1. [README.md](README.md)
2. [README.kr.md](README.kr.md), [README.jp.md](README.jp.md), and [README.cn.md](README.cn.md)
3. [ARCHITECTURE_CONTRACT.md](ARCHITECTURE_CONTRACT.md)
4. [RELEASE_NOTES.md](RELEASE_NOTES.md)
5. [MIGRATION.md](MIGRATION.md)
6. [Sources/InnoFlow/InnoFlow.docc/InnoFlow.md](Sources/InnoFlow/InnoFlow.docc/InnoFlow.md)
7. [Sources/InnoFlowTesting/InnoFlowTesting.docc/InnoFlowTesting.md](Sources/InnoFlowTesting/InnoFlowTesting.docc/InnoFlowTesting.md)

If a release changes package-consumer behavior or authoring contracts, update those docs in the same change.

## SwiftSyntax Upgrade Policy

`swift-syntax` is constrained to a single toolchain line (for example `"603.0.0"..<"604.0.0"`) because InnoFlow ships compiler macros and macro diagnostics can drift across SwiftSyntax toolchain majors. The manifest range keeps consumer dependency graphs solvable next to other macro packages; the exact version maintainers and CI build against is recorded in `Package.resolved`. Move to a new toolchain line, or bump the resolved patch, only in an intentional release-hardening change that includes:

1. Updating `Package.swift` and `Package.resolved` together.
2. Running the macro test suite and compile-contract tests with warnings as errors.
3. Running `swift format lint --strict --recursive Sources Tests Examples` with the Swift toolchain used by CI.
4. Updating macro diagnostic expectations, migration notes, or release notes when the public authoring surface changes.
5. Building the external macro consumer and `InnoFlow` product with `--disable-experimental-prebuilts`.

## Swift-DocC Plugin Upgrade Policy

`Tools/generate-docc.sh` injects `swift-docc-plugin` 1.5.0 as an exact
dependency into a temporary package copy. This keeps the plugin out of the
consumer dependency graph while ensuring local, Pages, and release-artifact
generation resolve the same documentation tool.

Upgrade that exact version only in an intentional documentation-tooling change
that regenerates the combined `InnoFlowCore` / `InnoFlow` site and the nested
`InnoFlowTesting` reference with warnings treated as errors. Update this policy
and the changelog in the same commit.

## Automated Release Artifacts

The release workflow publishes these assets to the GitHub Release:

- packaged DocC archive

If artifact naming or release-note sourcing changes, update this document and [CHANGELOG.md](CHANGELOG.md) in the same release.
