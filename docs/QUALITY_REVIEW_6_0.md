# 6.0.0 Runtime Quality Follow-up

Current decision, 2026-09-09: R25/R27/R28 are reopened after new reproduced
counterexamples. R26 requires implementation and regression-test hardening;
R30/R31 remain incomplete. Earlier PASS records below are historical evidence,
not final release readiness. See the [R32–R38 corrective plan](REMEDIATION_FOURTH_FOLLOWUP_PLAN_6_0.md)
for the current scope, acceptance criteria, and remaining gates.

Review date: 2026-09-05. Scope: the local Swift 6.0.0 release candidate,
especially dispatch lifetime, typed-output composition, and output testing.
This is not a publication approval or a claim that no further improvements exist.

## Reproduced gaps and changes

1. **Captured-output consumer cancellation did not stop its effects.**
   A cancelled `for await` task terminated its `AsyncStream`, but the dispatch
   stayed alive. The regression failed before the fix. Capture termination now
   weakly forwards cancellation to its own dispatch. Normal completion and
   broadcast unsubscription remain independent. Explicit `break` still needs
   explicit dispatch cancellation when abandoning work.
2. **Cancellation between emission and reduction still allowed mutation.**
   Deterministic tests reproduced both `.run` delivery and immediate `.send`
   chains mutating state and emitting output after cancellation. The FIFO
   reduction boundary now checks the dispatch again and reports discarded
   actions. Output delivery also checks cancellation accepted during state
   observation. Already-applied state is deliberately not rolled back.
3. **Output-free children required impossible `Never` mapping closures.**
   `promoteOutput(to:)` now adapts reducers and effect helpers only when their
   output is `Never`. Tests use actual macro-authored child/parent composition,
   scoped cancellation, and external-consumer typechecking. Negative compiler
   tests prevent silently discarding real child outputs.
4. **Valid non-equatable outputs could not be exhaustively received.**
   `TestStore.receiveOutput` now supports predicates and case paths, including
   optional `nil` payload extraction. Exact/predicate/path forms consistently
   apply exhaustivity, skipped-assertion reporting, and one total deadline.
   Invalidated buffered outputs cannot restart that deadline, and cancellation
   no longer becomes a false timeout failure.

## Regression coverage

- `ReducerOutputTests`: captured vs broadcast lifetime, cancellation before and
  during iteration, independent dispatch survival, normal completion, explicit
  early-exit cancellation, buffering, and capture/tracker ownership.
- `FlowTaskCancellationBoundaryTests`: cancellation between emission and
  reduction, cancellation during observation, state/output suppression, drop
  diagnostics, and independent dispatch survival.
- `OutputPromotionTests`: macro-first composition, effect reuse, state changes,
  and scoped child cancellation.
- `TestStoreOutputMatchingTests`: non-equatable outputs, optional payloads,
  strict ordering, all non-exhaustive overloads, warnings, total deadlines,
  invalidated buffers, and caller cancellation.
- `CompileContractTests`: public API accessibility and rejection of output
  promotion for inhabited output types.

The principle gates require these contracts, and CI's full package suites run
them rather than relying on source-pattern checks alone.

## 1-7 implementation follow-up

The ordered implementation pass added five bounded capabilities rather than a
new application-service layer:

1. Store-local run admission (`latest`, busy rejection, bounded FIFO serial)
   with one scheduler shared by Store and TestStore.
2. Lexical `FlowScope` ownership for multiple dispatch handles.
3. Root `DispatchID` propagation and opt-in bounded, payload-free diagnostics.
4. Post-reduction TestStore invariants and reusable deterministic scenarios.
5. Macro-synthesized Output case paths plus scoped root-output matching.

The implementation keeps negative serial capacity, queue overflow, busy lanes,
and live-policy conflicts as explicit rejection values. Tests cover physical
termination before serial advancement, queued cancellation, independent Stores
and lanes, same-lane descendant reentry, and dispatch-captured typed output.
The canonical orchestration sample demonstrates admission and lexical ownership.

## Mulbyul consumer pilot

