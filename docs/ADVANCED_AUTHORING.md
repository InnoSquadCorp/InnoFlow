# Advanced Reducer Authoring

This guide is the bridge between the rest of `docs/`. Read it after the README walk-through and once a reducer has more than a handful of cases.

The framework keeps three concerns in three documents:

- **Dependencies** — how reducers receive collaborators ([`docs/DEPENDENCY_PATTERNS.md`](DEPENDENCY_PATTERNS.md))
- **Instrumentation** — how the runtime exposes lifecycle events ([`docs/INSTRUMENTATION_COOKBOOK.md`](INSTRUMENTATION_COOKBOOK.md))
- **Cross-framework boundaries** — what stays *outside* InnoFlow ([`docs/CROSS_FRAMEWORK.md`](CROSS_FRAMEWORK.md))

This guide threads them together so a reducer-author with a non-trivial flow can build the right wiring on the first try.

## When to reach here

You are past README-territory once any of these is true:

- the feature has more than one `Reduce { ... }` block in its `body`
- the feature has a `Dependencies` bundle with more than two collaborators
- the feature emits effects that need cancellation, throttle, or debounce semantics
- the feature has a phase enum and you want legal transitions documented in the reducer contract
- the team has started shipping observability events (logs, metrics, signposts) for the runtime

## Authoring layers

The recommended order to build a new feature:

### 1. Sketch state and actions

Use `@InnoFlow` from the start; the macro both synthesizes `reduce(into:action:)` from `body` and emits CasePath/PhaseTotality/BindableField diagnostics that catch easy mistakes.

```swift
@InnoFlow
struct Feature {
  struct State: Equatable, Sendable, DefaultInitializable { /* ... */ }
  enum Action: Equatable, Sendable { /* ... */ }
  var body: some Reducer<State, Action> { /* ... */ }
}
```

### 2. Define a Dependencies bundle

Construction-time bundles keep reducer testing local; the test does not need a global container or a `@Dependency` registry to substitute fakes.

```swift
struct Dependencies: Sendable {
  let api: any APIClient
  let logger: any Logger
}
```

Then accept it via the reducer's initializer. See [`docs/DEPENDENCY_PATTERNS.md`](DEPENDENCY_PATTERNS.md) for the canonical single-service / composite-bundle / framework-provided-clock patterns and the substitutions accepted in tests.

### 3. Compose with primitives

`body` is a result-builder block. Within a single block reducers run in declaration order on the same state, with effects merged together (see [`Sources/InnoFlowCore/ReducerComposition.swift`](../Sources/InnoFlowCore/ReducerComposition.swift) for `buildPartialBlock`). Pick the smallest primitive that fits:

- `Reduce` — closure-backed, the leaf primitive
- `CombineReducers` — explicit grouping when you want emphasis (also runs in declaration order)
- `Scope` — child reducer over a non-optional sub-state
- `IfLet` — child reducer while optional state is present
- `IfCaseLet` — child reducer while enum-state matches a case
- `ForEachReducer` — collection-scoped row reducers

### 4. Add effect cancellation, throttle, or debounce

Effect semantics are owned by `EffectTask`. Use string-literal cancellation IDs for static work and `EffectID(_:)` for dynamic IDs. See the effect section of the README for the full list.

A high-volume effect (real-time stream, sensor fan-out) should compress at the boundary that knows the meaning of the traffic — `EffectTask.throttle`/`.debounce` or a collapsing reducer. The action queue itself does not back-pressure; see [`docs/adr/ADR-store-action-queue-burst.md`](adr/ADR-store-action-queue-burst.md).

### 5. Attach observability

Once the feature is wired end-to-end, decide what to observe at the runtime layer.

- `StoreInstrumentation.osLog(...)` and `.signpost(...)` cover Console + Instruments
- `StoreInstrumentationMetricsCollector` ships a built-in counter for runStarted / runFinished / runFailed / actionEmitted / actionDropped / effectsCancelled
- `.sink { event in ... }` is the escape hatch for vendor SDKs

For phase-managed features the matching surface is `PhaseMapDiagnostics` — see the *Phase Map Violations* section in [`docs/INSTRUMENTATION_COOKBOOK.md`](INSTRUMENTATION_COOKBOOK.md). The default `.disabled` keeps phase violations silent, so production deployments should always wire at least `.osLog` or `.sink` to a metrics backend.

### 6. Validate phase contracts in tests

If the feature is `@InnoFlow(phaseManaged: true)`, lock the legal transitions with `assertPhaseMapCovers(...)`. The principle gates enforce this for every phase-managed feature in `Sources/InnoFlow`; it is recommended for sample apps too.

## Where to read next

- [`docs/DEPENDENCY_PATTERNS.md`](DEPENDENCY_PATTERNS.md) — single-service, composite, framework-provided clock; three test-substitution scenarios; explicitly rejected anti-patterns.
- [`docs/INSTRUMENTATION_COOKBOOK.md`](INSTRUMENTATION_COOKBOOK.md) — `.osLog` / `.signpost` / `.sink` / `.combined` recipes plus the run-failure and phase-violation event coverage.
- [`docs/CROSS_FRAMEWORK.md`](CROSS_FRAMEWORK.md) — what InnoFlow does not own (navigation, transport, DI graphs).
- [`docs/PERFORMANCE_BASELINES.md`](PERFORMANCE_BASELINES.md) — how to interpret baseline gates and when to refresh fixtures.
- [`docs/FRAMEWORK_COMPARISON.md`](FRAMEWORK_COMPARISON.md) — positioning against TCA, ReactorKit, ReSwift, SwiftRex.
