# Migration Notes

This file tracks release-to-release migration guidance when behavior, defaults, or artifact contracts change in a way that users must react to.

## Unreleased

### Who is affected

- Consumers that directly referenced `ReducerBuilder`'s underscored
  implementation wrapper types instead of composing through public reducers.
- SwiftUI app targets that call `Store.binding`, `ScopedStore.binding`,
  `Store.preview`, or `EffectTask.animation(Animation?)`.
- Effects that still read `context.isCancelled` from inside `EffectTask.run`.
- Maintainers or downstream CI jobs that run the canonical sample package or
  sample app build under macro-heavy toolchains.

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
- Run canonical sample package tests and sample Xcode builds serially
  (`--jobs 1` / `-jobs 1`) so CI fails on real diagnostics instead of Swift
  macro worker log corruption.

### Notes

- Lowered platform floors are source-compatible: the root package and
  canonical sample now build down to iOS 17, macOS 14, tvOS 17, watchOS 10, and
  visionOS 1 without availability branches.
- The sample package no longer compiles against `InnoNetworkWebSocket`; concrete
  transport/session ownership remains an app-boundary integration concern.
- The root package now enforces the Swift 6 package contract and pins
  `swift-syntax` exactly to `603.0.1`; update downstream lockfiles deliberately
  when adopting the release.
- The retired `FRAMEWORK_EVALUATION*` documents were removed. Use
  `docs/FRAMEWORK_COMPARISON.md` for adjacent-library positioning.

## 4.0.0

### Who is affected

- Maintainers preparing the current implementation and documentation contract as the 4.0.0 public surface.
- Consumers who pin exact package tags once the 4.0.0 tag is published later.

### Required action

- No source migration is required from the current public APIs.
- Update exact package pins to `4.0.0` only after the 4.0.0 tag is published.

### Notes

- This release is a contract and documentation rebaseline. Runtime semantics, reducer authoring,
  import paths, and effect APIs are unchanged.
- `EffectTask.run` remains a non-throwing async closure; throwing work inside docs and app code
  should be handled inside the closure with `do/catch`.

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