Mulbyul's TrainingRecords load and Training routine save paths now consume the
local candidate through `.dropWhileRunning`. Their tests use blocking fakes to
prove that duplicate user actions start one external operation and preserve the
accepted request's visible ownership until completion. All affected no-output
feature bodies explicitly use `Reducer<State, Action, Never>`.

Settings deliberately keeps its existing revisioned FIFO persistence queue.
That mechanism carries domain snapshots, retry, and rollback behavior that a
generic admission lane does not replace. Consumer validation must continue to
cover rapid revision order and rollback before any future simplification.

## Local verification

Candidate baseline: `00a73ed2d2cb94114b0be5c9fbd59c187a4b67c7`
on `release/6.0.0-local`. The candidate remains an uncommitted working-tree
snapshot, so that baseline is not an immutable release-candidate hash. No
commit, push, tag, release, or registry publication was performed.

Toolchain: Xcode 27.0 (`27A5252f`), Apple Swift 6.4
(`swiftlang-6.4.0.33.1`), arm64 macOS 27 host. Package minimums remain iOS 18,
macOS 15, tvOS 18, watchOS 11, and visionOS 2.

| Gate | Result |
| --- | --- |
| Debug package | 700 tests / 58 suites and 64 macro tests / 5 suites passed with serial jobs and warnings as errors |
| Release package | The same 700 + 64 tests passed under optimization; the isolated timing baseline also passed |
| Sanitizers | Final full TSan and ASan runs each passed 700 + 64 tests with no sanitizer report; fresh scratch paths were `/tmp/innoflow-final-tsan.Nz9qd5` and `/tmp/innoflow-final-asan.win6Zp` |
| Sample | 43 feature tests passed; canonical sample app built |
| API comparison | `5.1.1` comparison returned the expected major-release status 1: InnoFlow 0, Core 164, SwiftUI 1, Testing 21 diagnostics |
| Release/static gates | `principle-gates-selftest.sh` and the complete `principle-gates.sh` passed; release sync, README parity, workflow pins/timeouts, macro operations, and staged API checks passed |
| Documentation | `Tools/generate-docc.sh` generated combined Core/facade and Testing archives after disambiguating the scheduled-run `concatenate` symbol link |
| SDK builds | `InnoFlow-Package` built for generic macOS, iOS, tvOS, watchOS, and visionOS destinations with unique DerivedData, one job, and signing disabled |

The generated root Xcode project does not expose `InnoFlow-Package`, so the SDK
matrix used a temporary SwiftPM mirror containing symlinks to the exact source
snapshot. This selected SwiftPM's real package workspace without moving or
editing the generated project. DerivedData paths are
`/tmp/innoflow-platform-final-{macos,ios,tvos,watchos,visionos}`.

### Runtime and consumer evidence

- iOS 27 sample UI automation completed the normal sync and Scope-owned
  refresh/sync flows. The final Scope-owned control measured 288 x 58 points,
  exceeded the 44-point touch minimum, reached 100%, and had no visible overlap
  or clipping. Evidence:
  `/tmp/innoflow-ios-runtime-qa-evidence/OrchestrationRuntimeQA3.xcresult` and
  `OrchestrationTouchTargetAndScopeQA6.xcresult` in the same directory.
- A physical rapid double-tap was not claimed: XCUITest merged `doubleTap()`
  into one activation. Deterministic scheduler tests and the Mulbyul blocking
  fakes separately prove duplicate admission, but this exact gesture remains a
  UI-automation limitation rather than fabricated evidence.
- tvOS 27, watchOS 27, and visionOS 27 each built the original package and
  passed all 46 targeted tests in 5 suites: scheduler, FlowScope, dispatch
  diagnostics, TestStore scenarios, and Output case paths. These include
  failure progression, Store release, pre-cancelled callers, nested scopes,
  captured-output early exit, scope retention, cancellation attribution,
  scenario cancellation, and escaped-keyword macro synthesis. Every platform
  reported zero build errors, test failures, or source diagnostics. Xcode
  emitted two platform-tool warnings per run while skipping App Intents metadata
  extraction from a library with no App Intents dependency. Evidence logs are
  `/tmp/innoflow-runtime-final-{tvos,watchos,visionos}.log`; result bundles are
  in the matching `/tmp/innoflow-runtime-final-*` DerivedData directories.
