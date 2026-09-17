# Releasing InnoFlow

This document defines the minimum release quality bar for InnoFlow.

Current stable public release: `5.1.1` (tagged and published on GitHub
Releases, 2026-08-26)

Current staged release candidate: `6.0.0` (local and untagged, 2026-09-03)

The `release/6.0.0-local` branch carries the staged 6.0.0 contract.
Installation snippets and non-tag release metadata are aligned with that
candidate. Publishing still requires promoting this line to the stable field,
creating the exact tag, and passing tag-enforced release gates.

## Stable release readiness

The 6.0.0 release tag must be exactly `6.0.0`; do not create or document a `v6.0.0`
tag. A release is publish-ready only after its exact tag triggers a successful
GitHub Actions `Release Gate`.

For the current development line, and again before creating the next release
tag, run and confirm:

1. Main package tests: `swift test --jobs 1 --no-parallel -Xswiftc -warnings-as-errors`
2. Release package tests: `swift test -c release --jobs 1 --no-parallel -Xswiftc -warnings-as-errors`
3. Sample package tests: `swift test --package-path Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage --jobs 1 -Xswiftc -warnings-as-errors`
4. Macro source fallback: `swift build --disable-experimental-prebuilts --product InnoFlow --jobs 1 -Xswiftc -warnings-as-errors`
5. Macro operations contract: `scripts/check-macro-operations.sh`
6. Package builds for every declared destination: `macOS`, `iOS`, `tvOS`,
   `watchOS`, and `visionOS`, using the `InnoFlow-Package` scheme and
   `generic/platform=<platform>` destinations with code signing disabled.
7. Public API comparison against the previous stable tag:
   `swift package diagnose-api-breaking-changes 5.1.1 --products InnoFlow InnoFlowCore InnoFlowSwiftUI InnoFlowTesting`.
   A minor or patch release must have no unexplained breakage. A major release
   may return a nonzero result only when every public migration is documented.
   The 6.0.0 classification is recorded in
   [docs/API_BREAKAGE_6_0.md](docs/API_BREAKAGE_6_0.md).
8. Thread and address sanitizer package tests, each with `--jobs 1 --no-parallel`.
9. DocC generation: `Tools/generate-docc.sh` (`swift-docc-plugin` 1.5.0 at revision `647c708be89f834fa6a6d4945442793a77ddf5b6`, `swift-docc-symbolkit` 1.0.0 at revision `b45d1f2ed151d057b54504d653e0da5552844e34`, and `swift-syntax` 603.0.1 at revision `9de99a78f099e59caf2b2beec65a4c45d54b2081`, resolved only from `Tools/docc-package.resolved`)
10. Release sync: `scripts/check-release-sync.sh`
11. Doc parity: `scripts/check-doc-parity.sh`
12. Full principle gates: `scripts/principle-gates.sh`
13. Instrumented coverage and required-module inventory: `scripts/run-coverage.sh`.
    The shared CI/release workflow enforces the repository-owned
    [coverage policy](docs/contracts/coverage-policy.json), preserves the raw
    report and module summary, and fails if the candidate changes during the run.
    See [gate mapping and limits](docs/CI_GATES.md) for the InnoRouter adoption.

`STABLE_VERSION` is the machine-checked stable-release marker. While it remains
on the prior major, `scripts/check-api-compatibility.sh` deliberately stages the
unpublished `6.0.0` baseline. Promoting `STABLE_VERSION` to `6.0.0` makes the
baseline mandatory before checking whether the tag is available, so a deleted
or missing stable tag fails closed instead of silently disabling the gate. With
the tag present, the script compares all four public products and fails on any
source-breaking change. Override `INNOFLOW_API_BASELINE` only when intentionally
opening a new major development line.

To audit the currently published stable tag locally, release-tag enforcement
must also pass:

```bash
INNOFLOW_REQUIRE_RELEASE_TAG=1 INNOFLOW_RELEASE_VERSION=6.0.0 scripts/check-release-sync.sh
```

That command intentionally requires the exact local tag `6.0.0` to point at
the checked-out commit and `Current stable public release` to be promoted to
`6.0.0`. In GitHub Actions, the triggering `GITHUB_REF_NAME` is authoritative
and must match the staged version. The gate must not normalize or accept
`v6.0.0`. The command is expected to fail while the candidate is deliberately
untagged.

