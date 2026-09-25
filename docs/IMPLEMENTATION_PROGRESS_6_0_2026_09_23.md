# InnoFlow 6.0.0 local implementation progress — 2026-09-23

This is an execution log for [PRE_RELEASE_EXECUTION_PLAN_6_0.md](PRE_RELEASE_EXECUTION_PLAN_6_0.md),
not a release-readiness claim. Baseline: `release/6.0.0-local` at
`dbd6cfec40e302fc03ac9f8f35ff810d30d48014`. The working tree already
contained unrelated and prior in-progress changes; this log does not treat
them as newly verified. No commit, push, public tag, or GitHub Release was made.

| Work item | Current state | Fresh evidence and remaining gate |
| --- | --- | --- |
| R68 selector identity | Focused Debug/Release and Swift 6.3/6.4 full tests passed; final evidence pending | Owner delegated the correctness choice. Keyless closures now have independent handles; explicit semantic `id:` weakly reuses live handles; key-path cache stays stable. Same-callsite captured-input, memoized/variadic, identity, and weak-cache tests passed in 74/74 focused Debug and 74/74 focused Release suites; a later Release run covering selection plus instrumentation passed 104/104 tests. The 31-test compile-contract suite now also runs an external public macro consumer executable that checks separated captures, live ID reuse, independent state updates, and parent release; it passed under Swift 6.3 and 6.4 full suites. Comparable performance measurement and final candidate matrix remain. |
| R69 parent lifetime | Focused Debug/Release and Swift 6.3/6.4 full tests passed; final evidence pending | Owner delegated the observable-lifetime choice. Root isolated deinit marks its token released, refreshes weak projection observers on MainActor, and prunes them; scoped/selected handles expose nil and notify tracked optional reads. Root/scoped/child notification and reentrant nil-read tests passed in both focused configurations. The independent macro consumer checks `optionalValue == nil` after root release. Final platform matrix remains. |
| R59 execution binding | Local SDK destination checks passed; official receipt pending | The SDK command uses a package-only workspace wrapper and fresh build xcresult. Five Xcode 27 generic SDK builds (macOS, iOS, tvOS, watchOS, visionOS) all returned `status=succeeded`, a real Build action, the matching platform, and zero errors/warnings/analyzer warnings. Raw results are `.build/r68r69-final-sdk-{macos,ios,tvos,watchos,visionos}.xcresult`. Runtime command rejects foreign package redirection. Full candidate-bound recorder verification remains. |
| R60 output parser | Current-code local output validation passed; candidate receipt pending | Reversed/repeated/missing event fixtures are rejected. Fresh strict full-suite logs under the actual Swift 6.3.3 and Swift 6.4 toolchains both contain 784 passing tests in 63 suites and produce zero parser failures. Swift 6.3 emits one run while Swift 6.4 emits two; the earlier shared two-run policy incorrectly rejected the 6.3 success and was corrected without lowering the test-count or suite requirements. The policy self-test now rejects either run-count swap. These are preserved local logs (`.build/r60-live-swift{63,64}.log`), not recorder-issued candidate-bound receipts. |
| R61 runtime inventory | Eight local runtime combinations passed; official receipt pending | Inventory pins 146 IDs, including three R68/R69 tests, by SHA-256 in all eight policy rows. After source/test edits were frozen, the runner found and executed the same 146 IDs with zero failed/skipped/runtime warnings on iOS 18.5/27.0, tvOS 18.5/27.0, watchOS 11.5/27.0 and visionOS 2.5/27.0. Raw results are `.build/r68r69-final-{ios185,ios270,tvos185,tvos270,watchos115,watchos270,visionos25,visionos270}.xcresult`. These are local source-tree checks, not immutable candidate-bound release receipts or device/UI claims. |
| R62 evidence integrity/runner | R62-A strengthened; R62-B implemented for local checks, final evidence pending | Nested normal xcresult passed recorder→verifier. Nested tamper and directory symlink were rejected. The new policy-bound `run-release-preflight.sh` plans all 28 current local IDs, serializes execution, checks clean candidate/environment, records unique attempts, independently verifies each receipt before reuse, and reports status/time/artifacts. Its fixture checks plan, execute, resume, failed-attempt retry, concurrent lock, signal interruption/retry, low disk, artifact tamper, changed candidate and dirty-candidate rejection. File-descriptor reads now reject file replacement during hashing and recorder/verifier rehash after semantic validation; deterministic in-validation mutation controls pass. A complete real-candidate run has not been demonstrated. |
| R63 API/migration | Focused external consumer and preliminary four-product symbol inventory produced; review/semantics pending | A fresh `swift package diagnose-api-breaking-changes 5.1.1 --products InnoFlow InnoFlowCore InnoFlowSwiftUI InnoFlowTesting` exited 1 and produced per-product counts 0/203/1/21. The 39 additional Core diagnostics were classified as 38 selector signature changes and one package-only enum case. A separate SwiftPM consumer built and ran against an archive of exact annotated `5.1.1` (commit `00a73ed2d2cb94114b0be5c9fbd59c187a4b67c7`) and the current candidate, comparing counter/selection results; the 6.0 variant additionally checked independent closure captures and same-callsite semantic ID reuse. Fresh public-only symbol graphs for all four products were compared in `.build/r63-public-api-inventory.json`: baseline→candidate own declarations 3→4, 380→510, 9→10, 75→108, with added/removed/changed classified mechanically, not yet owner-reviewed. Both versions now pass equivalent effect completion/cancellation and scoped parent-lifetime checks; the 6.0-only typed-output capture passes. Final owner review and frozen-candidate inventory remain. |
| R64 docs/sample | F7 focused fix, sample package/build and DocC generation passed; inventory/UI remain | The actual mutable `@Observable` guidance snippet typechecks under strict Swift 6 with MainActor isolation; removing it fails as expected. A first full principle run passed its 1,569 tests but failed the sample Xcode build because shared DerivedData supplied SwiftSyntax prebuilts for compiler 6.4.0.33.1 to the installed 6.4.0.34.1 compiler. A fresh isolated DerivedData build selected the matching 6.4.0.34.1 modules and passed. The sample gate now uses a new DerivedData directory per attempt; its direct rerun and a new complete principle run passed. Fresh DocC generation produced combined InnoFlow and nested InnoFlowTesting archives with no warning/error lines (`.build/r64-docc-20260924.log`). The reproducible Swift-fence inventory is `.build/r64-swift-block-inventory.json`: 129 blocks in 22 Markdown/DocC files, all explicitly marked unreviewed. Classification and block-by-block compilation are not complete. The Swift 6.3 command-line sample gate passes 43 tests with preview declarations excluded only because that SDK lacks PreviewsMacros; the unflagged Xcode 27 iOS sample build also passes. Actual UI behavior and block review remain. |
| R65 verify-only publishing | Local guard and pre-tag/tag metadata lifecycle implemented; remote validation pending | `publish_release` defaults false; only an explicit tag dispatch with successful release evidence enters the publication job. The frozen 6.0.0 candidate keeps `STABLE_VERSION=5.1.1`; tag enforcement requires the exact tag at HEAD and the prior stable marker to remain older than the target. The 5.1.1→6.0 migration consumer runs in local evidence, PR CI and the tag Release Gate. Lifecycle fixtures reject missing/wrong tag and premature stable promotion; workflow mutation tests and actionlint pass. The published-stable marker is promoted on the development branch only after public release, without rewriting the tag. Actual remote tag/producer/protection and post-publication transition have not run. |
| R66/R67 final evidence/remote | Pending | Clean immutable candidate, full local matrix and separate public-tag authorization remain. A 2026-09-24 read-only GitHub CLI inspection under `Ethan-IS` found remote `main=00a73ed2d2cb94114b0be5c9fbd59c187a4b67c7`, `main.protected=false`, no applicable rules from `rules/branches/main`, zero repository-visible self-hosted runners, no runs for `release/6.0.0-local`, and no `6.0.0` tag or Release. The only visible active repository ruleset targets branches and its `main` name is not proof of effective protection or immutable release tags. No remote setting was changed. |