- The repository test bundle initially failed to compile on tvOS/watchOS because
  its popover compile assertion did not mirror the product API's platform
  condition. The test now uses the same `!tvOS && !watchOS` guard; this does not
  hide a supported API on those platforms.
- Host-only subprocess suites are enabled on macOS and explicitly skipped on
  Apple device platforms. Their shared helper conditionally compiles `Process`
  only on macOS; the device builds remain warning-free instead of excluding the
  entire test target.
- Mulbyul uses the exact local package path. Its feature-only generated workspace
  was also checked from clean DerivedData and exposed a pre-existing generation
  gap: it omitted the external `InnoBase` project required by DesignSystem. The
  authoritative `Mulbyul.xcworkspace` contains that dependency and is therefore
  the integration-test surface. TrainingRecords passed 46 tests, Training
  passed 399 tests, and Settings passed 68 tests there. Training was repeated
  on a dedicated iOS 27 simulator to remove interference from another active
  project and again passed all 399 tests. The blocking load/save tests prove
  duplicate operations do not start, while the Settings suite preserves rapid
  revision ordering and rollback. No consumer log contained an InnoFlow source
  diagnostic. TrainingRecords did report existing deprecated design-token use;
  Training's view-construction tests reported SwiftUI state-access warnings and
  an expected unsigned-test HealthKit entitlement message. Settings reported no
  warning or error. Evidence is in
  `/tmp/mulbyul-innoflow6-final-{trainingrecords,training,settings}-main/Logs/Test`;
  the isolated Training log is
  `/tmp/mulbyul-innoflow6-final-training-main-dedicated.log`.

### Final adversarial revalidation

A public-API executable independently re-ran the counterexamples that escaped
the first scheduler/scope/diagnostics/scenario pass. It now confirms that:

- replacing a `.latest` operation cancels its physical task and run-local
  context, while stale same-dispatch actions are discarded;
- concurrent `FlowScope.cancelAndFinish()` callers all wait for physical
  teardown and return with their owned handle finished;
- explicit effect-ID cancellation marks the affected dispatch, whereas the
  first uncontested `.latest` dispatch is not falsely marked cancelled; and
- caller cancellation stops a TestStore scenario before subsequent steps and
  reports the cancelled outcome rather than completed steps.

The escaped-keyword Output case is covered by the cross-platform macro test.
Final probe evidence is `/tmp/innoflow-final-probes.Pc01LN/runtime-results.txt`.

The API comparison count changed during this hardening pass from the earlier
150/1/16 snapshot to 164/1/21. The added diagnostics were classified instead of
silently retaining stale numbers. Defaulted dispatch-correlation arguments
remain source-compatible and now have external compile fixtures; scheduler
finish activity is package-only. Public exhaustive event enums are documented
as migrations in `docs/API_BREAKAGE_6_0.md`.

## Remaining release evidence

Passing library tests and SDK compilation does not establish every application's
production behavior. Before publication, still require:

- Mulbyul's actual migrated flows on its supported devices, including background
  transitions, navigation dismissal, account changes, and long-running effects.
  Its consumer-specific platform UI errors are not fixed by this library patch.
- Long-duration operational traces for memory and effect/stream ownership under
  real traffic; deterministic and sanitizer tests cover bounded scenarios.
- The canonical sample has no native tvOS, watchOS, or visionOS product surface;
  library runtime smoke does not establish remote/focus/short-session/spatial UI
  usability for an app that does not exist. A future consumer on those surfaces
  needs its own product-level acceptance run.
- The remote CI, tag/API-baseline, and public-install checks in `RELEASING.md`.
  No commit, push, tag, or registry publication is implied by this local review.

Keep further features tied to measured consumer friction. Persistence, concrete
navigation stacks, transport/session ownership, and dependency construction
remain app or sibling-framework responsibilities, not automatic additions to
InnoFlow's reducer runtime.

## 2026-09-06 F1~F7 remediation revalidation

The seven counterexamples recorded in `docs/REMEDIATION_PLAN_6_0.md` were moved
into permanent tests and fixed in order. The resulting contracts are:

- `latest` publishes replacement ownership before suspension, so stale attach
  and finish callbacks cannot orphan the current request;
