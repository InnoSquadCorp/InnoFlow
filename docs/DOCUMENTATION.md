# InnoFlow documentation

## Version and publication boundaries

The current published release is [6.0.2](https://github.com/InnoSquadCorp/InnoFlow/releases/tag/6.0.2),
published 2026-10-08 from `1176de1e4783b638c03a9334f43cc49378957148`.
At the 2026-10-10 PR #63 refresh, production files under `Sources/` are identical
to that tag. Later development commits change CI, test partitioning, tooling,
skill validation and documentation; they are not another published release.
`STABLE_VERSION` records 6.0.2 in development. Its prior-stable value in the
immutable tag is candidate provenance, not today's release state.

For an installed version, inspect `Package.resolved` and that exact tag's
manifest/source. Hosted DocC follows the deployed revision and may describe
later development documentation. Git tags 6.0.0 and 6.0.1 remain accessible to
SwiftPM but their GitHub Release publication did not complete; do not call those
attempts published GitHub Releases. [Release history](../RELEASE_NOTES.md) and
[release procedure](../RELEASING.md) preserve that distinction.

## Entry points

[English](../README.md) | [한국어](../README.ko.md) | [Español](../README.es.md) |
[Deutsch](../README.de.md) | [简体中文](../README.zh-Hans.md) | [日本語](../README.ja.md) |
[Русский](../README.ru.md)

All seven READMEs contain equivalent current entry guidance and identical Swift
examples. Detailed guides remain in English. The old `.kr`, `.jp` and `.cn`
filenames are compatibility landing pages; translations at old tags remain
historical. Structural/identifier parity does not certify native editorial
quality; changes still need a language review.

## Maintained guides

| Need | Guide |
| --- | --- |
| Complete authoring/composition/effect/selection examples | [User guide](USER_GUIDE.md) |
| Learning and runnable local sample | [Examples](../Examples/README.md), [setup](../Examples/SETUP_GUIDE.md), [ten demos](../Examples/InnoFlowSampleApp/README.md) |
| Domain phases and topology | [Phase modeling](../PHASE_DRIVEN_MODELING.md), [DocC walkthrough](../Sources/InnoFlow/InnoFlow.docc/PhaseDrivenWalkthrough.md) |
| Constructor dependencies and app ownership | [Dependency patterns](DEPENDENCY_PATTERNS.md), [cross-framework guide](CROSS_FRAMEWORK.md), [advanced authoring](ADVANCED_AUTHORING.md) |
| Lifetimes, scheduling, operation isolation | [Optional child lifetime](OPTIONAL_CHILD_LIFETIME.md), [admission](SCHEDULER_ADMISSION_CONTRACT.md), [run snapshots](RUN_LANE_SNAPSHOTS.md), [isolation](EFFECT_OPERATION_ISOLATION.md) |
| SwiftUI and diagnostics | [SwiftUI DX](SWIFTUI_DX_6_0.md), [instrumentation](INSTRUMENTATION_COOKBOOK.md) |
| 5.x→6.0 migration and prior draft corrections | [Migration](../MIGRATION.md), [migration tool](../Tools/innoflow-migrate/README.md), [API classification](API_BREAKAGE_6_0.md), [API decisions](PUBLIC_API_FREEZE_6_0.md) |
| AI-assisted consumers | [Library skill](../skills/README.md), [exact-version validation](../skills/validation.md) |
| Toolchains and compiler plugins | [Macro operations](MACRO_OPERATIONS.md), [toolchain tracking](SWIFT_TOOLCHAIN_TRACKING.md), [SPI](SWIFT_PACKAGE_INDEX.md) |
| Current CI, contribution and release rules | [CI gates](CI_GATES.md), [selective targets](CI_SELECTIVE_TEST_TARGETS.md), [automation](automation-policy.md), [contributing](../CONTRIBUTING.md), [release procedure](../RELEASING.md) |
| Architecture and stewardship | [Contract](../ARCHITECTURE_CONTRACT.md), [rules](../CLAUDE.md), [governance](../GOVERNANCE.md), [support](../SUPPORT.md), [security](../SECURITY.md) |
| Benchmarks and comparisons | [Benchmark methodology](../Benchmarks/README.md), [performance policy](PERFORMANCE_BASELINES.md), [framework positioning](FRAMEWORK_COMPARISON.md) |

## Validation claims

The [fence inventory checker](../scripts/report-doc-fence-review.rb) binds every
Swift fence to its digest and executable checker in the
[review ledger](contracts/doc-swift-fence-review.tsv). Complete declarations are
compiled; contextual fragments are compiled within explicit app-model/wrapper
contexts. Installation fragments are parsed in complete manifests. Versioned
historical fragments remain non-copyable. Syntax parsing alone is not a
consumer typecheck, runtime result or final-SHA release receipt.

Run `scripts/check-doc-links.py` for local file/heading links,
`scripts/check-doc-parity.sh` for seven-language structure, code, navigation and
critical identifiers, `scripts/check-doc-swift-syntax.rb` for syntax, and
`scripts/check-doc-copyable-examples.rb` for compilation and named tests.
External URL reachability, native translation quality and device UI behavior
need separate checks. The skill uses an exact remote 6.0.2 fixture, while the
sample and documentation harness use the current local checkout.

The release policy has 28 required checks, including four OS 27 runtimes,
and four optional legacy iOS 18.5/tvOS 18.5/watchOS 11.5/visionOS 2.5 runtime
checks that are not automatic. Minimum deployment support remains iOS 18,
macOS 15, tvOS 18, watchOS 11 and visionOS 2. Full release validation is CI-only;
focused local checks are not release certification.

## Historical evidence

Dated implementation/status/ledger, review, remediation and release-planning
records preserve the claims made at their recorded revision. Their historical
32-check policy, pending publication, test counts, local paths and unresolved
boundaries do not override current rules or prove a later commit passed.
In particular [implementation status](IMPLEMENTATION_STATUS_6_0.md) is a
2026-10-03/04 snapshot, not current publication status. The current review
method is in [the review guide](REVIEW_GUIDE_6_0.md); accepted decisions are
retained under [ADR records](adr).

Links to absent local build receipts or other repositories are presented as
unavailable historical artifact paths rather than navigable repository files.
Exact old SHAs, dates, failure results and artifact path text are preserved.
This documentation refresh does not revalidate those old receipts or rewrite
immutable tags. See [the refresh audit](DOCUMENTATION_AUDIT_2026_10_10.md).
