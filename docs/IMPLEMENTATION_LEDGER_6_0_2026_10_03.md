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
