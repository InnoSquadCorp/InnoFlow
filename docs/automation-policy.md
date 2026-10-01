# CI, dependencies, and public operations

InnoFlow follows the common InnoSquad automation interface, with its own explicit
job inventory. This is an adaptation of InnoDI's prepared coordinator and
InnoRouter's full-source path policy; their package graphs and job names are not
interchangeable. Runtime APIs and release/performance thresholds are unchanged.

## Validation and changed paths

Every CI invocation creates **CI Plan**, **CI Required**, and the existing native
**Build Documentation** check. Workflow-level path filters are deliberately absent.
The planner uses the exact event base/head and Git's NUL-delimited name/status
stream. It includes deleted paths and both old/new names of renames or copies.
Unknown paths and empty diffs select full validation; malformed input, unavailable
anchors, or Git failure fail closed. The final evaluator rejects missing,
duplicate, unknown, failed, cancelled, or unexpectedly skipped job results.

- Source, macro, test, and live example changes preserve the complete prior CI
  graph: strict Debug/Release tests, macro fallback, API baseline and previous-stable
  migration consumer, both sanitizers, coverage, static principles/negative controls,
  five platform builds, four focused runtimes, sample package/platform builds and UI
  smoke tests. DocC is part of the same required aggregate
- Main/develop pushes, manual/merge-queue validation, `release-validation`, and
  verified Dependabot PRs select the full graph. `run-asan` selects ASAN in the
  main CI plan, including later revisions. The separate ASAN entry point remains a
  manual diagnostic, avoiding a second skipped PR check with the same name
- Markdown and DocC-only changes select policy, lint/documentation consumer
  contracts and DocC. Declared individual workflow changes select their affected
  groups. Shared orchestration, manifests/locks and unclassified tooling select
  the full graph. See the executable map in `scripts/ci-policy.py`
- Selected jobs must succeed. Unselected jobs must be skipped. **Build
  Documentation** is an always-running compatibility aggregate for the existing
  protected context; it verifies the plan and the selected reusable DocC result
- Policy and planner changes are themselves tested with positive/negative fixtures.
  Matrices remain `fail-fast: false`, and no existing check uses `continue-on-error`

PR validation has read-only tokens, no release secrets, no persisted checkout
credentials, and no deployment. The metadata-only coordinator is a separate
trusted-main workflow. A successful metadata test suite is not live auto-merge
proof, Apple runtime evidence, or release readiness.

## Dependencies and lock coherence

Dependabot checks GitHub Actions every Monday at 09:00 Asia/Seoul (five open
version PRs), and Swift at 09:30 (three). Minor/patch updates are grouped as
`actions-minor-patch` and `swift-minor-patch`. SwiftSyntax is excluded from the
low-risk group using its normalized name `github.com/swiftlang/swift-syntax`.
Majors and all SwiftSyntax changes remain individual PRs and are **eligible** for
the same guarded auto-merge only after full exact-head CI succeeds.

The Swift inventory is `/` and the live consumer
`/Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage`. Historical test fixtures,
generated DocC packages and scratch consumers are intentionally excluded.
`release-validation` is requested alongside existing ecosystem labels. Missing
custom labels do not authorize reduced bot checks; identity independently selects
full validation. Creating labels is a separate owner-approved settings action.

`scripts/check-public-operations.py` requires the root, sample package, sample
Xcode workspace and DocC SwiftSyntax lock versions/revisions to agree with the
manifest's reviewed 603/604 range and DocC generator. Regenerate lockfiles with
SwiftPM from their actual manifests; do not fabricate origin hashes or loosen
frozen resolution to make CI green. A coordinated major proposal must update the
manifest range, all four locks, generator metadata, compatibility assertions and
relevant docs together while preserving Swift 6.3 primary, Swift 6.4 validation,
default/fallback build paths and existing performance contracts. Matching prebuilts
are optional availability; only artifact evidence proves their use. Additional
mandatory SwiftSyntax compatibility jobs exercise 603.0.0 on Swift 6.3 and
604.0.0 on Swift 6.4, while every prior primary job validates the committed 604
resolution. See [integration evidence](DEPENDENCY_INTEGRATION_2026_09_30.md).

## Candidate release and publication

InnoFlow retains its stronger existing release pipeline instead of replacing it
with a simpler shared template:

1. **Release Preflight** on exact main SHA runs all 32 unchanged checks in isolated
   hosted CI jobs, including pinned tvOS/watchOS runtimes
2. After separate tag authorization, **Release Evidence Producer** binds the
   exact tag/SHA to successful CI preflight and records raw artifacts/provenance
3. **Release Gate** validates exact-tag evidence and runs verify-only by default:
   `publish_release=false`. Its existing input is the Flow spelling of the common
   `publish=false` contract
4. Separate publication approval with `publish_release=true` is gated by all
   existing evidence and the `release` environment. Publication binds checkout,
   DocC artifact/checksum and a final remote tag recheck to the candidate SHA

A tag is already public SwiftPM publication, even before a GitHub Release. Do not
create tags from an unapproved candidate run. Local static/selftests are diagnostics,
never substitutes for the 32-check CI bundle. Live environment protection, repository
settings, tags and releases are not changed by this implementation. See
[RELEASING.md](../RELEASING.md).

## Documentation and OSS

