# InnoFlow 6.0 implementation ledger

## Authorization and immutable input

The owner requested both attached plans be assessed, implemented locally in the Linux VM, verified, and committed in dependency order on 2026-10-03. No remote push, PR, merge, tag, release, GitHub security-setting change, or user-desktop use is authorized by this work.

- Baseline: `138992674025cb6faa69d224c30580e0fce63e85`, verified remote main on 2026-10-03
- Core consistency input SHA256: `4ea12d01526b0ef8bfb3b095a4b101a504cf499ea4821d3aaaae6b85c156c1be`
- Expanded input SHA256: `d3245a969aa1808b8396d982c19f111db78887e11a8afde872d68363205a546d`
- Existing checkout preserved; implementation uses an independent clone
- Plans are retained verbatim under `docs/plans/`; their historical measurements remain supplied evidence, not fresh verification

## Reconciled contracts

The stricter core-consistency lifetime rules govern overlapping D1/D2/T1/T2 and child ownership. A deinitializer must never mark uncooperative running work physically complete. Shared throttle completion is runtime-owned and per-dispatch observation removable. `perform` maps a thrown CancellationError as failure unless the authoritative cancellation boundary was accepted.

The canonical new testing handle is `TestStoreDispatch` (expanded D-6); `TestFlowTask` is a typealias for the earlier draft spelling. Both mean the same non-consuming, dispatch-specific verification contract. Statement sends remain discardable; async Void method values need an explicit adapter. The optional-child wrapper remains opt-in and must observe the complete parent reduction.

The expanded plan's absolute Apple-silicon performance targets cannot be validated on Linux. Linux runs can establish correctness and paired performance direction only. Public API recommendations remain local pre-release candidates until owner review; no tag freezes them here.

## Dependency order

1. Preserve inputs, reproduce defects and passing controls, fix baseline/verification boundary
2. D1/D2 runtime cleanup; M1/M2 identifier compile fixes
3. TestStoreDispatch, queue lease/context propagation, T1/T2 terminal semantics
4. Optional-child ownership and common host parity
5. Expanded W2 scheduler/correctness + W3 public contracts + W0 local validation tooling
6. W1 measured optimization; W4/W5 testing tools; W6 migration DX; W7 SwiftUI/Inspector; W8 concurrency
7. W9 docs/sample/consumer/inventory, full VM validation, exact local SHA and recoverable bundle
8. Explicit approval-dependent remote CI/32-check Preflight and Apple platform validation

Each implementation commit records its focused checks below. Integration checks are reopened after later edits. A PASS from an earlier SHA never certifies a later candidate.

## Evidence boundary

Linux Swift 6.4 validates a generated mirror. Product source remains unchanged by the adapter. The mirror replaces Apple OSAllocatedUnfairLock with an NSLock-only validation layer, omits Apple OSLog/signpost/SwiftUI adapter surfaces, makes Observation public in three generated host files, and adds two unknown-enum fallback branches needed by resilient prebuilt toolchain SwiftSyntax modules. Every transformed file has source and mirror hashes. The pinned SwiftSyntax SPM build and Apple lock/backend behavior remain unverified.

Fresh controls: 18 tests across ManualTestClock, cancellation scopes, and queued FlowTask admission passed. Fresh baseline failures: D1 dropped throttle handle leaks active dispatch registration; D2 direct CancellationError loses failure; T1 .off output waiting does not progress actions; T2 terminal action failure omits output. M1/M2 fail in actual Swift 6.4 macro consumers while original raw enums and ordinary-name consumers compile.

## Status dimensions

For every W0–W9 requirement, distinguish implementation, VM verification, Apple verification, and approval-dependent execution. The whole expanded plan is not complete while any required row remains unclosed.

### Current external blockers

- W0-1/W0-3 and final 32-check preflight require remote publication and GitHub-hosted Apple execution; neither has occurred here
- W0-4 release environment reviewer/tag protection changes need separate administrator/security approval
- Apple SwiftUI, Inspector rendering, notification animation, OSLog/signpost, Apple silicon latency, Swift 6.3 runtime, and Apple sanitizers are unverified in this Linux VM
- TCA comparison results require an identical supported Apple toolchain/runner; supplied numbers cannot substitute for new measurements

## Commit receipts

- S0: this ledger and immutable plans; full input read, remote baseline check, 18 controls and six baseline failures established through the stated mirror/consumer boundary

- W0-5/W0-6 local: date validation rejects Unreleased, malformed/impossible/duplicate dates and accepts a valid dated heading; Ruby 2.6 negative control and current Ruby control pass. Untagged release-sync passes. CI static job selects pinned official Ruby setup action; remote run remains pending. No release date or stable version was changed.

- S2 M1/M2: Swift 6.4 Linux macro build with warnings-as-errors, nine diagnostic test declarations, four positive and four intentionally rejected external consumers, raw-language controls, and an executable with 18 round-trip/phase preconditions pass. Actual original-source failures remain preserved separately. The pinned SwiftSyntax SPM/Apple/Swift 6.3 matrix remains unverified.