- inherited cancellation IDs index scheduled requests, and cancelling a pending
  request returns capacity immediately while a running serial/drop operation
  retains its slot until physical return;
- Mulbyul TrainingRecords loading and phase are owned by the accepted request
  ID, so busy and stale results cannot replace the active owner;
- caller cancellation starts `FlowScope` teardown even while the body awaits
  unrelated work, and every return joins the same idempotent close state;
- late diagnostic events never recreate a terminated active dispatch; and
- Output case-path helpers preserve availability and recursively mirror
  `#if` / `#elseif` / `#else`, including mutually exclusive same-name cases.

The code-and-test candidate SHA-256 is
`8adca5a31632cce1d60ed74c1f51a2b215934c4bd91abf12bcec492ac99aa14c`.
It hashes InnoFlow `Sources`, `Tests`, the canonical sample package, and the two
modified Mulbyul TrainingRecords source/test files while excluding generated
build directories. The repository baseline remains
`00a73ed2d2cb94114b0be5c9fbd59c187a4b67c7` on
`release/6.0.0-local`; the candidate is still an uncommitted working tree.

### Final same-candidate gates

| Gate | Result and evidence |
| --- | --- |
| Static/contract | `swift format lint --strict --recursive Sources Tests Examples`, `git diff --check`, `principle-gates.sh --static`, and the final full `principle-gates.sh` passed. Full log: `/tmp/innoflow-principle-gates-final.log`. |
| Focused remediation | 50 runtime tests across scheduler/scope/diagnostics/Output and 1 macro expansion passed: `/tmp/innoflow-focused-after.log`. |
| Debug / Release | Each configuration passed 707 runtime tests in 58 suites plus 65 macro tests in 5 suites (772 total). Independent logs: `/tmp/innoflow-full-debug-after.log`, `/tmp/innoflow-full-release-after.log`; the full principle gate reproduced both. |
| Sanitizers | Full TSan and ASan runs each passed the same 772 tests with zero sanitizer reports: `/tmp/innoflow-tsan-after.log`, `/tmp/innoflow-asan-after.log`. |
| Sample / performance | Canonical sample package passed 43 tests (`/tmp/innoflow-sample-tests-after.log`); the full gate also passed the isolated release timing baseline and canonical sample app build. |
| Apple SDK builds | `InnoFlow-Package` built with independent DerivedData for current macOS, iOS, tvOS, watchOS, and visionOS SDKs: `/tmp/innoflow-platform-{macOS,iOS,tvOS,watchOS,visionOS}.log`. |
| Device-platform runtime | tvOS 27, watchOS 27, and visionOS 27 simulators each passed 27 targeted scheduler/scope/diagnostics/Output tests with zero failures, skips, warnings, or source changes: `/tmp/innoflow-platform-runtime-qa.1RhtMF/evidence-final-package-6/validation-summary.txt`. |
| External consumer | The package compile-contract test, including public Output availability and conditional `#elseif` branches, passed. The real Mulbyul source probe passed 20/20: `/tmp/innoflow-review-20260906.Kx33EF/consumer-after-results.txt`. |
| Mulbyul integration | The authoritative workspace passed TrainingRecords feature tests on macOS 4/4 and iOS 4/4. iPhone 17 Pro / iOS 27 UI tests passed exact seeded-row detail navigation and empty CTA navigation 2/2 with zero failures, skips, crashes, or xcresult runtime warnings: `/tmp/mulbyul-trainingrecords-ui-qa.YzXK4W/evidence`. |

### Usability findings outside the reducer remediation

The iOS functional G6 contract passed, but the broad accessibility audit is not
green. In light/ko, TrainingRecords reported five contrast findings: root
`100%`, row `01:30`, row `4/4`, detail summary `4/4`, and detail set status
`성공`. The first four measured approximately `2.998:1` or `3.238:1`; the last
token pair measured `4.567:1`, but Apple's rendered audit still classified it
as nearly passing. The detail `training.records.detail.more` button measured
`28×36pt`, below the 44pt touch target. Evidence and screenshots are in
`/tmp/mulbyul-trainingrecords-ui-qa.YzXK4W/evidence`.

