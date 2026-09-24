# Releasing InnoFlow

This document defines the minimum release quality bar for InnoFlow.

> Scope revision, 2026-09-18: the owner has removed Mulbyul-specific validation
> from InnoFlow's release checklist. Mulbyul feature/UI/accessibility/VoiceOver
> checks are out of scope, not passed or waived failures. The active pre-release
> plan is the [pre-release execution plan](docs/PRE_RELEASE_EXECUTION_PLAN_6_0.md), continuing the
> implementation history and reopened checks in [R52–R58](docs/FRAMEWORK_ONLY_REMEDIATION_PLAN_6_0.md).
> The JSON policy and release workflows now use a single InnoFlow candidate;
> retired product SHA/token/checkout/evidence inputs must not be reintroduced.
> InnoFlow's own platform, toolchain, consumer, sample, coverage, sanitizer and
> release-provenance gates remain required.

> Plan revision, 2026-09-23: the [comprehensive review](docs/COMPREHENSIVE_REVIEW_6_0_2026_09_23.md)
> adds selector correctness (R68) and a parent-lifetime contract decision (R69)
> before R59–R67; artifact integrity (F6) and sample guidance (F7) extend R62/R64.
> These are Draft remediation tasks, not completed fixes or publishing approval.
> The owner subsequently delegated D1/D2 implementation decisions; the local
> selection and lifetime changes are tracked in the [implementation log](docs/IMPLEMENTATION_PROGRESS_6_0_2026_09_23.md).
> Focused tests do not replace the final candidate-bound platform matrix.

> Local implementation boundary: the Release Gate now has a
> `publish_release=false` default and requires an explicit true dispatch to
> enter the GitHub Release job. This code has not yet been published or proven
> against the final remote candidate; do not treat the local workflow check as
> publication approval.
> A public `6.0.0` Git tag itself exposes the version to SPM consumers and
> requires authorization separate from evidence review or GitHub Release publication.

Current stable public release: `5.1.1` (at 6.0.0 candidate freeze; tagged and
published on GitHub Releases, 2026-08-26)

Release target: `6.0.0` (verify live tag/Release status on GitHub)

The `release/6.0.0-local` branch carries the staged 6.0.0 contract.
Installation snippets and non-tag release metadata are aligned with that
candidate. A frozen tagged source snapshot keeps the prior published-stable
marker; tag creation and GitHub Release publication remain separate gates.

## Stable release readiness

The 6.0.0 release tag must be exactly `6.0.0`; do not create or document a `v6.0.0`
tag. A release is publish-ready only after its exact tag triggers a successful
GitHub Actions `Release Gate`.

For the current development line, and again before creating the next release
tag, run and confirm:

1. Main package tests: `swift test --jobs 1 --no-parallel -Xswiftc -warnings-as-errors`
2. Release package tests: `swift test -c release --jobs 1 --no-parallel -Xswiftc -warnings-as-errors`
3. Sample package tests: `swift test --package-path Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage --jobs 1 -Xswiftc -warnings-as-errors`
   Also run the required Swift 6.3 command-line sample gate through
   `scripts/check-sample-swift63.sh --scratch-path <isolated-build-path>` with
   `TOOLCHAINS=org.swift.633202606251a` and
   `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`.
   That SDK lacks `PreviewsMacros`, so this gate excludes only preview
   declarations; the canonical Xcode sample app build must separately pass
   without the exclusion flag.
4. Macro source fallback: `swift build --disable-experimental-prebuilts --product InnoFlow --jobs 1 -Xswiftc -warnings-as-errors`
5. Macro operations contract: `scripts/check-macro-operations.sh`
6. Package builds for every declared destination: `macOS`, `iOS`, `tvOS`,
   `watchOS`, and `visionOS`, using
   `scripts/run-sdk-platform-build.sh --platform <platform> --derived-data <absolute-dir> --result-bundle <absolute-xcresult>`.
   The wrapper binds the package-only workspace and `InnoFlow-Package` scheme,
   disables code signing, and requires a fresh, clean build-result bundle.
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
    Run `scripts/check-doc-swift-syntax.rb` as a separate syntax-only check for
    every Swift fence. Its 12 pinned contextual/historical exceptions are not
    typecheck approvals; runnable and partial examples still need their
    versioned compilation/harness review before the 6.0 candidate is approved.
    `scripts/check-doc-copyable-examples.rb` additionally compiles twelve exact
    README/DocC quick-start, dependency-injection, and phase-modeling fences
    in eight external SwiftPM targets with warnings as errors. It uses the
    release candidate's `Package.resolved` without automatic version updates.
    This focused executable check does not classify or typecheck the remaining
    contextual fences.