The host has Xcode 27.0/Swift 6.4. The official signed/notarized Swift 6.3.3
toolchain is installed for the current user at
`~/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain`; invoke it by
`TOOLCHAINS=org.swift.633202606251a` and verify `swift --version` (the generic
`xcrun --toolchain swift-6.3.3-RELEASE` fell back to 6.4 here). Its package
manifest build requires `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`
on this host rather than the default Xcode 27 SDK. A strict Swift 6.3 Core
build passes after independently weakly capturing `self` in `FlowTask`'s
cancellation callback. Its strict full test command passed 784 tests in 63
suites after two test-harness issues (the running bundle's module lookup and
Swift Testing import path) and four instrumentation fixtures were corrected.
The first full 6.3 attempt was not a product PASS; the final full rerun is.
The strict Swift 6.4 full command also exited zero. The
comprehensive review's matrix and explicit exclusions remain the scope
boundary. A green self-test or representative runtime does not close the
final acceptance criteria.

After the Release-focused run, `swift format lint --strict --recursive Sources Tests Examples`,
`scripts/principle-gates.sh --static`, `scripts/principle-gates-selftest.sh`,
`scripts/check-catalyst-macro-consumer.sh`, and `git diff --check` all exited
zero. The principle gate's intentionally failing negative controls are part of
its passing self-test, not production failures. These checks do not substitute
for the full, candidate-bound evidence manifest.

