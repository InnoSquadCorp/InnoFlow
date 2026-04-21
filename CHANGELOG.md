# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
adapted for the release workflow in [RELEASING.md](RELEASING.md).

## [Unreleased]

### Fixed

- `swift build -c release` now succeeds on the current Swift 6.3 toolchain. The SIL `EarlyPerfInliner` previously segfaulted in `isCallerAndCalleeLayoutConstraintsCompatible` while scanning `Store.deinit` and `TestStore.deinit` for inlining candidates. Both deinits are now annotated with `@_optimize(none)`, which sidesteps the crash without changing `@MainActor isolated deinit` semantics or the public API. Deinit is not a hot path, so the localized optimization loss is negligible. Upstream tracker: [swiftlang/swift#88173](https://github.com/swiftlang/swift/issues/88173) (and adjacent #87077 / #87736 / #87462). A minimal in-tree reproducer lives at `Repro/SILCrashRepro/` with the full crash dump in `Repro/SILCrashRepro/CRASH.txt`; retest on toolchain bumps to retire the workaround.
- `swift test -c release` now passes the full InnoFlow test suite (212 tests). Five crash-contract subprocess tests (`StaleScope*CrashContractTests`, `PhaseMap*CrashContractTests`) previously failed in release because `runStaleScopedStoreHarness` and `runPhaseMapCrashHarness` linked against enumerated `.build/**/InnoFlow.build/*.o` object files — which pulls in whichever configuration happened to be in `.build/`. When the outer runner was invoked with `-c release`, the harness picked up release-optimized objects where `assertionFailure` had been elided, so the subprocess could not abort and the crash contract could not be verified. Both harnesses now inline-compile InnoFlow sources with `-Onone` + `-package-name InnoFlow` via the existing `innoFlowCoreSourcePaths` helper, matching the pattern already used by the release-harness counterparts and removing any dependency on the outer test-runner's build configuration.
- Five timing-sensitive tests (`effectContextUsesStoreClock`, `effectContextCheckCancellationPassesWhileActive`, `effectContextCheckCancellationThrowsAfterCancelEffects`, `storeCombinatorComposition`, and `manualTestClockResumesSameDeadlineSleepersInInsertionOrder`) previously asserted state after a fixed number of `await Task.yield()` calls. That count was sufficient in debug but not in release — release-mode WMO eliminates some scheduling boundaries, and the remaining actor hops inside `Store.executeEffect → Task { walker.walk → driver.startRun → inner Task { gate.wait }}` still need scheduler turns. The tests now poll for the observable outcome (e.g., `store.throttled == [1]`, `await probe.started == 1`, `await clock.sleeperCount == N`), which is the idiomatic pattern for async-effect tests and was already used for the `_completed` probe flows elsewhere in the suite. The `Store.send(_:)` scheduling contract is now documented in `ARCHITECTURE_CONTRACT.md` under "Store.send(_:) scheduling contract".

### Added

- `EffectTimingRecorder` (`InnoFlowTesting`) — a test-only actor that captures `StoreInstrumentation` events (run lifecycle, action emission, cancellation) with monotonic nanosecond timestamps. Pass `recorder.instrumentation()` to `Store(reducer:..., instrumentation:)` to record a run; `recorder.entries()` returns the captured timeline and `recorder.dumpJSONL(to:)` serialises it as newline-delimited JSON for offline comparison. Timestamps are captured synchronously inside each instrumentation callback (not inside the async append hop) so measured run durations stay faithful to the `Store` event order even under scheduler contention.
- `scripts/compare-effect-timings.sh` — relative p95 / mean comparison between a baseline JSONL and a fresh recorder dump. Fails with a structured JSON regression payload on stderr when the current run exceeds the configured tolerance. Pure `bash` + `jq`.
- `Tests/InnoFlowTests/Fixtures/EffectTimings.baseline.jsonl` — committed baseline distribution (10 matched runs) that the new `EffectTimingBaselineGate` suite compares against under principle-gates' release-mode gate. The gate opts in via `INNOFLOW_CHECK_EFFECT_BASELINE=1` so local `swift test` runs remain silent while CI catches the 2026-04 class of scheduling regressions.
- `store.binding(_:to:)` — argument-label alias for `store.binding(_:send:)` that reads naturally when passing an enum case constructor, as in `store.binding(\.$step, to: Feature.Action.setStep)`. The two spellings are semantically identical and both remain supported on `Store` and `ScopedStore`, but call sites must now spell `send:` or `to:` explicitly because unlabeled trailing-closure forms like `store.binding(\.$step) { ... }` are ambiguous once both overloads are in scope.
- `ManualTestClock.sleeperCount` — test-only observable for the number of sleepers currently suspended on the clock. Tests that need to confirm `.run` / `.debounce` / `.throttle` effects have reached their `try await clock.sleep(...)` registration before calling `advance(by:)` can poll this instead of relying on a fixed yield count.
- Four new canonical sample demos in `Examples/InnoFlowSampleApp` covering the domains flagged as missing by the competitive analysis:
  - `AuthenticationFlowDemo` — multi-step credentials + MFA flow modeled with `PhaseMap` (idle → credentials → submitting → mfaRequired → submittingMFA → authenticated / failed) plus a `.cancellable("auth-submit", cancelInFlight: true)` effect for cancel-and-retry.
  - `ListDetailPaginationDemo` — paginated list + per-row child reducer + detail scope. Uses `ForEachReducer(state:action:reducer:)` for row state, `scope(collection:action:)` for list rendering, and `Action.articleActionPath` for the generated collection action path. Intentionally phase-light to contrast `AuthenticationFlowDemo`.
  - `OfflineFirstDemo` — optimistic local update + debounced save + server-side rollback. Uses `.cancellable("offline-save-debounce", cancelInFlight: true)` to collapse consecutive edits and `_saveConfirmed` / `_saveRolledBack(previous:reason:)` actions to reconcile with repository truth.
  - `RealtimeStreamDemo` — looping `.run` subscription driven by the injected `tickInterval: Duration` dependency and `context.sleep`. Tests swap in `ManualTestClock` to advance time deterministically and poll `sleeperCount` instead of sleeping on wall clock.
- Ten new `@Test` cases in `InnoFlowSampleAppFeatureTests` that exercise each new sample through `TestStore` — happy paths, failure / retry paths, collection-scoped row actions, debounced-save confirmation vs. rollback, and clock-driven tick receipts.

### Changed

- Sample app, DocC walkthrough, `.cursor` authoring rules, README, and `CLAUDE.md` now document the new `store.binding(_:to:)` alias when forwarding an enum case constructor. `store.binding(\.$step, to: Feature.Action.setStep)` is the recommended form, `send:` remains supported indefinitely, and binding calls must now keep an explicit `send:` or `to:` label because unlabeled trailing-closure forms are ambiguous once both overloads are available.
- `ScopedStore` and `SelectedStore` now survive the SwiftUI observer / parent-store-release race without aborting release builds. When a projection is read or written after its parent `Store` has been released (or the projection has been marked inactive), reads return the last valid cached snapshot and writes become silent no-ops. Debug builds surface both cases through `assertionFailure` so the race stays immediately visible in development. Programming errors that are not lifecycle races — state resolver returning `nil` at init, or `Identifiable.id` type mismatch — still trap. The new contract is documented in `ARCHITECTURE_CONTRACT.md` under "Projection lifecycle contract".
- `ReducerBuilder` now preserves composed reducer structure through the full builder chain instead of collapsing every step into nested closure composition. Public authoring (`CombineReducers { … }` with `Reduce`, `Scope`, `IfLet`, `IfCaseLet`, `ForEachReducer`) is unchanged. Construction-side benchmarks (debug build) show −29%/−34%/−40% at N=2/8/32; dispatch-side benchmarks show modest −3 to −5% gains in debug and are expected to improve further in release builds where `@inlinable` unlocks specialization across the builder boundary.

### Internal

- `@InnoFlow` now emits a Fix-It-backed warning when a feature's `State` declares `@BindableField var <name>` but the associated `Action` enum has no matching `case set<Name>(Value)` (or any `set*` case whose suffix matches case-insensitively, so `mfaCode` ↔ `setMFACode` is accepted). The diagnostic is strictly opt-out-safe: it never fires when `State` or `Action` is a `typealias` (for example `SampleArticleRowFeature.Action = ...`), and `case _setX(Value)` serves as an explicit escape hatch for private setters. Payload type is inferred from the literal initialiser or the explicit type annotation; without that signal, the warning is emitted without a Fix-It. Backed by four new `InnoFlowMacrosTests` cases covering positive match, acronym casing tolerance, typealiased-Action skip, and multi-field partial coverage.
- `docs/DEPENDENCY_PATTERNS.md` is now the canonical authoring guide for how construction-time `Dependencies` bundles enter reducers. The document covers the three canonical patterns (single service / composite bundle / framework-provided clock), the three test-substitution scenarios, preview conventions, the list of anti-patterns InnoFlow explicitly rejects (singletons, property-wrapper resolvers, runtime service locators), and the charter rationale for not shipping a DI container. The English README, `README.kr.md`, `README.jp.md`, `README.cn.md`, and `ARCHITECTURE_CONTRACT.md` link to it from their dependency / quick-link sections. `scripts/principle-gates.sh` now enforces that the document exists and that every README and the architecture contract link to it.
- `scripts/principle-gates.sh` now opts the release-mode test run into the `EffectTimingBaselineGate` suite via `INNOFLOW_CHECK_EFFECT_BASELINE=1`. The gate drives a probe `Store` through a fixed workload, captures the recorder's JSONL output to a temp file, and invokes `scripts/compare-effect-timings.sh` to fail on p95 regressions beyond a generous tolerance — structural regressions are caught while machine-to-machine variance and CI parallelism contention stay absorbed.
- Added a release-build regression guard to `scripts/principle-gates.sh`. The gate runs `swift build -c release` in an isolated build path so release object files cannot leak into `.build/` and pollute subprocess harness linking.
- Added a release-test regression gate to `scripts/principle-gates.sh`. The gate runs `swift test -c release` in an isolated build path so tests that pass under debug but regress under release optimization (flaky timing assumptions, harness configuration leakage, SIL inliner variants) surface in CI instead of only manual runs.
- Added release-mode subprocess tests that verify `ScopedStore.state`, `ScopedStore.send`, collection-scoped projections, and `SelectedStore.value` all fall back to cached snapshots instead of aborting after the parent store is released.
- Added `Repro/SILCrashRepro/` — a minimal, standalone SwiftPM package that reproduces the Swift 6.3 `EarlyPerfInliner` crash on a generic `@MainActor` class with an `isolated deinit` that stores result-builder-composed value types. Kept in-tree so toolchain bumps can retest whether the InnoFlow `@_optimize(none)` workaround is still required.

## [3.0.2] - 2026-03-21

### Changed

- Declared the full `swift-syntax` product set required by `InnoFlowMacros` so SwiftPM and Xcode package builds no longer emit missing macro dependency scan warnings.
- Kept the consumer-facing `InnoFlow` and `InnoFlowTesting` package surface unchanged while tightening the maintainer macro build graph.

## [3.0.1] - 2026-03-21

### Added

- `MIGRATION.md` guidance for the consumer dependency graph cleanup.

### Changed

- Removed `swift-docc-plugin` from the main consumer package graph so SwiftPM users only resolve dependencies required to build and test InnoFlow.
- Moved DocC generation to a docs-only flow that injects the DocC plugin into a temporary package during maintainer and CI documentation builds.
- Updated the release workflow to publish the matching changelog section as the GitHub Release body.
- Updated installation snippets and release governance docs for the `3.0.1` stable tag.

## [3.0.0] - 2026-03-18

### Added
- `PhaseMap` as the canonical post-reduce phase-transition layer for phase-heavy features
- `ActionMatcher` for payload-aware phase transition matching
- `PhaseMap` testing helpers that reuse `derivedGraph` with `TestStore.send/receive(..., through:)`
- `PhaseMap.validationReport(expectedTriggersByPhase:)` for opt-in trigger coverage validation in tests
- `PhaseTransition` and `PhaseTransitionGraph` for opt-in phase-driven FSM modeling
- `PhaseTransitionGraph.linear(...)` and dictionary-literal initialization for concise phase graph declarations
- `InnoFlowTesting` helpers to validate reducer actions against documented phase transitions
- `PHASE_DRIVEN_MODELING.md` as the official guide for feature-level FSM usage
- Queue-ordering contract tests for `EffectTask.send`, `EffectTask.run`, `merge`, and `concatenate`
- Direct-composition guidance for `InnoFlow` + `InnoRouter` at the app/coordinator boundary

### Changed
- `PhaseMap` now owns the declared phase key path in phase-heavy features; base reducers must stop mutating that phase directly once `.phaseMap(...)` is active
- `PhaseMap` remains partial by default at runtime; unmatched phase/action pairs stay legal no-ops and stricter coverage is opt-in
- Generated case path member names strip one leading underscore
  - `Action._loadedCasePath` → `Action.loadedCasePath`
  - `Action._failedCasePath` → `Action.failedCasePath`
- `validatePhaseTransitions(...)` remains available for backward compatibility, but `PhaseMap` is now the canonical authoring pattern for runtime phase movement
- `Store` now dispatches reducer input and effect-emitted follow-up actions through a single FIFO queue
- `EffectTask.send` follow-up actions are queued rather than reducer-reentrant
- Documentation now defines `concatenate` as declaration-ordered and `merge` as completion-ordered

### Migration Notes
- `PhaseMap` is the canonical path for phase-heavy features.
- Base reducers should stop mutating an owned phase directly once `.phaseMap(...)` is active.
- Generated case path names now strip one leading underscore.
- Prefer `CasePath`-based `On(...)` rules first, then equatable action matching, and keep `On(where:)` as an escape hatch.

## [1.0.0] - 2025-01-XX

### Added
- **Core Architecture**
  - `Store` - Observable state container with `@Observable` integration
  - `Reducer` protocol - Defines feature logic with unidirectional data flow
  - `Action`, `Mutation`, `Effect` - Core types for state management
  - `Reduce` - Result type for action processing
  
- **Swift Macros**
  - `@InnoFlow` macro - Automatically generates `Reducer` conformance and `Effect = Never` when needed
  - `@BindableField` macro - Type-safe two-way bindings for SwiftUI
  - Automatic boilerplate reduction
  
- **Binding Support**
  - `@BindableField` for marking bindable state properties
  - `BindableProperty` wrapper type for type-safe bindings
  - `store.binding(_:send:)` method for creating SwiftUI bindings
  
- **Effect System**
  - `EffectOutput` - Supports `.none`, `.single`, and `.stream` outputs
  - Async effect handling with automatic action dispatching
  - Effect cancellation support
  
- **Testing**
  - `TestStore` - Comprehensive testing utilities
  - Action and state assertion support
  - Effect testing with action verification
  
- **Documentation**
  - Comprehensive API documentation
  - Canonical sample app (`Examples/InnoFlowSampleApp`)
  - Architecture diagrams and guides

### Features
- Built on Swift's `@Observable` for seamless SwiftUI integration
- `@dynamicMemberLookup` for convenient state access
- Thread-safe with `@MainActor`
- Automatic effect handling and action dispatching
- Type-safe bindings with `@BindableField`
- Minimal boilerplate with Swift macros
