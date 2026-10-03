# Migration Notes

This file tracks release-to-release migration guidance when behavior, defaults, or artifact contracts change in a way that users must react to.

## 6.0.0

### Testing source locations and lexical scopes

New canonical assertion parameters are fileID, filePath, line and column, all defaulted at the caller. Explicit old file: calls remain accepted and map to column 1. Stored method values may need an adapter for the expanded signature. Direct FlowScope construction is now unavailable: move owned work into withFlowScope. Scenario.advance requires onceSleepersReach to make clock progression deterministic. TestStoreDispatch.effectLedger reports bounded typed lifecycle events separately from action/output assertions.

### Scheduler capacity and terminal admission

serial(maxPending:) and queueFull(maxPending:) now carry UInt. Nonnegative literals continue to work; validate signed application input before converting it with UInt(exactly:), rather than trapping or clamping implicitly. invalidCapacity is removed. Exhaustive EffectAdmission switches must handle cancelledBeforeStart and superseded. A delayed older latest request no longer evicts a newer live request. Terminal admission observations never authorize action delivery after accepted cancellation.

### Optional-child lifetime adoption

Existing IfLet keeps its behavior. To adopt state-owned cancellation, replace duplicate child composition with OptionalChildLifetime or the parent optionalChild modifier. Provide a fresh explicit instance ID on reopening; keeping the ID preserves the same lifetime. The wrapper already reduces the child before its complete parent. Lift typed outputs explicitly. Raw effect IDs inside a child are owner-local, so outside raw-ID cancellation no longer reaches opt-in child work. This is an additive opt-in API; see docs/OPTIONAL_CHILD_LIFETIME.md.

### IfCaseLet declaration identity

IfCaseLet now captures defaulted fileID, line and column parameters so optional-child lifetimes remain stable when a computed reducer body rebuilds manual CasePath values. Existing constructor calls continue to compile. A stored initializer function value with the previous four-argument signature needs a closure adapter that calls the initializer. Helpers that create separate overlapping case reducers at one declaration must supply a stable, distinct lifetimeID: EffectID<ID> for each namespace. CasePath cache identity is unchanged. The independent CollectionLifetimeConsumer checks ordinary calls, the explicit-ID overload, a function-value adapter, and rejection of the old direct initializer reference.

### Testing send return value and output progress

`TestStore.send`, `ScopedTestStore.send`, and phase helper sends return `TestStoreDispatch`. `TestFlowTask` remains a typealias for the earlier draft name. Existing statement calls need no change. Explicit async Void method values and protocol adapters must wrap the call and discard its result. A dispatch handle's finish diagnoses only its own unverified work without consuming it; global store finish retains its whole-store role. In `.off`, receiveOutput now reduces intermediate actions and their follow-up effects while seeking the output under the original deadline. Exhaustive global finish reports both pending action and output counts together.

### perform cancellation errors

`perform` now maps every thrown error, including a directly thrown `CancellationError`, to its failure action while the host remains active. Accepted task/dispatch/runtime cancellation remains silent. General `run` and AsyncSequence cancellation-error behavior is unchanged. Code that used a thrown CancellationError to abandon an active request should use explicit cancellation instead.

### Compiler-assisted authoring migration

Apply the macro Fix-It for a missing or incorrect third reducer generic; it selects Output only when the feature declares one and otherwise Never. Swift.Never is also accepted. Explicit-reduce repairs preserve existing Never effects with an explicit promoteOutput when moving to a typed-output body. Strict totality now checks active conditional Phase declarations and map references; missing compiler configuration produces a clear error instead of silently approving incomplete coverage. Constructor renamed availability does not rename the generated CasePath helper.

### Identifier corrections

Keyword Phase cases no longer fail strict totality merely because declaration and reference use different optional backticks. Raw Action/Output names retain spaces and punctuation in generated CasePath names; reference those members with Swift backticks. Existing ordinary and leading-underscore path names are unchanged. Missing Phase cases and actual generated-member collisions still diagnose.