The first full `scripts/principle-gates.sh` attempt exited 1 at the canonical
sample Xcode build. Its log is `.build/r68r69-full-principle.log`; the shared
DerivedData contained SwiftSyntax prebuilts for an older Swift 6.4 compiler
revision. No shared cache was deleted. A fresh isolated build passed, and
`scripts/principle-gates-lib.sh` now gives the sample build an attempt-local
DerivedData path. The direct sample gate passed; then a complete rerun exited
zero with `[principle-gates] All checks passed`. Its preserved log is
`.build/r68r69-full-principle-isolated.log`, and the policy output parser
accepted 1,569 tests, 127 suites and five runs with zero failures. This fixes
a local environment-dependent gate, not the remaining candidate-bound
release-evidence work.

On 2026-09-24, `scripts/run-release-preflight-selftest.sh`, the policy catalog
checker, `scripts/check-release-evidence-policy-selftest.sh`, and the full
`scripts/principle-gates-selftest.sh` passed after adding the runner. A first
principle self-test failed because its isolated policy fixture lacked the new
runner files; the fixture was corrected and the full self-test rerun passed.
The runner has not produced an official 6.0.0 receipt from this dirty working
tree: it intentionally requires a clean isolated candidate. The policy's
28 current local checks still require document-block typecheck review and a final frozen run; this
fixture success is not R62/R66 completion evidence. Later focused self-tests
also passed interruption/retry, low-disk rejection, and stale-candidate report
cases. The migration consumer passed both external variants, `swift format
lint --strict --recursive Sources Tests Examples`, the static principle gate,
`actionlint` for CI/CD, and `git diff --check`; remote CI has not run for the
candidate.

The external migration fixture now also compiles and executes the previous
`EffectTimingRecorder.Entry` initializer through `InnoFlowTesting` test targets
against both 5.1.1 and 6.0.0. An initial attempt linked this testing-only
product into an executable and failed at runtime because Swift Testing was not
loaded in that executable context; moving the check to a test target resolved
the fixture error. The exact baseline tag object and peeled commit are pinned
in the script, and a moved-tag negative control passes. The counter/selection
consumer and testing-product checks are still focused coverage, not the
complete R63 migration semantics matrix.

The expanded migration fixture now runs all three testing-product tests on
each side; an earlier filter selected only the original initializer test and
was removed before the passing rerun. Both versions passed deterministic
effect completion and cancellation, counter state, and scoped parent release.
The candidate-only fixture consumed a typed output through dispatch capture.
The raw summary is `.build/r63-migration-semantics-final.log`. The local API
review grouped every removed identifier by owner in `docs/API_BREAKAGE_6_0.md`;
it still requires regeneration and explicit approval for the frozen candidate.

The Swift 6.3 command-line sample initially failed because the macOS 26.5
command-line SDK lacked `PreviewsMacros`, not because of a sample feature
diagnostic. A dedicated gate excludes only `#Preview` declarations through
`INNOFLOW_DISABLE_PREVIEWS`; it passed 43/43 tests in one suite with strict
warnings (`.build/r64-swift63-sample-gate.log`). A separate unflagged Xcode 27
generic iOS sample app build succeeded (`.build/r64-sample-xcode27-build.log`).
The policy now requires this Swift 6.3 sample row, raising local required IDs
to 26. A syntax-only Swift documentation check then classified 117/129 fences
as independently parseable and pinned 12 contextual/historical fragments as
explicit exceptions (`.build/r64-doc-syntax-gate.log`). This is not block
typechecking or approval, and it raised local required IDs to 27. A fresh
read-only GitHub inspection still found no effective `main`
protection and the organization runner inventory returned 403 for this token;
the dedicated producer's runner is therefore unverified, not presumed absent.

