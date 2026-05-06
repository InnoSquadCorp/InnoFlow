# Releasing InnoFlow

This document defines the minimum release quality bar for InnoFlow.

Current stable public release target: `4.0.0`

## Release Checklist

Before tagging a release:

1. Update [CHANGELOG.md](CHANGELOG.md).
2. Decide whether [MIGRATION.md](MIGRATION.md) needs a new entry.
3. Run the main package test suite.
4. Run the sample package test suite in `Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage` with `--jobs 1`.
5. Run [scripts/principle-gates.sh](scripts/principle-gates.sh).
6. Generate DocC through [Tools/generate-docc.sh](Tools/generate-docc.sh).
7. Confirm the README and localized README installation snippets match the intended public tag.
8. Confirm [ARCHITECTURE_CONTRACT.md](ARCHITECTURE_CONTRACT.md) and localized README selection guidance match the current public contract.
9. Confirm the GitHub Actions `Release Gate` workflow will run from the intended tag.
10. Confirm tag-triggered release gates run [scripts/principle-gates.sh](scripts/principle-gates.sh) with release-tag enforcement enabled.
11. Confirm the matching `## [<tag>]` section exists in [CHANGELOG.md](CHANGELOG.md); the release workflow publishes that body automatically.

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

If a release changes package-consumer behavior or authoring contracts, update those docs in the same change.

## SwiftSyntax Upgrade Policy

`swift-syntax` is pinned with an exact version because InnoFlow ships compiler macros and macro diagnostics can drift across SwiftSyntax releases. Upgrade it only in an intentional release-hardening change that includes:

1. Updating `Package.swift` and `Package.resolved` together.
2. Running the macro test suite and compile-contract tests with warnings as errors.
3. Running `swift format lint --strict --recursive Sources Tests Examples` with the Swift toolchain used by CI.
4. Updating macro diagnostic expectations, migration notes, or release notes when the public authoring surface changes.

## Automated Release Artifacts

The release workflow publishes these assets to the GitHub Release:

- packaged DocC archive

If artifact naming or release-note sourcing changes, update this document and [CHANGELOG.md](CHANGELOG.md) in the same release.
