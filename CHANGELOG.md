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

- `ScopedStore.isAlive` / `ScopedStore.optionalState` and `SelectedStore.isAlive` / `SelectedStore.optionalValue` — explicit lifecycle accessors for the projection-lifecycle race documented in `ARCHITECTURE_CONTRACT.md`. `state` / `value` keep the existing cached-fallback contract for SwiftUI observer reads, but call sites that prefer to branch on liveness rather than rely on the cached snapshot can now consult `isAlive` (`true` while the projection is backed by a live parent and active observer state) or `optionalState` / `optionalValue` (returns `nil` in the same situations where `state` / `value` would emit a debug `assertionFailure` and a release-time cached fallback). The accessors do not change the cached-read or no-op-write semantics; they expose the same lifecycle signal in a release-tolerant form. Backed by four new `@Test` cases verifying both the live-parent and released-parent paths.
- `CONTRIBUTING.md` now documents the intentional package layout: core lives in the root `Package.swift`, the canonical sample lives in `Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage`, and the SIL inliner reproducer lives in `Repro/SILCrashRepro`. Consumers depend only on the core package, so sample- or reproducer-only changes do not invalidate consumer build caches.
- `Tests/InnoFlowTests/PhaseMapPerfTests.swift` — opt-in (`INNOFLOW_PERF_BENCHMARKS=1`) dispatch benchmark for `PhaseMap` covering small (4 phases × 3 transitions), medium (16 × 5), large (64 × 5), and worst-case (last-of-5 match in a 64-phase ring) FSM fixtures. Establishes baseline numbers so a future per-phase transition index — which would require a `Hashable` constraint on `Action` and an opt-in `PhaseMap` shape — can be evaluated against measurement instead of intuition. The `PhaseMap` doc comment now records the per-action complexity (`O(1)` phase lookup + linear walk over the matched phase's transitions) and explains why the index work is intentionally deferred until real workloads demand it.
- `StoreInstrumentation.signpost(signposter:name:includeActions:)` — new instrumentation factory that bridges store run lifecycle to `OSSignposter`. Each `runStarted` event opens an Instruments interval signpost identified by the run's UUID token, the matching `runFinished` event closes it, and action emissions / drops / cancellations are surfaced as `emitEvent` signposts on the same name so they appear inline in Instruments' timeline. Pairs cleanly with `.osLog(logger:)` through `.combined(...)`. Backed by a new `@Test` case verifying that signpost-instrumented stores preserve runtime behavior on the canonical async load path. `ARCHITECTURE_CONTRACT.md` lists `.signpost` alongside `.sink` / `.osLog` / `.combined` as official instrumentation surfaces.
- `Store.select(dependingOnAll:)` — Swift parameter-pack-based selection that declares an arbitrary number of explicit dependency key paths and projects them into a derived value. Lifts the previous six-field ceiling on `select(dependingOn:)` for projections that legitimately depend on more state slices, without forcing the closure-only `select(_:)` form's `.alwaysRefresh` re-evaluation on every parent action. Uses a distinct `dependingOnAll:` argument label rather than overloading the existing `dependingOn:` so the fixed-arity tuple overloads remain unambiguous at call sites. Backed by a new `@Test` case driving an eight-field selection through tracked- and untracked-mutation paths and asserting that the projection only refreshes when a declared dependency changes.
- `@InnoFlow(phaseManaged: true)` — phase-managed variant of the macro that requires the type to provide a static `phaseMap` declaration and automatically wraps the synthesized `reduce(into:action:)` in `.phaseMap(Self.phaseMap)`. Authors no longer have to remember to call `.phaseMap(Self.phaseMap)` inside `body`; forgetting the static `phaseMap` becomes a compile-time error. A boolean marker (`phaseManaged: true`) is used instead of a `WritableKeyPath` argument because a keypath argument back into the same type would create a self-referential macro-attribute cycle; the actual phase key path lives inside the static `phaseMap` value where it belongs. Existing `@InnoFlow` (no-arg) features continue to work unchanged — they keep authoring `.phaseMap(map)` explicitly inside `body`. Backed by a new `@Test` case verifying both the auto-apply path and the no-op-on-undeclared-action contract through the synthesized reducer.
- Compile-time phase totality diagnostic for `@InnoFlow(phaseManaged: true)`. The macro now collects the case names of the nested `Phase` enum (top-level or inside `State`) and walks the static `phaseMap` getter body for `MemberAccessExprSyntax` references; any Phase case that never appears in the phaseMap surfaces a `warning` anchored on the enum case declaration. Catches the declared-but-unwired authoring hazard at compile time without changing the runtime partial-by-default contract documented in `ADR-phase-map-totality-validation.md`. The new `docs/adr/ADR-compile-time-phase-totality.md` records the analysis-vs-reachability trade-off and why graph-based reachability stays out of scope for this layer. Backed by a new `@Test` in `InnoFlowMacrosTests` that drives the diagnostic against a fixture with an `.orphan` Phase case and asserts both the warning surface and the synthesized reducer expansion.
- `docs/adr/ADR-no-builtin-di-container.md`, `docs/adr/ADR-post-reduce-vs-pre-reduce-phase.md`, `docs/adr/ADR-reducer-sendable-policy.md` — ADRs recording the trade-off analyses behind three previously-implicit framework decisions: why InnoFlow ships construction-time `Dependencies` bundles instead of a runtime resolver, why `PhaseMap` runs as a post-reduce decorator instead of a pre-reduce action filter, and why `State` / `Action` / effect payloads must be `Sendable` while the `Reducer` protocol itself does not.
- `EffectTimingRecorder` (`InnoFlowTesting`) — a test-only actor that captures `StoreInstrumentation` events (run lifecycle, action emission, cancellation) with monotonic nanosecond timestamps. Pass `recorder.instrumentation()` to `Store(reducer:..., instrumentation:)` to record a run; `recorder.entries()` returns the captured timeline and `recorder.dumpJSONL(to:)` serialises it as newline-delimited JSON for offline comparison. Timestamps are captured synchronously inside each instrumentation callback (not inside the async append hop) so measured run durations stay faithful to the `Store` event order even under scheduler contention.
- `scripts/compare-effect-timings.sh` — relative p95 / mean comparison between a baseline JSONL and a fresh recorder dump. Exit `1` means a real metric regression; exit `2` means malformed JSONL, incomplete capture, usage error, or missing dependency. Pure `bash` + `jq`.
- `scripts/report-effect-timing-trend.sh` — non-blocking trend reporter that captures a fresh JSONL (or consumes an existing capture) and prints both mean and p95 deltas against the committed baseline. Metric regressions stay non-blocking, but malformed data and capture failures now fail loudly instead of being reported as ordinary slowdowns.
- `Tests/InnoFlowTests/Fixtures/EffectTimings.baseline.jsonl` — committed baseline distribution (10 matched runs) that the new `EffectTimingBaselineGate` suite compares against under principle-gates' release-mode gate. The gate opts in via `INNOFLOW_CHECK_EFFECT_BASELINE=1` so local `swift test` runs remain silent while CI catches the 2026-04 class of scheduling regressions.
- `Tests/InnoFlowTests/Fixtures/EffectTimings.baseline.meta.json` — maintainer metadata that records the gate's fixed workload size, metric, tolerance, and refresh posture so baseline regeneration stays decision-complete when runners or toolchains change.
- `store.binding(_:to:)` — argument-label alias for `store.binding(_:send:)` that reads naturally when passing an enum case constructor, as in `store.binding(\.$step, to: Feature.Action.setStep)`. The two spellings are semantically identical and both remain supported on `Store` and `ScopedStore`, but unlabeled trailing-closure forms like `store.binding(\.$step) { ... }` are now an intentional 3.x migration break with a targeted unavailability message that points callers to `send:` or `to:`.
- `ManualTestClock.sleeperCount` — test-only observable for the number of sleepers currently suspended on the clock. Tests that need to confirm `.run` / `.debounce` / `.throttle` effects have reached their `try await clock.sleep(...)` registration before calling `advance(by:)` can poll this instead of relying on a fixed yield count.
- Four new canonical sample demos in `Examples/InnoFlowSampleApp` covering the domains flagged as missing by the competitive analysis:
  - `AuthenticationFlowDemo` — multi-step credentials + MFA flow modeled with `PhaseMap` (idle → credentials → submitting → mfaRequired → submittingMFA → authenticated / failed) plus a `.cancellable("auth-submit", cancelInFlight: true)` effect for cancel-and-retry.
  - `ListDetailPaginationDemo` — paginated list + per-row child reducer + detail scope. Uses `ForEachReducer(state:action:reducer:)` for row state, `scope(collection:action:)` for list rendering, and `Action.articleActionPath` for the generated collection action path. Intentionally phase-light to contrast `AuthenticationFlowDemo`.
  - `OfflineFirstDemo` — optimistic local update + debounced save + server-side rollback. Uses `.cancellable("offline-save-debounce", cancelInFlight: true)` to collapse consecutive edits and `_saveConfirmed` / `_saveRolledBack(previous:reason:)` actions to reconcile with repository truth.
  - `RealtimeStreamDemo` — looping `.run` subscription driven by the injected `tickInterval: Duration` dependency and `context.sleep`. Tests swap in `ManualTestClock` to advance time deterministically and poll `sleeperCount` instead of sleeping on wall clock.
- Ten new `@Test` cases in `InnoFlowSampleAppFeatureTests` that exercise each new sample through `TestStore` — happy paths, failure / retry paths, collection-scoped row actions, debounced-save confirmation vs. rollback, and clock-driven tick receipts.

### Changed

- `.github/workflows/ci.yml` now splits package tests into two parallel jobs — `Package Tests (Core)` and `Package Tests (Sample)`. Sample-only failures no longer hold up core test feedback, and platform builds depend on the core test job alone, while sample-package builds depend on the sample test job. The principle-gates job depends on both since it runs the full canonical suite.
- `scripts/principle-gates.sh` now excludes `Repro/` and any `.build-*` working directory when rsyncing the project into the canonical sample test root. The reproducer is not exercised by CI, and broader `.build-*` exclusion keeps stray release-build caches out of the staged copy used for sample-package tests.
- Sample app, DocC walkthrough, `.cursor` authoring rules, README, and `CLAUDE.md` now document the new `store.binding(_:to:)` alias when forwarding an enum case constructor. `store.binding(\.$step, to: Feature.Action.setStep)` is the recommended form, `send:` remains supported indefinitely, and unlabeled calls are now documented as an intentional 3.x migration break. Swift still reports the trailing-closure spelling as an explicit-label ambiguity, while the parenthesized unlabeled spelling surfaces a no-exact-matches call with the same label guidance.
- `ScopedStore` and `SelectedStore` now survive the SwiftUI observer / parent-store-release race without aborting release builds. When a projection is read or written after its parent `Store` has been released (or the projection has been marked inactive), reads return the last valid cached snapshot and writes become silent no-ops. Debug builds surface both cases through `assertionFailure` so the race stays immediately visible in development. Programming errors that are not lifecycle races — state resolver returning `nil` at init, or `Identifiable.id` type mismatch — still trap. The new contract is documented in `ARCHITECTURE_CONTRACT.md` under "Projection lifecycle contract".
- `ReducerBuilder` now preserves composed reducer structure through the full builder chain instead of collapsing every step into nested closure composition. Public authoring (`CombineReducers { … }` with `Reduce`, `Scope`, `IfLet`, `IfCaseLet`, `ForEachReducer`) is unchanged. Construction-side benchmarks (debug build) show −29%/−34%/−40% at N=2/8/32; dispatch-side benchmarks show modest −3 to −5% gains in debug and are expected to improve further in release builds where `@inlinable` unlocks specialization across the builder boundary.

### Internal

- `@InnoFlow` now emits a Fix-It-backed warning when a feature's `State` declares `@BindableField var <name>` but the associated `Action` enum has no matching `case set<Name>(Value)` (or any `set*` case whose suffix matches case-insensitively, so `mfaCode` ↔ `setMFACode` is accepted). The diagnostic is strictly opt-out-safe: it never fires when `State` or `Action` is a `typealias` (for example `SampleArticleRowFeature.Action = ...`), and `case _setX(Value)` serves as an explicit escape hatch for private setters. Payload type is inferred from the literal initialiser or the explicit type annotation; without that signal, the warning is emitted without a Fix-It. Backed by four new `InnoFlowMacrosTests` cases covering positive match, acronym casing tolerance, typealiased-Action skip, and multi-field partial coverage.
- `docs/DEPENDENCY_PATTERNS.md` is now the canonical authoring guide for how construction-time `Dependencies` bundles enter reducers. The document covers the three canonical patterns (single service / composite bundle / framework-provided clock), the three test-substitution scenarios, preview conventions, the list of anti-patterns InnoFlow explicitly rejects (singletons, property-wrapper resolvers, runtime service locators), and the charter rationale for not shipping a DI container. The English README, `README.kr.md`, `README.jp.md`, `README.cn.md`, and `ARCHITECTURE_CONTRACT.md` link to it from their dependency / quick-link sections. `scripts/principle-gates.sh` now enforces that the document exists and that every README and the architecture contract link to it.
- `scripts/principle-gates.sh` now opts the release-mode test run into the `EffectTimingBaselineGate` suite via `INNOFLOW_CHECK_EFFECT_BASELINE=1`. The gate drives a probe `Store` through a fixed workload, captures the recorder's JSONL output to a temp file, and invokes `scripts/compare-effect-timings.sh` to fail on mean regressions beyond a generous tolerance. That release gate is intentionally catastrophic-only; stricter timing observations now belong to `scripts/report-effect-timing-trend.sh`, which now preserves hard failures for malformed or incomplete data instead of flattening them into non-blocking regressions. Maintainers can regenerate `Tests/InnoFlowTests/Fixtures/EffectTimings.baseline.jsonl` deliberately with `INNOFLOW_WRITE_EFFECT_BASELINE=<path>`.
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