These six findings predate and are independent of the TrainingRecords reducer
change: no affected color or view component file was modified in this
remediation. They are nevertheless product-quality work and prevent describing
the entire Mulbyul UI as accessibility-clean. The audit also observed a slow
cold start (spinner at 3 seconds, ready by 13 seconds) and existing build
warning debt (388 UI-build warnings and 123 feature-build warnings), although
the tested flows did not hang or crash.

### Release boundary

The local R01~R07 remediation and its functional acceptance criteria are
complete. A fully production-green release still requires fixing/retesting the
six Mulbyul accessibility findings, evaluating cold-start latency and warning
debt, remote CI, a published `6.0.0` API baseline/tag, public-install checks,
and supported minimum-OS/device coverage. No commit, push, tag, release, or
registry publication was performed.

## 2026-09-07 R08~R15 follow-up validation

The six follow-up counterexamples and the six concrete Mulbyul usability
findings above were implemented as local candidate work and moved into permanent
regression coverage. This supersedes the earlier statement that those six
accessibility findings still require implementation; it does not turn unrelated
whole-app accessibility findings into passes.

- Mulbyul TrainingRecords now owns load request IDs together with their
  `FlowTask`, restores the last confirmed presentation state on cancellation,
  rejects stale cleanup, and prevents an uncooperative predecessor from
  overlapping a replacement in its serial lane. The new focused suite passed
  8/8 on both iOS and macOS.
- Output path synthesis now models conditional branches, partial manual-helper
  coverage, conditional availability, and unavailable declarations. Its macro
  snapshot and external compile contract cover both `MANUAL_PATH` values,
  direct/conditional attributes, platform branches, and negative use.
- Scheduler diagnostics remove the exact pending request on cancellation,
  replacement, finish, and cancel-all. A regression observes queued count reach
  zero while a sibling run remains alive.
- The five reported TrainingRecords contrast pairs no longer appear in the
  light, dark, or Arabic maximum-Dynamic-Type records audits. More is at least
  44×44pt. The review additionally found and fixed the edit toolbar Save control,
  whose rendered height was 36pt, and the iPad floating-keyboard dismissal path.
  A final visual pass also found that a long Arabic session title collapsed to
  a 58pt column and expanded the list beyond 13,000pt at maximum Dynamic Type;
  accessibility sizes now stack title and status, with a permanent 160pt
  minimum readable-width assertion.
- Navigation UI acceptance passed four applicable tests on both iPhone 17 Pro
  and iPad Pro 11-inch, with two form-factor-only tests skipped on each device
  and no failures. It verifies direct detail and empty CTA navigation,
  edit/save/return, set-sheet close, and rendered More/Save hit areas.

The final InnoFlow source passed focused TSan and ASan runs (45 tests / 3 suites
each, no sanitizer report) and actual SwiftPM builds for minimum macOS 15,
iOS 18, tvOS 18, watchOS 11, and visionOS 2 triples. The exact final candidate
was then subjected again to strict formatting, static contracts, macro and
compile contracts, and the complete principle gate; details and artifact paths
are recorded in `docs/REMEDIATION_FOLLOWUP_PLAN_6_0.md`.
The final cross-repository code/test candidate SHA-256 is
`69ebfde89345b4f21df0f9c16e66ebb34d3a1c38c578981542837ffeafb152d5`.

The broad Mulbyul accessibility suite is still not a whole-app green signal:
the final Arabic run passes the scoped Records reachability, RTL width, and
centered status-contrast assertions but remains red for Settings theme
reachability/dynamic-type findings; known set-detail clipped-text false positives
are recorded separately. Likewise, current local tools provide
Swift 6.4/Xcode 27.0, not an independently installed Swift 6.3 toolchain. Remote
CI, exact-SHA remote consumption, API baseline/tag, signing, and public-install
checks remain release gates. No commit, push, tag, release, or publication was
performed.

## 2026-09-08 R16~R24 second follow-up result

The second follow-up closes the newly reproduced owner-lifetime, confirmed-state
snapshot, scheduled-token diagnostics, Boolean conditional synthesis,
availability parsing, and conditional opt-out contracts in R16 through R22.
The external macro consumer passed every combination of three flags (eight of
eight) for public, package, and generic declarations. Focused TSan and ASan each
passed 67 tests in eight suites with no sanitizer report.