### Who is affected

- Every `@InnoFlow` feature body must add the reducer output generic. Use
  `Never` when the feature emits no output, and its nested `Output` type when
  it does. Explicit generic uses of `Reduce` and `CombineReducers` must do the
  same.
- Manual reducers that emit output now return
  `ReducerEffect<Action, Output>`. `EffectTask<Action>` remains available as
  the `Output == Never` alias for reducers without outputs.
- Direct statement calls to `store.send(...)` remain source-compatible because
  the new `FlowTask` result is discardable. Code that stores `send` as a
  `Void`-returning function value must wrap it in a closure and discard the
  result explicitly.
- Tests still calling `assertNoMoreActions()` must choose the terminal or
  checkpoint contract described below.
- Features adopting typed outputs must subscribe before sending the action that
  emits them when using the store-wide broadcast. Output streams are live and
  non-replaying by design.

### Required action

Migrate reducer bodies and any explicitly specialized composition primitives:

```swift
// No app-boundary output
var body: some Reducer<State, Action, Never> {
  Reduce { state, action in
    // ...
    return .none
  }
}

// Typed app-boundary output
enum Output: Sendable { case dismiss }

var body: some Reducer<State, Action, Output> {
  Reduce { _, _ in
    Self.output(.dismiss)
  }
}
```

Child and parent output types must match at a composition boundary. Use
`mapOutput(_:)` when they differ; an unmapped mismatch is now a compile-time
error instead of a value that can disappear at runtime.

Use the dispatch handle when a caller owns an action tree's lifetime:

```swift
let task = store.send(.load)
await task.finish()

let cancelTask = store.send(.startSearch)
cancelTask.cancel()
await cancelTask.finish()
```

When adapting a method value that previously returned `Void`, discard the
handle explicitly:

```swift
let send: (Feature.Action) -> Void = { action in
  _ = store.send(action)
}
```

Replace terminal `assertNoMoreActions()` calls with `await store.finish()`.
Replace immediate queue-only checks with
`await store.assertNoBufferedActions()`.

Typed outputs are for one-shot app-boundary commands, not renderable or
restorable state:

```swift
@InnoFlow
struct Feature {
  struct State: Equatable, Sendable, DefaultInitializable {}

  enum Action: Equatable, Sendable {
    case select(Int)
  }

  enum Output: Equatable, Sendable {
    case openDetail(Int)
  }

  var body: some Reducer<State, Action, Output> {
    Reduce { _, action in
      switch action {
      case .select(let id):
        return Self.output(.openDetail(id))
      }
    }
  }
}

var outputs = store.outputs().makeAsyncIterator()
await store.send(.select(42)).finish()
let output = await outputs.next()
```

If output must be correlated to one action tree, prefer the atomic dispatch
capture. It is installed before enqueue, so synchronous output cannot race the
subscriber:

```swift
let task = store.send(.select(42), capturingOutputs: .unbounded)
var outputs = task.outputs.makeAsyncIterator()
await task.finish()
let output = await outputs.next()
```

`OutputFlowTask.outputs` is single-consumer and terminates with the dispatch.
Choose a bounded capture only when dropping is part of the feature contract.
Cancelling a task awaiting captured outputs cancels that dispatch, including
when consumption lives in SwiftUI `.task`. A plain `break` is not task
cancellation: call `task.cancel()` if the retained capture is being abandoned.
Cancelling a store-wide broadcast subscription never cancels dispatch work.

Use `mapOutput(_:)` at a child composition boundary when the child and parent
output types differ. Tests must consume emitted values with
`receiveOutput(_:)`; exhaustive `finish()` reports unhandled outputs.
For an output-free child or `EffectTask` helper, use
`promoteOutput(to: Output.self)` instead of manually mapping an impossible
`Never` value. Real child outputs still require `mapOutput(_:)`.
Non-equatable outputs can be received by predicate (`receiveOutput(where:)`)
or by `CasePath`. Like action matching, output matching honors exhaustivity and
one total timeout, including skipped mismatches and invalidated buffered values.

