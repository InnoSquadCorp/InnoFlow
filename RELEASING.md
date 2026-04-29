# Releasing InnoFlow

This document defines the minimum release quality bar for InnoFlow.

Current stable public release target: `4.0.0`

## Release Checklist

Before tagging a release:

1. Update [CHANGELOG.md](CHANGELOG.md).
2. Decide whether [MIGRATION.md](MIGRATION.md) needs a new entry.
3. Run the main package test suite.
4. Run the sample package test suite in `Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage`.
5. Run [scripts/principle-gates.sh](scripts/principle-gates.sh).
6. Generate DocC through [Tools/generate-docc.sh](Tools/generate-docc.sh).
7. Confirm the README and localized README installation snippets match the intended public tag.
8. Confirm [ARCHITECTURE_CONTRACT.md](ARCHITECTURE_CONTRACT.md) and localized README selection guidance match the current public contract.
9. Confirm the GitHub Actions `Release Gate` workflow will run from the intended tag.
10. Confirm the matching `## [<tag>]` section exists in [CHANGELOG.md](CHANGELOG.md); the release workflow publishes that body automatically.

## GitHub Release Notes

The tag-driven `Release Gate` workflow automatically creates the GitHub Release and uses the matching changelog section from [CHANGELOG.md](CHANGELOG.md) as the release body.

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

## Automated Release Artifacts

The release workflow publishes these assets to the GitHub Release:

- packaged DocC archive

If artifact naming or release-note sourcing changes, update this document and [CHANGELOG.md](CHANGELOG.md) in the same release.