Read-only reusable DocC validation is required through CI when selected. Main
publication consumes only the successful current-main CI artifact, including a
verified actual bot post-merge recovery run. A separate trusted-main API-only job
checks workflow/run/attempt/job and artifact provenance and rechecks current main
before Pages deployment. It never executes origin-run source or artifact contents
with a write token. Ordinary branch/manual CI and PRs cannot publish docs.
Standalone numeric-tag/manual Docs runs also must resolve to current main for
publication; an old tag cannot roll back the single live documentation root.

SPI configuration uses the existing external DocC site rather than promising that
SPI runs Flow's custom multi-target generator. Registration and current-version
indexing are separate facts; see [SPI policy](SWIFT_PACKAGE_INDEX.md). Existing
LICENSE, CONTRIBUTING, SECURITY and conduct policies remain in force.

## Activation is separate

On 2026-09-30 the inspected main ruleset `15900286` strictly required **CI Required**
and **Build Documentation**, pinned to GitHub Actions app `15368`, with PR review
thread resolution and no bypass actors. Auto-merge was disabled. The release-tag
ruleset `24190928` was present. Classic protection returned 403 and was not assumed
absent. This PR preserves those contexts and does not mutate settings.

See [Dependabot activation and safety contract](dependabot-auto-merge.md) for the
additional Ready context, native feature, dedicated job scopes and flag-last order.

## Ready transitions, exact caches and main proof reuse

The standardization reference is InnoDI PR #50 at commit
`ffaab38bb63ead5c2aa3374b0f7c2900ec83e9c8` (tree
`d1a8fffac0b4c889583774c5fd74a1c67abff0df`). Flow's jobs, consumers and release
contracts remain its own inventory; no DI job names or performance-history
writer are introduced.
The subsequent DI fix at `1e334b1b0f0da84bc0c9a921d0df2383541cc148` (tree
`3d95cd94ce6598e19cf9e6ca47dbee187641ad4b`) changes only history shell guards
and their portability regressions. Flow has no history writer or corresponding
bare-conditional shell guards, so that delta needs no Flow code adaptation.

`ready_for_review` is metadata eligibility only. It invokes the trusted native
**Dependabot Ready** reporter, not the heavy CI graph. Open, synchronize, reopen,
label and label removal still plan ordinary PR validation. Making a PR Ready does
not grant a CI success, invalidate an actual failure, or bypass native review rules.

Dependency caches contain only SwiftPM repository mirrors and downloaded prebuilts.
They never contain `.build` products, test results, coverage output, DerivedData,
DocC output, release evidence or reusable pass/fail verdicts. Each validation job
uses an explicit profile; platform and SwiftSyntax matrix cells also use explicit
variants. Exact keys bind the full Apple Swift/Xcode/SDK, OS-build and architecture
identities, repository manifests/resolved locks and the cache helper contract.
There are no broad restore prefixes. The SwiftSyntax matrix fingerprints only
after its audited lock version/revision has been resolved and verified. Source
fallback, compiler diagnostics, sanitizer flags, frozen sample resolution and
coverage cleanup are unchanged. A cache hit cannot skip any assertion.

Cache `restored` and `report` observations are intentionally fail-closed. A
restored-state error stops downstream validation; a report error fails its job,
including when the report runs under `always()`. Cache availability is optional,
but broken identity/observation is never silently called a successful validation.
Cache timings and hit/miss metadata are observations, not a measured speedup claim.

On a normal single-commit, same-repository squash merge to current `main`, CI may
reuse exactly six logical groups from a successful PR run:

- Package Tests (Core), including macro source fallback and all Debug contracts
- Package Tests (Release)
- Package Tests (ThreadSanitizer) and Package Tests (AddressSanitizer)
- Package Build on macOS, iOS, tvOS, watchOS and visionOS
- SwiftSyntax Compatibility on Swift 6.3/603.0.0 and Swift 6.4/604.0.0

The source must be the latest run and latest successful attempt of this exact CI
workflow and PR head, with the complete 30-job Flow inventory. Immutable tested
merge parents must equal current merge base/head, and its entire Git tree must
match the new main tree. This includes every workflow, helper and test blob.
GitHub Actions app/suite/job/check IDs, exact check URLs, repository identities,
all referenced reusable workflow SHAs and every required successful step are
verified. Prior-attempt check IDs are accepted only through exact repository-bound
check URLs. Source verification must finish before merge and be at most 24 hours
old both at admission and final revalidation. Metadata reads are bracketed by a
fresh latest-run/attempt and current-main check.

All logical plan requirements stay true. A separate, schema-checked proof changes
only those six physical execution outputs. **CI Required** repeats the complete
read-only proof after the fresh jobs finish; evidence that changes or disappears
then fails the aggregate. Before jobs skip, missing/ambiguous/stale proof, API
errors, forks, changed trees, direct/multiple/forced pushes and unsupported merge
shapes fall back to the complete original CI. Ordinary PRs, develop pushes, queue
and manual/recovery runs never obtain reuse permission.

Fresh main work always includes policy, lint and documentation consumer contracts,
coverage and its exact-SHA artifacts, API baseline/previous-stable migration,
focused runtime matrices, all sample build/test/UI work, static principles and
negative controls, both aggregates, DocC upload and current-main publication checks.
Dynamic simulator selection is deliberately not reusable. No PR artifacts are
consumed and no check conclusion is synthesized by this optimization. The 32-check
Release Preflight, tag-bound evidence producer and explicit
`publish_release=false`/publication approval contract are unchanged. Successful
PR reuse is ordinary CI evidence, never a replacement release receipt.