`Store.outputs()` now defaults to unbounded buffering so one-shot coordinator
commands are not silently dropped during a burst. Hosts may pass a bounded
`AsyncStream` buffering policy only when dropping is an explicit product
decision and should keep the stream continuously consumed.

Prefer `EffectTask.perform` for one async request with explicit success and
failure actions. Cancellation deliberately emits neither terminal action.
Use `onChange(of:perform:)` only for a narrow equatable state projection, not
an entire application state.

Independent requests that share an external resource can opt into Store-local
admission. Handle rejection explicitly so UI ownership is not stranded:

```swift
return .run(
  id: EffectID("profile-load"),
  policy: .dropWhileRunning,
  onAdmission: { .loadAdmission($0) }
) { send, context in
  // Cancellation remains cooperative.
}
```

Use `.serial(maxPending:)` only for bounded run admission. It does not replace
an application's persistence revision, transaction, retry, or rollback model.
Use `FlowScope` when one lexical caller owns several dispatch trees; register
only work that should be cancelled together.

`StoreDiagnostics` is opt-in and payload-free. Supplying one to `Store.init`
enables a bounded lifecycle history; omitting it allocates no history buffer.
Tests may supply `TestStoreInvariant` and replay `TestStoreScenario` values.
Invariant checks run once after the composed reducer for every reduction path.
Scenario callers that cancel execution can inspect `wasCancelled`,
`cancelledStepIndex`, and `cancelledStepLabel`; cancelled runs no longer execute
subsequent steps or look like fully completed scenarios.

Supported nested `Output` enum cases now receive macro-generated case paths.
`ScopedTestStore.receiveOutput` still consumes the root output queue, preserving
its ordering, exhaustivity, and total timeout. Existing manual canonical paths
continue to win, and `@InnoFlowCasePathIgnored` remains the explicit opt-out.

`PhaseMap` remains partial at runtime. Add `try phaseMap.requireComplete(...)`
to a test or release gate only when a feature intentionally promises complete
trigger coverage.

For directly declared phase enums, opt into compile-time declaration coverage
with `@InnoFlow(phaseManaged: true, strictPhaseTotality: true)`. This turns an
unreferenced `Phase` case into an error; predicate and payload-domain coverage
still belongs in `requireComplete(...)` tests.

### Collection identity and cancelled test-clock waits

`IdentifiedArray` equality and hashing now compare the stored ID-to-position
mapping as well as ordered element values. Arrays with equal values but
different custom IDs (or the same IDs at different positions) are no longer
interchangeable selection snapshots or Set/Dictionary keys. If a consumer
intentionally compares payloads only, compare `values` explicitly; do not use
payload-only equality to suppress identity-dependent updates. An identity
projection must remain stable for each stored element and must not depend on
mutable external state. Equivalent projections still compare equally when
they produce the same stored mapping and values.

`ManualTestClock.sleep(for:)` now throws `CancellationError` for a task that is
already cancelled, even when the duration is zero or negative. Remove tests
that expect code after that sleep to run successfully in a cancelled task.
Use an uncancelled task to test immediate completion, and separately assert
cancellation propagation. Nonpositive sleeps do not register a sleeper;
positive waits still use the deterministic registration APIs before advancing
manual time. These corrections do not require source-signature changes.


### Nested Output is an authoring declaration

A nested type named Output opts the feature into the typed-output contract. A previously unrelated nested Output in a 5.x feature must be renamed or deliberately adopted; it is not silently ignored. The body diagnostic names the expected output type. EffectTask remains the Never-output typealias, so its generic extensions do not become arbitrary-output helpers. Live Store.outputs streams do not replay prior values; dispatch capture buffers from before its send is enqueued.

### Dispatch correlation and timing JSONL