The current candidate also passed 53 focused runtime tests, with zero failures,
skips, or runtime warnings, on each of iOS 18.5 and 27.0, tvOS 18.5 and 27.0,
watchOS 11.5 and 27.0, and visionOS 2.5 and 27.0. The five generic SDK package
builds for macOS, iOS, tvOS, watchOS, and visionOS passed. The runtime scripts
now select the Swift Package workspace when an unrelated local Xcode project
would shadow `InnoFlow-Package`, and fall back to the older compatible Vision
Pro simulator type for visionOS 2.5.

The final full principle gate passed after all source and test changes: Debug
and Release each ran 711 runtime tests in 58 suites and 66 macro tests in five
suites, followed by the isolated release timing test, sample package tests,
canonical sample app build, and PhaseMap totality check. The reporting-only
documentation update that records those results was followed by another static
principle gate, strict format lint, and both repositories' diff checks. The
retained full log is `.build/release-evidence-r24/final-gates/principle-full.log`.

Mulbyul's authoritative workspace passed the current TrainingRecords tests on
iOS (24 selected tests) and macOS (37 whole-scheme tests). Its navigation suite
passed four applicable tests on each of iPhone and iPad; two form-factor-only
tests were intentionally skipped per device.

R23 is not green. Ten canonical iPhone/iPad accessibility configurations all
reached records root, row, detail, metrics, and the unique first set with zero
fixture/query/visibility assertion failures, but all ten system audits failed.
The unmasked raw result contains 151 issues: 76 contrast, 63 Dynamic Type, and
12 clipped-text findings. There are no hit-region or sufficient-description
findings. The target correlation mapped 106 findings and did not turn missing
target correlation into an allowed exception. One iPhone maximum-Dynamic-Type
English run also recorded an audit-infrastructure timeout. Actual VoiceOver
navigation was not performed.

This evidence supersedes the earlier claim that the five original contrast
pairs "no longer appear" as a completion statement. Some prior findings may be
system false positives, but they remain failures until independently resolved
or narrowly accepted by the owner; no automatic whitelist was added. Exact
Swift 6.3 execution, actual VoiceOver traversal, remote CI, tag/API baseline,
signing, and public-install verification also remain open. No commit, push,
tag, release, or publication was performed.

## 2026-09-09 R25~R31 third follow-up result

The third follow-up implemented a versioned release-evidence policy, atomic
receipts, artifact digest and semantic-result validation, and a fail-closed CD
dependency. Negative fixtures cover deleted or downgraded requirements,
duplicate/unknown/malformed entries, false PASS results, candidate and artifact
digest mismatches, incomplete receipts, and paths or symlinks escaping the
evidence root. The verifier self-test, principle-gate self-test, workflow
contract check, and 6.0.0 release-surface check all passed. Actual trusted
remote artifact production and publication control were not executed.

Macro synthesis now distinguishes proven-exclusive compiler predicates from
real overlap for `arch`, `targetEnvironment`, `swift`, and `compiler`, and
preserves application-extension availability on synthesized Output helpers.
Queued cancellation diagnostics retain the original dispatch ID. These paths
passed the external compile contracts and both Debug and Release full suites.

On Xcode 27.0 / Apple Swift 6.4, the current InnoFlow source produced the
following local evidence under `.build/release-evidence-r31/`:

- TSan and ASan each passed 711 Core tests in 58 suites plus 66 Macro tests in
  five suites, with no sanitizer report.
- The full principle gate passed Debug and Release with the same 711 + 66 test
  counts, the isolated release timing baseline, sample package tests, the
  canonical iOS sample app build, and PhaseMap totality enforcement.
- Generic macOS, iOS, tvOS, watchOS, and visionOS SDK builds passed in separate
  DerivedData paths. The only SDK-log warning was Xcode choosing Any Mac rather
  than Mac Catalyst for the generic macOS destination.
- iOS 18.5/27.0, tvOS 18.5/27.0, watchOS 11.5/27.0, and visionOS 2.5/27.0 each
  passed all 53 focused runtime tests with no failure, skip, expected failure,
  or xcresult runtime warning.

