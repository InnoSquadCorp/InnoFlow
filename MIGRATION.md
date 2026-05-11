# Migration Notes

This file tracks release-to-release migration guidance when behavior, defaults, or artifact contracts change in a way that users must react to.

## 4.0.0

### Who is affected

- Consumers adopting the 4.0.0 public surface before the release tag is cut.
- Consumers that directly referenced `ReducerBuilder` underscored implementation
  wrapper types instead of composing through public reducers.
- SwiftUI app targets that call `Store.binding`, `ScopedStore.binding`,
  `Store.preview`, or `EffectTask.animation(Animation?)`.
- Effects that still read `context.isCancelled` from inside `EffectTask.run`.
- Maintainers or downstream CI jobs that run the canonical sample package or
  sample app build under macro-heavy toolchains.
- Call sites that read `SelectedStore.value` directly. The accessor has been
  removed; reads now go through `optionalValue` (returns `nil` once the
  projection deactivates) or `requireAlive()` (traps when the projection
  is dead).
- Tests that asserted on the per-action `Task { @MainActor }` scheduling
  hop in `TestStore`. Action delivery now drains on the same serial queue
  as `Store.send`, so one fewer scheduling boundary exists between
  `await store.send(.x)` and the next reducer step.
- Feature authors that route collection state through
  `ForEachReducer<[Element]>` and want O(1) child lookup; the new
  `ForEachIdentifiedReducer` overload accepts an
  `IdentifiedArrayOf<Element>` and is the preferred path for hot routing
  surfaces.

### Required action

- Keep feature bodies typed as `some Reducer<State, Action>` and compose with
  public reducers (`Reduce`, `CombineReducers`, `Scope`, `IfLet`, `IfCaseLet`,
  `ForEachReducer`) instead of naming `_EmptyReducer`, `_ReducerSequence`,
  `_OptionalReducer`, `_ConditionalReducer`, or `_ArrayReducer`.
- Add the `InnoFlowSwiftUI` product dependency and `import InnoFlowSwiftUI` in
  SwiftUI targets that use binding, preview, or animation conveniences. Non-UI
  feature/domain targets can continue to depend on `InnoFlow` alone.
- Replace synchronous `context.isCancelled` checks with
  `try await context.checkCancellation()` when cancellation should abort the
  effect, or `await context.isCancellationRequested()` when a non-throwing
  probe is needed.
- `validatePhaseTransitions(tracking:through:)` now accepts an optional
  `diagnostics:` parameter (defaults to `.disabled` for source compatibility).
  Pass a non-`.disabled` `PhaseValidationDiagnostics` to surface undeclared
  transitions in release builds; the historical `assertionFailure`-only
  behavior is preserved when the parameter is omitted, but new code should
  prefer `PhaseMap` with `PhaseMapDiagnostics` for runtime-observable phase
  contracts.
- Run canonical sample package tests and sample Xcode builds serially
  (`--jobs 1` / `-jobs 1`) so CI fails on real diagnostics instead of Swift
  macro worker log corruption.
- Replace `store.value` reads with one of:
  - `store.optionalValue ?? fallback` for graceful degradation when the
    projection is no longer alive (typical SwiftUI body usage during a
    parent-driven dismiss),
  - `store.requireAlive()` for assertions / explicit ownership paths
    where the caller has external proof that the projection is still
    routable.
  Dynamic member lookup (`store.someField`) and the SwiftUI bindings
  continue to work; they internally route through `requireAlive()` and
  surface a deterministic trap if the projection deactivates between the
  binding read and the action send.
- Migrate hot collection routing to `ForEachIdentifiedReducer` and
  `IdentifiedArrayOf<Element>` where the parent feature already keys child
  state by identity. The `ForEachReducer<[Element]>` overload remains for
  source-compatible call sites, but moving hot paths to the identified
  collection eliminates the per-action O(N) `firstIndex(where:)` scan.
- Tests that interleaved `await store.send(...)` with other awaits and
  relied on the per-action `Task { @MainActor }` hop should re-check
  their interleaving. The reducer-visible action sequence and the
  receive/expect API are unchanged; assert on reducer state, not on
  scheduler micro-timing.

### Notes

- Platform floors raised to iOS 18, macOS 15, tvOS 18, watchOS 11, and
  visionOS 2 (Swift 6.0 standard library). The 4.0.0 release dropped the
  prior iOS 17 / macOS 14 floor — apps that still need iOS 17 support must
  stay on the 3.x line. The bump unlocks direct use of Swift 6.0 standard
  library primitives (typed throws, `sending` parameters, `~Copyable`
  generics) without availability branches. Note that `AsyncThrowingStream
  .Iterator: Sendable` still requires `Failure: Sendable`, so the common
  `any Error` spelling continues to need a hand-rolled sequence — the
  bump removes that constraint for typed-failure stream wrappers but does
  not eliminate it universally.
- The sample package no longer compiles against `InnoNetworkWebSocket`; concrete
  transport/session ownership remains an app-boundary integration concern.
- The root package now enforces the Swift 6 package contract and pins
  `swift-syntax` exactly to `603.0.1`; update downstream lockfiles deliberately
  when adopting the release.
- The retired `FRAMEWORK_EVALUATION*` documents were removed. Use
  `docs/FRAMEWORK_COMPARISON.md` for adjacent-library positioning.
- Exact package pins can move to `4.0.0`.

## 3.0.2

### Who is affected

- Maintainers and CI jobs that build the `InnoFlowMacros` target through SwiftPM or Xcode package resolution.

### Required action

- No source migration is required for framework consumers.
- Update downstream lockfiles only if you want the quieter macro dependency graph from the `3.0.2` tag.

### Notes

- This patch release only aligns the declared `swift-syntax` macro dependencies with what the compiler already loads during package builds.

## 3.0.1

### Who is affected

- SwiftPM consumers that inspect resolved dependencies for InnoFlow.
- Maintainers or CI jobs that generate DocC documentation.

### Required action

- No source code migration is required for framework consumers.
- Switch DocC generation to `Tools/generate-docc.sh` instead of calling `swift package generate-documentation` directly from the checked-in package manifest.

### Notes

- This patch release removes `swift-docc-plugin` from the consumer dependency graph.
- DocC generation remains available for maintainers and CI through the docs-only generation flow.

## 3.0.0

### Who is affected

- Existing app features migrating to `PhaseMap`-owned phase transitions.

### Required action

- Stop mutating an owned phase directly once `.phaseMap(...)` is active.
- Update references to generated action path names that previously kept one leading underscore.

### Notes

- `PhaseMap` is the canonical runtime phase-transition layer for phase-heavy features.
- `validatePhaseTransitions(...)` remains available for backward compatibility.