DispatchID.rawValue is now a process-local monotonic UInt64 and init(rawValue:) is unavailable. Use your own domain or tracing identifier for persisted and cross-process correlation. JSON consumers must retain integer precision beyond JavaScript's safe-integer range; use a lossless UInt64-capable parser instead of converting to a floating-point number.

EffectTimingRecorder.Entry.dispatchID is UInt64? and new JSONL records declare schemaVersion 2. Older records without dispatch correlation still decode. UUID-string records fail with an explicit migration diagnostic rather than silently losing identity. The offline scripts/migrate-effect-timing-jsonl.py takes explicit input and a new output path; it preserves the original file and maps each archived UUID to a collision-free file-local integer while retaining legacyDispatchID in the raw converted JSON. These imported numbers are archival correlation only, not live DispatchID values. Keep both raw files; decoding and re-encoding Entry retains its public fields, not the converter's extra provenance field. Numeric IDs are not globally unique and separate process/file captures must not be concatenated as one correlation namespace.

OnChange merges the base and change effects concurrently. Neither Store nor TestStore promises declaration-order emissions from those branches. If the application requires ordered work, express that order with concatenate; completing one branch earlier is not a host mismatch.

PhaseMap's defaulted source coordinates distinguish coverage declaration sites without requiring new arguments at ordinary call sites. If you store the initializer as a function value, use an explicit closure adapter. On Swift6.3, a TestStoreExplorer factory with multiple statements may need an explicit TestStoreExplorer<YourFeature> generic argument; its behavior is unchanged.

## 5.1.1

- Existing unlabeled single-payload and `id:action:` collection cases require
  no changes; their action paths continue to be synthesized.
- For a labeled or multi-payload case that needs routing, declare the canonical
  static `<caseName>CasePath` inside `Action`. The static variable name is the
  syntactic intent signal, so its value may use a `CasePath` typealias or factory.
- If the case intentionally needs no path, or the manual path must live in an
  extension that the attached macro cannot inspect, annotate the case with
  `@InnoFlowCasePathIgnored`. Both unqualified and module-qualified spellings
  are supported.

## 5.1.0

- `PhaseMapExpectedTrigger.predicate(_:sampleAction:)` is deprecated. Use the
  identical `PhaseMapExpectedTrigger("label", sampleAction:)` initializer —
  the compiler fix-it applies the rename. The factory never took a predicate
  closure; coverage has always been decided by running the sample action
  through the declared transitions.
- Tests that polled `ManualTestClock.sleeperCount` (or inserted
  `Task.yield()` / wall-clock sleeps) before `advance(by:)` can migrate to
  the deterministic waits: `advance(by:onceSleepersReach:)`,
  `waitForSleepers(atLeast:)`, and `waitForSleepRegistrations(toReach:)` for
  latest-wins restarts. The polling pattern keeps working but is no longer
  the recommended idiom.

## 5.0.0

Historical 5.0 migration guidance follows. Its partial examples describe that
version's transition and are not copy-ready 6.0 recipes; use the 6.0.0 section
above for current feature authoring and testing contracts.

### Who is affected

- Consumers upgrading to 5.0.0 with a Swift toolchain older
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

In 6.0, closure-based `select` calls no longer infer identity from their call
site alone. Each call creates an independent handle unless a stable semantic
`id:` is supplied, including the dependency-aware and `memoize:` overloads.
If a view relied on repeated closure calls at one call site returning the
same handle, pass an ID that covers every captured input and retain the handle
for as long as that identity is needed. Calls from different source locations
do not share a handle. Key-path-only selections keep their existing cache.
Code that stores a closure-based `select` method itself as a function value
must adapt to the new defaulted `id:` parameter; Swift does not apply default
arguments when converting a method to a function value.
Tracked `isAlive`, `optionalState`, and `optionalValue` reads now invalidate
when the parent store is released, not only when a collection element is
removed or when the caller checks liveness again.

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

- Keep feature bodies typed as `some Reducer<State, Action, Never>` and compose with
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