Mulbyul's current local TrainingRecords scheme passed 59/59 on iOS and 37/37
on macOS. The final iPhone and iPad accessibility release matrices each passed
all 12 required theme, Dynamic Type, and locale combinations. iPad frame
stability, actual failure-to-retry navigation, and split-view sidebar
hide/restore each passed three consecutive repetitions. The detailed paths and
exception boundaries are recorded in Mulbyul's `Apple/docs/TRAINING_RECORDS_QA.md`.

R30 and the overall release remain open. The audit policy contains narrowly
reproduced nil-identifier system findings, but their use as accepted exceptions
has no recorded owner approval. The generated macOS UI-test target passed
build-for-testing, while two runtime attempts failed before test discovery
because the Mac was locked and system authentication was active. Actual
VoiceOver traversal was not performed.

Mulbyul's canonical local checkout is six commits behind fetched `origin/main`.
An isolated `origin/main` 00313ffa worktree with the current Apple patch and
local InnoFlow dependency successfully generated and passed TrainingRecords
59/59 on iOS and 37/37 on macOS, plus the actual failure-to-retry UI test. Its
iPhone audit retained one cold-build timeout with no summary; the following 11
matrix scenarios passed and the exact timed-out scenario passed on a preserved
warm rerun. The latest-remote macOS UI target also built for testing, but emitted
the existing warning debt and contradictory Xcode 27 "exit code 0" diagnostics.
Latest-remote iPad and actual macOS UI runtime matrices remain unverified.

Exact Swift 6.3, trusted remote CI/evidence, tag/API baseline, signing where
applicable, publication, and public-install verification remain open. No
commit, push, tag, release, or publication was performed.

## 2026-09-10 R32~R38 fourth follow-up execution

The release-evidence contract now uses a deterministic two-repository candidate
snapshot and a single JSON policy. Receipts are validated by result profile,
allowed command, environment, candidate/policy digest, preserved artifact and,
for XCTest, the raw xcresult's discovered test identities. Replacing required
tests with unrelated tests at the same count is a permanent failing fixture.
The workflow contract tests also reject verifier echoing, relocated `needs`,
failure suppression, incomplete prerequisites, and mismatched GitHub run or
artifact provenance.

Macro output synthesis now proves the mutually exclusive simulator/Catalyst
predicate pair without removing real collisions, and copies Catalyst-specific
availability to generated helpers. The macro tests, external compile contracts,
and `scripts/check-catalyst-macro-consumer.sh` passed on Xcode 27.0
(`27A5252f`) / Apple Swift 6.4. The complete package command passed 711 runtime
tests and 68 macro tests (779 total) with warnings as errors in both Debug and
Release. The full principle gate also passed the isolated Release timing
baseline, sample package, canonical sample app, and PhaseMap totality check.
Strict format, principle/evidence/workflow/provenance/toolchain self-tests, and
both repository diff checks also passed. A clean iOS 27 focused
runtime run passed all 53 discovered tests and verified the four required suite
identities; its raw bundle is
`.build/release-evidence-r38/runtime-ios-27/result.xcresult`.
The same four suites passed 53/53 under independently built TSan and ASan
configurations with no sanitizer report; logs are
`.build/release-evidence-r38/{tsan-focused,asan-focused}.log`.
Independent clean DerivedData runs also passed 53/53 on iOS 18.5/27.0, tvOS
18.5/27.0, watchOS 11.5/27.0, and visionOS 2.5/27.0, with zero failures,
skips, expected failures, or runtime warnings and all four required suite
identities present. Generic macOS, iOS, tvOS, watchOS, and visionOS SDK builds
also passed in five isolated DerivedData roots. The macOS build emitted only
Xcode's destination-choice warning between Any Mac and Mac Catalyst; Catalyst
was verified separately by the dedicated consumer compile.

That preserved iOS DerivedData exposed an additional reproducibility defect:
the compile-contract helper selected the newest matching module anywhere under
`.build`, even when it was an iOS Simulator module for a macOS typecheck. Module
lookup now honors the explicit running-test search path first and accepts only
host-compatible modules in recursive fallback. A permanent foreign-newer-module
fixture and all 31 compile-contract tests pass while the iOS evidence remains in
place.