## Release Checklist

Before tagging a release:

1. Update [CHANGELOG.md](CHANGELOG.md).
2. Decide whether [MIGRATION.md](MIGRATION.md) needs a new entry.
3. Run both deterministic main and release package test commands above; keep
   `--jobs 1 --no-parallel` so shared-runner scheduling cannot invalidate
   wall-clock timeout assertions.
4. Run the sample package test suite in `Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage` with `--jobs 1`.
5. Build the `InnoFlow-Package` scheme for every declared Apple platform. The
   tag workflow runs these as independent required jobs, and release publishing
   depends on all five succeeding.
6. Compare the public API with the previous stable tag. For a major release,
   classify every reported external break and verify that [MIGRATION.md](MIGRATION.md)
   provides its replacement. Do not treat package-scoped implementation
   diagnostics as consumer-facing API removals. Keep the version-specific
   classification artifact in `docs/` with the release change.
7. Run both thread and address sanitizer suites. The tag workflow runs them as
   independent required jobs, and release publishing depends on both.
8. Run [scripts/principle-gates.sh](scripts/principle-gates.sh).
9. Generate DocC through [Tools/generate-docc.sh](Tools/generate-docc.sh) and
   confirm the combined `InnoFlowCore` / `InnoFlow` site plus the nested
   `InnoFlowTesting` API reference are present.
10. Confirm the README and localized README installation snippets match the intended public tag.
11. Confirm [ARCHITECTURE_CONTRACT.md](ARCHITECTURE_CONTRACT.md) and localized README selection guidance match the current public contract.
12. Confirm the GitHub Actions `Release Gate` workflow will run from the intended tag.
13. Confirm tag-triggered release gates run [scripts/principle-gates.sh](scripts/principle-gates.sh) with release-tag enforcement enabled.
14. Confirm the matching `## [<tag>]` section exists in [CHANGELOG.md](CHANGELOG.md); the release workflow publishes that body automatically.
15. Confirm the macro source-fallback workflow passes and the consumer runbook in [docs/MACRO_OPERATIONS.md](docs/MACRO_OPERATIONS.md) matches the release toolchain.
16. Promote `STABLE_VERSION` and `Current stable public release` above to the
    candidate version, then remove the staged-candidate line in the tag-creating
    commit. The API gate must fail closed if that tag is later unavailable.
17. Confirm [SECURITY.md](SECURITY.md) lists the candidate major and every
    intentionally supported prior line; remove versions that no longer receive
    coordinated fixes.
18. Confirm the repository's server-side tag rules prevent update and deletion
    of release tags. The local and workflow checks bind the triggering tag to
    the checked-out commit, but only immutable-tag enforcement closes the gap
    between a completed gate and the later GitHub Release API call.
19. Create `candidate.json` with `scripts/release-candidate-snapshot.rb` from
    the exact InnoFlow and Mulbyul checkouts plus the single canonical
    [JSON evidence policy](docs/contracts/release-evidence-policy.json). Use
    `scripts/record-release-evidence.sh` for commands and preserved raw
    xcresult bundles, and `scripts/record-manual-release-evidence.sh` only for
    a pre-existing manual observation artifact. Verify the complete directory
    through the `local-preflight` stage with
    `scripts/verify-release-evidence.sh`. Keep the bundle outside either source
    checkout and preload it under the dedicated runner's
    `$RUNNER_TEMP/innoflow-release-evidence-intake/<intake-name>` directory.
20. Dispatch `Release Evidence Producer` on the exact immutable tag with the
    40-character Mulbyul SHA, the intake directory name, and explicit release
    approval. The dedicated `self-hosted`, `macOS`,
    `innoflow-release-evidence` runner checks out both exact candidates,
    reopens every local receipt and raw artifact, records the tag baseline and
    dispatch actor's approval, and uploads
    `innoflow-release-evidence-<exact-tag-SHA>`. It requires the read-only
    `MULBYUL_READ_TOKEN`; a missing runner, token, intake bundle, or approval
    leaves the release blocked.