12. Full principle gates: `scripts/principle-gates.sh`
13. Instrumented coverage and required-module inventory: `scripts/run-coverage.sh`.
    The shared CI/release workflow enforces the repository-owned
    [coverage policy](docs/contracts/coverage-policy.json), preserves the raw
    report and module summary, and fails if the candidate changes during the run.
    See [gate mapping and limits](docs/CI_GATES.md) for the InnoRouter adoption.

`STABLE_VERSION` records the public stable version at the source revision. Keep
it at `5.1.1` in the frozen 6.0.0 candidate and exact tag: promoting it before
the tag exists would make the API baseline gate require a nonexistent tag and
invalidate the candidate snapshot. The mandatory local/CI migration consumer
instead builds both the exact `5.1.1` baseline and 6.0.0 candidate, while the
reviewed four-product API inventory must classify the major breakage. After
GitHub Release publication, update `STABLE_VERSION` and the current-stable
wording on the development branch in a separate commit. Then the 6.0.0 API
baseline is mandatory; deletion or loss of that published tag fails closed.
The immutable 6.0.0 tag retains its historically accurate candidate-freeze
metadata. Override `INNOFLOW_API_BASELINE` only when intentionally opening a
new major development line.

After separate authorization to create the exact candidate tag,
release-tag enforcement must also pass:

```bash
INNOFLOW_REQUIRE_RELEASE_TAG=1 INNOFLOW_RELEASE_VERSION=6.0.0 scripts/check-release-sync.sh
```

That command intentionally requires the exact local tag `6.0.0` to point at
the checked-out commit and `STABLE_VERSION` to remain earlier than the target
in the tagged candidate. In GitHub Actions, the triggering `GITHUB_REF_NAME` is authoritative
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
16. Keep `STABLE_VERSION=5.1.1` and the dated prior-stable wording in the
    tag-creating candidate. Require the 5.1.1→6.0 external migration consumer
    and reviewed API inventory before tagging. Only after GitHub Release is
    published, promote the stable marker and current-stable wording on the
    development branch; that post-publication commit must not rewrite the
    immutable tag or reuse pre-tag receipts.
17. Confirm [SECURITY.md](SECURITY.md) lists the candidate major and every
    intentionally supported prior line; remove versions that no longer receive
    coordinated fixes.
18. Confirm the repository's server-side tag rules prevent update and deletion
    of release tags. The local and workflow checks bind the triggering tag to
    the checked-out commit, but only immutable-tag enforcement closes the gap
    between a completed gate and the later GitHub Release API call.
19. Create `candidate.json` with `scripts/release-candidate-snapshot.rb` from
    the exact InnoFlow checkout plus the single canonical
    [JSON evidence policy](docs/contracts/release-evidence-policy.json). Use
    `scripts/record-release-evidence.sh` for commands and preserved raw
    xcresult bundles, and `scripts/record-manual-release-evidence.sh` only for
    a pre-existing manual observation artifact. Verify the complete directory
    through the `local-preflight` stage with
    `scripts/verify-release-evidence.sh`. Keep the bundle outside either source
    checkout and preload it under the dedicated runner's
    `$RUNNER_TEMP/innoflow-release-evidence-intake/<intake-name>` directory.
20. Dispatch `Release Evidence Producer` on the exact immutable tag with the
    intake directory name and explicit release
    approval. The dedicated `self-hosted`, `macOS`,
    `innoflow-release-evidence` runner checks out the exact candidate,
    reopens every local receipt and raw artifact, records the tag baseline and
    dispatch actor's approval, and uploads
    `innoflow-release-evidence-<exact-tag-SHA>`. A missing runner, intake bundle,
    or approval leaves the release blocked.