The final strict `CompileContractTests` run after adding the migration fixture
passed 31/31 tests in one suite with `-warnings-as-errors`; its public macro
consumer/source-fallback test built and ran successfully. The raw output is
`.build/r63-compile-contract-final.log`. A subsequent strict format lint,
static principle gate, the full principle-gate self-test, CI/CD `actionlint`,
and `git diff --check` exited zero.
The documentation inventory was regenerated after the README wording changes
and still contains 129 Swift blocks in 22 files, all unreviewed. These focused
checks do not complete R63 API-owner review, R64 block classification/sample
runtime checks, or R66 clean-candidate evidence.

Nine exact quick-start Swift fences from English/localized READMEs and DocC
`GettingStarted.md` compiled in five external SwiftPM targets with warnings
as errors under Xcode Swift 6.4 and the installed Swift 6.3.3 toolchain
(`.build/r64-doc-copyable.log`, `.build/r64-doc-copyable-swift63.log`).
The expanded checker added the actual README dependency-injection block as
a sixth external target. It exposed two real authoring errors: top-level
MainActor-isolated `Store` initialization and an unhandled throwing API call
inside a non-throwing effect closure. The README now creates the store in an
`@MainActor` function and maps domain failure into an action/state field.
The corrected ten-fence build passed under both Xcode Swift 6.4 and Swift
6.3.3 (`.build/r64-doc-copyable-expanded-fixed2.log`,
`.build/r64-doc-copyable-expanded-swift63.log`). The two current phase-modeling
feature blocks also compiled as external targets under both toolchains,
raising the focused coverage to 12 fences in eight targets
(`.build/r64-doc-phase-expanded.log`, `.build/r64-doc-phase-expanded-swift63.log`).
The prior 6.3 run emitted a non-fatal
SwiftPM cache `maintenance.lock` warning during concurrent resolution, not a
source diagnostic. The new required
`doc-copyable-examples` policy row and CI lint step raise the local count to
28. Its command/coverage mutation self-test, CI `actionlint`, release-sync,
and release-note extraction passed after the policy update. This is focused
typecheck evidence, not approval of the other 117 fences or live sample UI.
The checker now copies the candidate `Package.resolved` and disables automatic
dependency resolution, so future compatible SwiftSyntax releases cannot alter
this evidence silently. Both Xcode Swift 6.4 and Swift 6.3.3 then compiled all
eight targets/12 exact fences with the pinned SwiftSyntax 603.0.1
(`.build/r64-doc-phase-pinned.log`,
`.build/r64-doc-phase-pinned-swift63.log`).
An isolated clean-candidate rehearsal exposed a path-identity error in this
new document checker: SwiftPM derived `checkout` from the detached worktree
directory, while target dependencies requested `InnoFlow`. The first four
formal local receipts passed (format, diff, static principle, syntax), then
`doc-copyable-examples` failed before compilation. The failed attempt is
preserved outside the source tree under the first rehearsal evidence root.
The generated fixture now uses an explicit `InnoFlow` package name for the
path dependency. Because this changes the candidate, that evidence root must
not be reused as final proof; a new clean snapshot and evidence root are
required.