- S1 D1/D2: baseline RuntimeConsistencyTests exposed dropped-handle registration leaks and lost direct CancellationError failures with ordinary run/debounce/success/error controls. Runtime-owned completion relay and explicit result/cancellation distinction pass in the current combined Linux candidate, including 1,000-cycle resource tests. This focused commit will be rechecked with the final exact SHA; it is not Apple/release evidence.

- S3: 145 tests across 12 suites pass in the Linux mirror, including baseline T1/T2 probes, dispatch non-consumption, cancellation, exhaustive/off queue semantics, source-origin diagnostics, and 1,000-cycle cleanup. An external Core+Testing-only SPM consumer builds/runs; old async Void method assignment passes baseline typecheck and fails candidate with the intended source-break diagnostic. Positive explicit Void adapters and both handle names compile.

- S4: common Core registry, captured owners, namespaced lanes and frozen queued contexts pass Store/TestStore same-action, removal/replacement/reentry, nested/sibling/other-Store, uncooperative late-action and 1,000-cycle owner tests. The combined candidate passes 71 runtime tests plus 9 macro diagnostic declarations; later S3 integration also passes 145 tests. Core-only generic and macro typed-Output consumers typecheck. Shared-Scope reuse isolation has a focused fixture. Sources adds zero unsafe concurrency escapes. Final exact-SHA/platform checks remain open.

- W0-1 preparation: diagnostic-only legacy-runtime workflow and helper are implemented locally. Ruby syntax, action pins, workflow validation and explicit non-hosted refusal pass. No runtime was installed and no probe was dispatched. W0-2 remains blocked on real per-runtime evidence; routing pins and 32 release checks are unchanged. Publication/execution and release-environment protection still require separate authorization.

- W6-1/W6-3 and macro candidates: new baseline probes produced 33 expected issues in 12 test declarations. Final candidate macro suite passes 89 tests/9 suites with warnings-as-errors, plus actual raw/keyword/migration/Swift.Never consumers and executed reduction controls. Conditional missing Phase is now an intended diagnostic. SwiftIfConfig is an explicit dependency from the already-existing SwiftSyntax package. Exact Swift 6.3/603-floor and Apple validation remain open. Codemod draft is a separate, unverified workstream and is not included in this receipt.

- W2 C1/C2/D6 and D-2/D-4: baseline delayed-latest probes reproduced newer-work cancellation with and without pre-cancel, and serial attach probes reproduced duplicate started callbacks. Fixed public-host probes and 28 scheduler tests/2 suites pass. UInt consumer compiles; negative literal consumer fails as expected. Package scheduler lifecycle callbacks support later test-ledger integration. Final exact-SHA and Apple CI remain open.

- W4/D-5/D-9/W5-3: combined candidate passes 280 tests/31 suites, macro9 and XCTest1; final formatted reporting/ledger focused18 and XCTest1 re-pass. Four-coordinate Swift Testing and real XCTest fallback routing are exercised; Apple XCTExpectFailure/UI branches remain unverified. External Core+Testing consumer runs and direct FlowScope construction fails intentionally (baseline control compiles). Five static-gate mutation controls pass. W5 phase observation/Explorer is staged separately.

- W2 D5: bounded StoreDiagnostics ring removes per-record front shifting while retaining chronological immutable snapshots, exact discarded counts, capacity-zero behavior, and active dispatches. New capacity0/1/3/32, retained-snapshot, and concurrent-submit controls pass in the combined291-runtime/9-macro Linux run. This receipt verifies behavior; no independent speed claim is made for this change.

- W8-1/W8-3: explicit concurrent user-operation function types propagate through all runtime/testing factories and mapping paths. Combined291-runtime/9-macro tests pass. The independent warnings-as-errors consumer with NonisolatedNonsendingByDefault passes; three intended API negatives fail correctly. Enabling the flag in a separate Core-only evaluation also passes, while removing only concurrent annotations produces the expected off-main-queue precondition failure (exit132). Unsafe-source gate and its mutation selftests pass. W8-2 global flag adoption remains deferred pending the full target/platform matrix; production defaults are unchanged.

- W6-2: standalone AST codemod provides dry-run/report, explicit backed-up writes, parse/semantic blockers, and idempotence. Toolchain-host SwiftSyntax validation passes25 unit tests, filesystem/exit controls, actual original V5Consumer conversion with zero manual edits and external executable success, three preserved semantics tests, and two typed-output/legacy-effect/terminal-finish consumer tests. SwiftSyntax603/604 source builds and Swift6.3/Apple remain pending. No unsupported application code is silently certified.

- D-3 diagnostic surface: anonymous bounded lane snapshots preserve stable lane identity through latest replacement/serial promotion and report cancellation through scheduler state, the original frozen dispatch context and the attached task. The final dispatch-cancel correction passes the302-runtime/9-macro Linux integration. The public weak provider compiles in the external concurrent-operation consumer. Physical superseded work is not misrepresented as the current lane head. Apple rendering remains separate.

