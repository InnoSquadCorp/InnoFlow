# Migration Notes

This file tracks release-to-release migration guidance when behavior, defaults, or artifact contracts change in a way that users must react to.

## 5.0.0 (in development)

### Who is affected

- Consumers building the 5.0 development line with a Swift toolchain older
  than 6.3 are affected. All package targets now compile in Swift 6 language
  mode under the Swift 6.3 toolchain contract.
- Ordinary `store.scope(state:action:)` call sites are source-compatible and
  require no changes.
- Consumers that store `store.scope` itself as a two-argument method value are
  affected. The method now includes defaulted `fileID`, `line`, and `column`
  parameters so runtime scope identity can include the source location; Swift
  does not apply default arguments when converting a method to a function
  value.
- Consumers that intentionally relied on every repeated
  `Store.scope(state:action:)` call allocating a distinct `ScopedStore` are
  affected. Calls with the same source location, state key path, child types,
  and `CasePath` identity now return the same live projection.
- Consumers that reconstructed a `CollectionActionPath` but relied on
  `Store.scope(collection:action:)` returning the previous row objects are
  affected. Independently constructed paths now replace the active row family
  so a row can never inherit an outdated action transform.
- Consumers that relied on `SelectedStore` dynamic-member reads trapping after
  parent release or source-collection removal in optimized builds are affected.
  Those view-facing reads now return the last valid snapshot, matching
  `ScopedStore`'s observer-race behavior.
- Consumers whose child state declares a member named `requireAlive` and reads
  it through `scoped.requireAlive` are affected. The new real
  `ScopedStore.requireAlive()` method takes precedence over dynamic-member
  lookup, so that expression now resolves to a function value.
- Consumers that read `ScopedStore.id` from a non-MainActor context are
  affected. Its `Identifiable` conformance is now MainActor-isolated so the
  underlying type-erased identifier never crosses executors unsafely.
- Tests that relied on partial `TestStore` state assertions are affected.
  `TestStore.exhaustivity` now defaults to `.on`, and an omitted `send` or
  `receive` assertion closure means that the reducer must not change state.
- Tests that sent a new user action while effect actions were still pending are
  affected. Exhaustive stores reduce those pending actions to preserve runtime
  order and report that each one should have been received first.
- Tests that assumed a mismatched effect action was discarded are affected.
  The action is now reduced exactly once before exhaustive mode reports the
  mismatch; non-exhaustive mode continues searching under one total deadline.
- Tests that let an exhaustive `TestStore` leave scope with valid buffered
  actions or active framework-owned effects are affected. Deinitialization now
  snapshots that work, cancels it, and then records one terminal-verification
  failure from the captured snapshot. Idle stores and stores whose `finish()`
  already completed or reported a failure are unaffected.
- Tests whose `EffectTask.run(sequence:)` stream throws a non-cancellation
  error are affected. `TestStore` previously discarded that error and could
  let `finish()` succeed; it now records one hard failure at the action
  assertion that created the run, regardless of exhaustivity.
- Call sites using `assertNoMoreActions()` are affected by a deprecation
  warning. Its legacy behavior remains available during the 5.x line and is
  planned for removal in 6.0.

### Required action

Upgrade downstream development and CI environments to Swift 6.3 or newer
before adopting the 5.0 line. The root package, compile-contract clients,
canonical sample package, Xcode sample targets, and DocC workflow are validated
against that toolchain contract.

For exhaustive tests, describe every complete state transition and receive
every effect-emitted action:

```swift
let store = TestStore(reducer: Feature())

await store.send(.start) {
  $0.phase = .loading
}

await store.receive(._finished(.fixture)) {
  $0.phase = .loaded
  $0.value = .fixture
}

await store.finish()
```

Use `finish()` at the terminal boundary and `assertNoBufferedActions()` only
for an intermediate, immediate queue checkpoint. Replace
`assertNoMoreActions()` according to that intent; there is no single renamed
replacement because the legacy API mixed both purposes.

If a test is intentionally partial or needs an incremental migration, opt out
explicitly:

```swift
store.exhaustivity = .off(showSkippedAssertions: true)
```

In `.off` mode, expected-state closures start from the actual post-reducer
state, unexpected effect actions are reduced automatically, and
`showSkippedAssertions: true` emits non-failing warnings. `finish()` drains
buffered, late, and follow-up actions until the harness is idle.