The second clean-candidate rehearsal passed the document checker and four
static receipts, then `coverage` failed when four `CompileContractTests`
external packages derived the detached folder name `checkout` instead of the
expected `InnoFlow` dependency identity. The other 712 Core tests and 68 macro
tests ran, but the suite is a failure, not a coverage PASS; its raw attempt is
preserved. The four inline manifests, the migration fixture, and the Catalyst
fixture now spell `.package(name: "InnoFlow", path: ...)` so a clean checkout
does not depend on its directory basename. The focused 31-test compile
contract rerun then passed all 31 tests in one suite with strict warnings
(`.build/r66-compile-contract-path-identity.log`); a third clean candidate
remains pending. The 5.1.1 and 6.0
migration fixture already passed after this identity change: each variant ran
three testing-product tests in two suites, and the candidate-only output,
selection, and parent-release markers matched
(`.build/r66-migration-path-identity.log`).
The Catalyst external package also passed its generic Mac Catalyst build and
the expected native-iOS unavailable diagnostic after the identity change
(`.build/r66-catalyst-path-identity.log`). Strict source format lint, the
static principle gate, release-evidence policy self-test, and
`git diff --check` passed again before the next candidate freeze.
The 6.0.0 changelog date was changed from the prematurely stated 2026-09-03
to `Unreleased`; the actual release date must be fixed before a public tag.
After the new policy row, the 28-check preflight runner self-test, static
principle gate, and complete 129-fence syntax check passed again. A fresh
source-tree full principle run then passed 1,569 tests (Debug 716+68, Release
716+68, timing 1), sample package tests, and the canonical sample build
(`.build/r64-full-after-artifact-sample.log`). This is not the clean-candidate
receipt. After the README dependency example fix landed during that run, the
static principle gate, 129-fence syntax check, release-sync, strict source
format lint, CI/CD actionlint, and `git diff --check` each passed on the
updated files.

On 2026-09-25, the R64 documentation gate expanded to 15 external SwiftPM
targets using 29 distinct exact Swift fences (30 uses) from the release
documentation, plus eight localized installation fragments. Five extracted
Swift Testing examples execute, including the contributor and README child
scope examples. The new runtime check found that the two child examples'
unqualified `.childCasePath` could not infer `ChildAction`; both now name
`ParentFeature.Action.childCasePath`, and the exact corrected blocks compile
and pass their tests under Xcode 27 and Swift 6.3.3. The sample guide's six
Swift fences are also checked: three SwiftUI typechecks on both iOS 18.5 and
26.0, the Sendable positive/negative control, contextual SwiftData typechecks on both
iOS targets, and two executed Swift Testing examples. The 129-block syntax
check reports 113 parseable and 16 pinned contextual blocks with no unexpected
failure; the complete principle-gate self-test passed after these changes.
The expanded exact-document and sample-guidance checks also passed with the
installed Swift 6.3.3 toolchain. Complete R64 block classification, sample UI
interaction evidence, and clean final-SHA preflight/CI remain open.

An actual iPhone 16 Pro/iOS 18.5 sample run then exposed a separate hub layout
defect: the translucent fixed `safeAreaInset` introduction showed scrolling
catalog text through the card. A new XCUITest reproduced it as a red assertion
that the introduction remained hittable after scrolling, while the existing
hub-to-router navigation XCUITest passed. The introduction now lives as the
first `List` row; the same two UI tests passed (2/2) on the same dedicated
simulator. The iPad 18.5 simulator installed the app but CoreSimulator's
launch/container queries stalled, so iPad visual interaction is not claimed
as passed. Post-fix iPhone screenshots and accessibility hierarchy confirm the
card scrolls away without overlapping catalog rows. Broader UI regression and
final-SHA evidence remain open. Legacy 1.0 release-note and 3.1 migration
examples now carry explicit historical/non-copyable warnings, without
reclassifying their Swift fences as current executable examples.

The release owner confirmed on 2026-09-25 that they will configure and provide
evidence for `main` protection and the dedicated release runner. This is an
ownership assignment, not verification that either remote control is active.
The same owner retains final approval of the four-product public API change
classification; no public tag or GitHub Release is authorized by the Draft PR.

A new iPhone list/detail UI test initially failed to observe the favorite
toggle changing. The failure artifact showed XCTest tapping the center of a
370-point-wide accessibility frame while the physical switch sat at its
trailing edge. A separate sample test proved the actual scoped `Binding`
updates parent and refreshed child state. Targeting the visible switch then
passed the UI flow: first-page load, article detail, favorite on, back, and
re-entry with the favorite still on. This classifies the initial failure as
an automation hit-target assumption, not a confirmed InnoFlow binding bug.
The expanded sample SwiftPM suite passes 44/44 tests on Xcode 27. The full
nine-case sample UI suite passed with no failure or skip on a dedicated
iPhone 16 Pro/iOS 18.5 simulator. iPad UI, unsupported sample deletion and
reinsertion, parent-release UI boundaries, and final-SHA evidence remain open.