Mulbyul's accessibility runner now rejects missing/corrupt/zero/wrong-ID or
warning-bearing results, records raw bundles and parsed JSON, separates timeout
from build failure, restores simulator settings, terminates only its own active
build/watchdog on signal, and refuses a stale generated InnoFlow project. The
stale project was the cause of the earlier `_SwiftSyntaxCShims` pre-discovery
failure; the official `make sync` regenerated the current macro source graph.
After regeneration, iPad Pro 11-inch / iPadOS 27 passed the representative
`test_recordReleaseTargets_defaultLightKorean` run 1/1. iPhone 17 Pro / iOS 27
reached the same real UI but failed with four nil-element contrast audit issues,
two at records root and two at overall summary. Product-color experiments did
not change the findings and were reverted; no count-based exception was added.
The preserved evidence is under Mulbyul
`.build/device-check-20260910/{ipad-fresh-tuist,iphone-fresh-tuist}`.

This is not a 6.0.0 release-ready result. Exact Swift 6.3 is not installed on
this host and the wrapper correctly rejects substituting Swift 6.4. The trusted
`.github/workflows/release-evidence.yml` producer and remote run do not yet
exist. The complete 24-combination accessibility, actual VoiceOver, macOS UI
runtime, owner approval, exact tag,
publication, and independent public-install gates remain open. No commit, push,
tag, release, or publication was performed.

## 2026-09-12 R39~R45 release-blocker execution status

The release-evidence implementation now has a v3 schema, exact per-check
commands, candidate before/after validation, atomic manifests, immutable
attempt status, actual Swift Testing/XCTest identity parsing, and fresh
xcresult enforcement. Runtime and accessibility producers use those contracts.
The no-publish producer workflow checks out source before invoking repository
scripts, keeps evidence outside the checkout, and binds independent GitHub run
and artifact provenance to the candidate. Seven evidence, workflow,
provenance, snapshot, and toolchain self-test entry points pass locally. This is
local implementation proof only; no trusted remote run has been produced.

The current policy requires 68 distinct items: 44 explicit checks plus the 24
iPhone/iPad accessibility matrix rows. It keeps Swift 6.3 and 6.4, five SDK
builds, eight runtime destinations, TSan/ASan, consumer feature/navigation and
recovery, three-platform VoiceOver, macOS UI/narrow-window, remote/tag/approval,
and independent public-install evidence as separate gates. A missing
environment is BLOCKED rather than silently replaced by a weaker check.

Xcode 27.0 (`27A5252f`) / Apple Swift 6.4 passed all 779 package tests (711
runtime and 68 macro). Exact Swift 6.3 is not installed on this host. Mulbyul's
focused iPhone and iPad primary audits passed after tightening semantic target
visibility and narrowly classifying reproducible XCTest accessibility issues.
The audit runner now retries and verifies simulator setting writes and fails if
restoration cannot be confirmed. A fixture defect that saved the default
Settings theme after applying a requested dark theme was corrected, and the UI
audit now asserts the localized picker value so a light Settings screen cannot
masquerade as a dark audit. The first post-fix iPad run confirmed the rendered
dark Settings surface but exposed that XCTest reports the picker choice as a
child label and produced 36 additional dark/maximum-size contrast diagnostics.
The corrected assertion and classifier bind those diagnostics to exact visible
labels, surface, configuration, OS build, and nil-node count/signature; nearby
counterexamples remain failures. The subsequent iPhone dark run left one of
two identical identifier-less countdown-management contrast nodes unclassified;
the boundary now requires exactly those two nodes on that build, configuration,
and surface and separately verifies the Add action can be scrolled fully inside
the list. A third node or adjacent editor surface fails. Final post-change
full-matrix evidence is collected only after the candidate stops changing.

The remaining release blockers are exact Swift 6.3 execution, actual
iPhone/iPad/macOS VoiceOver traversal, macOS UI runtime and narrow-window
evidence (Developer Mode is currently disabled), a complete same-candidate
68-item manifest, trusted remote no-publish execution, owner approval, tag and
publication checks, and independent public installation. No commit, push, tag,
release, or publication was performed.