- W5-1/2/4: coverage records the actual chosen transition without re-running matchers/resolvers; seeded search validates fresh replay/minimization and bounded physical cleanup. Original public-API probes failed three safety controls (configuration misclassified, replay after incomplete cleanup), now all pass. First-diagnostic priority and cancelled-idle cleanup before-fail/after-pass controls also pass. A zero-budget registration race reproduced4 failures in a fixed100-process control; registration-only timeout fixes pass100 processes covering both zero and already-satisfied positive thresholds. Final combined302-runtime/39 suites (two expected known issues) plus9 macro declarations and six non-UI doc examples pass. Swift6.3 tests require explicit generic types at two multi-statement factory call sites, now recorded. Apple/full final-source certification stays open.

- Post-integration review reopened S4: two ForEach elements reused the same optional-child namespace. The preserved pre-fix302-test product fails36 new host/collection/identity/removal scenarios with102 expected probe issues, including late output after parent row removal. Collection projections and final-root-state reconciliation are being verified before final adoption; absence of failures in the earlier suite did not certify this missing boundary. Manual computed CasePath lifetime identity is also under explicit contract review rather than being merged by type alone.

- W1 equal-condition evidence: the initial512-process capture is wholly excluded because testability/linker flags differed. A separately admitted product-only build pair completed a fresh512-process cohort with matching pre/post binary hashes. Independent reimplementation reproduced all8 paired medians and10,000-resample confidence intervals; the frozen patch passes the predeclared Linux relative performance gate. This remains frozen-patch evidence, not the post-ForEach final SHA or an Apple/TCA/CPU-time claim.

- W1 implementation commit: cached observation key paths, private monotonic activity tokens with independent shared observer UUIDs, disabled-instrumentation/drain shortcuts, in-place projection registration, and process-local UInt64 DispatchID are staged separately from the subsequent collection lifetime correction. The admitted frozen pair passes the fixed relative gate and independent statistics verification. Current JSON2/archival converter and external UInt64 positive/old-API negative controls pass; the old signatures compile on preserved baseline products. This commit is an implementation step, not final-SHA/Apple release certification.

- S4 collection follow-up: distinct collection key path/element identity and final-root-state projections isolate rows and retire removed ancestors without rerunning reducers/phase matchers. Generic state forwarding preserves the no-owner fast path. Default IfCaseLet declaration coordinates keep reconstructed manual paths stable; an explicit lifetimeID separates overlapping helper declarations without changing CasePath cache identity. Old36-case failures and the100-owner growth failure are preserved. Final311-runtime/9-macro integration,60 parameter cases, four separately serialized1,000-reconstruction controls, positive/negative external initializer consumers and unsafe-source gate pass. Earlier deadline contention was separately rerun and remains documented; final platform/performance checks stay open.

- W7 local implementation: fifth Inspector product, typed alert/dialog titles, view-owned task modifiers, beginner-level catalog, Inspector sample and independent presentation consumer are prepared. Core view-dispatch and Inspector graph tests pass in the311-runtime integration. Four latest sample model tests (actual phase coverage/exploration, child close/reopen, owned versus independent cancellation) pass with warnings-as-errors through an explicitly recorded model-only Linux extraction. The original SwiftUI consumer refuses Linux rather than certifying Apple overloads/UI. Apple compile, UI and accessibility execution remain pending.

- W2 C3 / floor closure: OnChange explicitly preserves concurrent merge semantics, with both base-first and observed-first effects tested through Store and TestStore using a manual clock. Official Swift6.3.3 plus independently source-built SwiftSyntax603.0.0 and604.0.0 each pass186 selected runtime+89 complete macro declarations and four public consumers/six negative controls under warnings-as-errors. Weak capture probes remain weak Boolean closures (not lifetime-extending strong references). These floor receipts do not replace the omitted Apple/full-suite evidence.

- W9 docs/contracts: beginner material remains separate from advanced lifetime/exploration details, typed tutorial examples and API/JSON migration are explicit, and all140 Swift fences are classified (123 parseable,17 intentional contextual fragments). Six non-UI documentation tests and independent positive/negative public consumers pass on recorded sources. Final receipts are source-bound; Apple examples and five-product digester are not represented as VM passes.

- W1 tooling/trend: standalone benchmark packages and exact Linux-resolved dependency pins are committed separately from product dependencies. The non-blocking Apple workflow explicitly selects official Swift6.4.0 with signature/Gatekeeper checks; actual Apple pins/build/timing remain unverified. Trend runner selftests pass10 controls. The local comparator adds a distinct predeclared final non-regression purpose (all eight medians and95% upper bounds <=1.05), with10 synthetic and10 actual-invocation admission selftests independently passing. No final-source timing is implied by this commit.