21. After that producer run has completed successfully, dispatch the tag's
    `Release Gate` with the producer GitHub Actions run ID that
    owns artifact `innoflow-release-evidence-<exact-tag-SHA>`. A plain tag push
    intentionally cannot publish. The evidence job downloads that immutable
    artifact outside both source checkouts, verifies its live GitHub run and
    artifact digest, records the independent `remote-ci` receipt, and verifies
    all local-preflight and pre-publication rows against both exact component
    SHAs. It is the sole prerequisite of the publication job.

The evidence manifest cannot define its own required set. The versioned JSON
policy does, and verification rejects missing, duplicate, unknown, failed,
skipped, blocked, stale-candidate, path-escaping, symlinked, empty, or
digest-mismatched inputs. XCTest receipts retain the raw xcresult and require
`Passed`, the policy's test-count range and expected test identity, zero failed,
skipped, or expected-failure tests, and zero runtime warnings. Manual
attestations require the expected environment, reviewer, UTC observation time,
and a hashed non-empty artifact; generating a receipt is not a substitute for
performing the manual check.

Evidence policy v3 is intentionally fail-closed and is not compatible with v2
receipts. V3 requires an automated check to declare its repository component
and structured command contract, validates both before execution, binds the
candidate digest before and after execution, and records execution metadata in
a v3 receipt. Every invocation also appends a distinct PASS, FAIL, BLOCKED, or
INTERRUPTED diagnostic receipt to `attempts.tsv`; the canonical manifest points
only to a PASS receipt, and verification reopens the corresponding PASS attempt
plus every indexed attempt artifact. Artifact and receipt paths are single-use
so a retry cannot overwrite the first failure. Regenerate the candidate
snapshot and every receipt after a v2 policy or receipt is encountered; do not
relabel or migrate prior evidence.

Swift Testing checks use `swift-test-output`, not process exit alone. The
verifier requires a nonzero passed summary, matching leaf-test and suite counts,
the exact policy count range, every required suite, and no failed, skipped, or
signal-terminated run anywhere in the log. XCTest commands must write exactly
one previously nonexistent result bundle through `-resultBundlePath` (or the
accessibility runner's `--result-bundle-path`) matching `--raw-artifact`; an old
xcresult cannot be attached to a new successful command.
The policy also requires separate iPhone, iPad, and Mac VoiceOver observations,
two Records Reduce Motion runs, and a Mac narrow-window observation.

The producer does not manufacture cross-repository Mulbyul, actual VoiceOver,
or other local evidence. Those observations and raw results must already exist
in its candidate-bound intake bundle. The producer adds only the exact-tag
baseline and explicit dispatch approval. The later tag workflow adds only the
independent GitHub producer-run verification; it cannot verify its own pending
conclusion. If any required row, trusted runner, exact checkout, run ID, or
unexpired artifact is unavailable, release publication remains blocked rather
than silently reducing the policy.

Before any Mulbyul UI evidence run, regenerate the authoritative Apple
workspace with `make sync` from Mulbyul's `Apple/` directory. The accessibility
runner verifies that every current `Sources/InnoFlowMacros/*.swift` file is
present in the generated `InnoFlow.xcodeproj` and fails before building when the
project is missing or stale. A previously generated project is not valid
consumer evidence for a changed macro source set.

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

`Tools/generate-docc.sh` injects `swift-docc-plugin` 1.5.0 at revision
`647c708be89f834fa6a6d4945442793a77ddf5b6` into a temporary package copy.
`Tools/docc-package.resolved` also pins its executable SymbolKit dependency and
the repository's SwiftSyntax dependency. Automatic resolution is disabled for
every documentation command. This keeps the tools out of the consumer graph
while making local, Pages, and release-artifact generation execute the same
immutable documentation tool graph.

Upgrade any version, revision, or lockfile pin only in an intentional documentation-tooling change
that regenerates the combined `InnoFlowCore` / `InnoFlow` site and the nested
`InnoFlowTesting` reference with warnings treated as errors. Update this policy
and the changelog in the same commit.

## Automated Release Artifacts

The release workflow publishes these assets to the GitHub Release:

- packaged DocC archive

If artifact naming or release-note sourcing changes, update this document and [CHANGELOG.md](CHANGELOG.md) in the same release.