Do not rely on deinitialization to drain a test. It does not wait for effects
or reduce buffered actions. In `.on`, omitted terminal work records one
failure; `.off(showSkippedAssertions: true)` records one warning; `.off`
cancels silently. Tests that intentionally exercise `TestStore` release with
active work can opt out explicitly, but ordinary tests should receive or
cancel expected work and still end with `finish()`.

Handle expected `AsyncSequence` failures inside the effect and convert them
into domain actions that the test can receive. Reserve thrown cancellation for
normal cooperative termination. `.off` relaxes state and action assertions;
it does not hide runtime errors. Once Store or TestStore has accepted an effect
cancellation, however, a later domain error from cancellation-ignoring work is
classified as part of that cancelled run and is not reported through
`didFailRun` or the TestStore assertion channel.

Scoped stores forward the parent exhaustivity policy. Because exhaustive child
assertions compare the complete root state, send through the parent
`TestStore` when a child action intentionally mutates parent or sibling state.

For scoped projection identity changes, either include the source-location
parameters in the stored function type:

```swift
typealias LocatedScopeMethod = @MainActor @Sendable (
  KeyPath<Feature.State, Feature.Child>,
  CasePath<Feature.Action, Feature.ChildAction>,
  StaticString,
  UInt,
  UInt
) -> ScopedStore<Feature, Feature.Child, Feature.ChildAction>

let scope: LocatedScopeMethod = store.scope
let child = scope(
  \.child,
  Feature.Action.childCasePath,
  #fileID,
  #line,
  #column
)
```

Or preserve a two-argument function shape with a closure:

```swift
typealias ScopeMethod = @MainActor @Sendable (
  KeyPath<Feature.State, Feature.Child>,
  CasePath<Feature.Action, Feature.ChildAction>
) -> ScopedStore<Feature, Feature.Child, Feature.ChildAction>

let scope: ScopeMethod = { state, action in
  store.scope(state: state, action: action)
}
```

If a caller genuinely needs an independent projection, use a distinct source
location or an independently constructed `CasePath`. Features whose macro
expansion emits a stored static action path should keep that path so repeated
body evaluation reuses one observer and projection identity. Generic or
extension lexical contexts still synthesize computed action paths, but 5.0
assigns each generated member a stable identity from its specialized root
action type and a private generated marker. Repeated access therefore reuses
the same live projection without a manual hoist.

Ordinary `store.scope(collection:action:)` calls remain source-compatible. To
preserve stable row object identity, reuse a stored `CollectionActionPath`
(normally the macro-generated `static let`). The collection cache retains one
active signature per collection key path: matching child types and opaque path
identity reuse the same ID-keyed rows across source locations. Changing either
part replaces the complete cached family; previously returned row handles
remain valid and keep their original action transform.

Generic or extension lexical contexts synthesize a computed
`CollectionActionPath` whose generated identity is stable for the specialized
root action type and a private per-member marker. Repeated rendering therefore
reuses the active row family. Construct a path explicitly only when a separate
routing identity is intentional.

`SelectedStore` dynamic-member reads are now reserved for SwiftUI view bodies
and similarly tick-bounded observers. If a dead projection must remain a hard
failure in every build, replace `selected.someMember` with
`selected.requireAlive().someMember`. For release-tolerant non-UI reads, use
`selected.optionalValue` and regenerate the projection when it returns `nil`.

`ScopedStore` now provides the same explicit strict path through
`scoped.requireAlive()`. Its existing `state` and dynamic-member reads retain
the view-facing cached fallback, while `optionalState` remains the
release-tolerant absence path.

Read collection-scoped `ScopedStore.id` values on the MainActor. SwiftUI view
bodies already satisfy this contract. Non-UI async code should obtain the ID
inside `await MainActor.run { scoped.id }` and pass the resulting domain ID,
not the scoped store itself, across executors.

If child state already has a property named `requireAlive`, make that lookup
explicit. Use `scoped.state.requireAlive` only in a SwiftUI view body that needs
the cached observer-race fallback, `scoped.optionalState?.requireAlive` for a
release-tolerant non-UI read, or `scoped.requireAlive().requireAlive` when a dead
projection is a programming error.

## 4.0.0

### Who is affected

- Consumers upgrading from 3.x to the 4.0.0 public surface.
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