21. After that producer run has completed successfully, dispatch the tag's
    `Release Gate` with the producer GitHub Actions run ID that
    owns artifact `innoflow-release-evidence-<exact-tag-SHA>`. Leave
    `publish_release` at its default `false` for a verify-only run. A plain
    tag push or a verify-only dispatch cannot create the GitHub Release,
    although pushing the public tag already exposes that version to SwiftPM
    consumers and requires separate authorization. The evidence job downloads that immutable
    artifact outside the source checkout, verifies its live GitHub run and
    artifact digest, records the independent `remote-ci` receipt, and verifies
    all local-preflight and pre-publication rows against the exact InnoFlow
    candidate. After reviewing a successful verify-only result, a separately
    authorized dispatch of the same exact tag with `publish_release=true` and
    the evidence run ID is required to enter the publication job. That job
    also requires the evidence prerequisite to succeed in its own run.

The evidence manifest cannot define its own required set. The versioned JSON
policy does, and verification rejects missing, duplicate, unknown, failed,
skipped, blocked, stale-candidate, path-escaping, symlinked, empty, or
digest-mismatched inputs. XCTest receipts retain the raw xcresult and require
`Passed`, the policy's test-count range and expected test identity, zero failed,
skipped, or expected-failure tests, and zero runtime warnings. Manual
attestations require the expected environment, reviewer, UTC observation time,
and a hashed non-empty artifact; generating a receipt is not a substitute for
performing the manual check.

For a clean isolated candidate, `scripts/run-release-preflight.sh plan
--evidence-root <outside-repository-directory>` lists the policy's required local
check IDs, their reviewed commands, and expected environments without running
them. `execute` collects them serially into a new evidence root; `resume`
reuses only independently verified receipts for the same candidate and current
toolchain, then runs missing checks. `report` distinguishes verified passes
from missing or stale attempts and prints elapsed time and artifact paths.
Use `--check-id <id>` for a focused attempt. Keep the evidence root and its
adjacent `.work` directory outside the source checkout. Failed attempts stay
in the evidence root; a modified previously recorded artifact requires a new
evidence root rather than relabeling or deleting the old receipt. The runner
does not accept a dirty candidate, create a commit or tag, import historical
logs, or substitute for the final full verifier. The required local checks
must all pass for the same frozen candidate before the pre-tag gate can close.

Evidence policy v3 is intentionally fail-closed and is not compatible with v2
receipts. V3 requires an automated check to declare its repository component
and structured command contract, validates both before execution, binds the
candidate digest before and after execution, and records execution metadata in
a v3 receipt. Automated receipts record the logical component path (`.` for
InnoFlow), and root SwiftPM/SDK checks reject package, project, or workspace
redirection to a different input. Every invocation also appends a distinct PASS, FAIL, BLOCKED, or
INTERRUPTED diagnostic receipt to `attempts.tsv`; the canonical manifest points
only to a PASS receipt, and verification reopens the corresponding PASS attempt
plus every indexed attempt artifact. Artifact and receipt paths are single-use
so a retry cannot overwrite the first failure. Regenerate the candidate
snapshot and every receipt after a v2 policy or receipt is encountered; do not
relabel or migrate prior evidence.

Swift Testing checks use `swift-test-output`, not process exit alone. The
verifier requires every run, test, and suite start to have one terminal event,
each run summary to match its own leaves and suites, the exact policy count
range, every required suite and test name, and no failed, skipped, cancelled,
or signal-terminated run anywhere in the log. XCTest commands must write exactly
one previously nonexistent result bundle through `-resultBundlePath` (or the
accessibility runner's `--result-bundle-path`) matching `--raw-artifact`; an old
xcresult cannot be attached to a new successful command.

The producer does not manufacture local evidence. Required command results and
raw artifacts must already exist in its candidate-bound intake bundle. The
producer adds only the exact-tag baseline and explicit dispatch approval. The
later tag workflow adds only the independent GitHub producer-run verification;
it cannot verify its own pending conclusion. If any required row, trusted
runner, exact checkout, run ID, or unexpired artifact is unavailable, release
publication remains blocked rather than silently reducing the policy.

## GitHub Release Notes

The tag-triggered `Release Gate` runs the principle gate with release-tag enforcement, but a tag push does not create a GitHub Release. After the exact-tag evidence producer and a verify-only Release Gate run have passed, a separately approved `workflow_dispatch` with `publish_release=true` may create the GitHub Release. That publishing job uses the matching section of [CHANGELOG.md](CHANGELOG.md) as its release body.

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
