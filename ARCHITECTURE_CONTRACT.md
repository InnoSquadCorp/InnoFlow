# Architecture Contract

This document captures the stable framework guarantees that should not drift with scorecards or release notes.

## Core ownership

- InnoFlow owns business and domain transitions only.
- The app layer owns window, scene, route, and spatial runtime concerns. On `visionOS`, immersive-space orchestration stays in the app layer.
- Transport, reconnect, and session lifecycle stay outside InnoFlow.
- Construction-time `Dependencies` bundles enter reducers explicitly. InnoFlow does not own the dependency graph. See [`docs/DEPENDENCY_PATTERNS.md`](docs/DEPENDENCY_PATTERNS.md) for the canonical single-service / composite-bundle / framework-provided-clock patterns, and [`docs/CROSS_FRAMEWORK.md`](docs/CROSS_FRAMEWORK.md) for the navigation / transport / DI ownership split.

## Official authoring surface

- Official feature authoring uses `var body: some Reducer<State, Action>`.
- Composition happens through `Reduce`, `CombineReducers`, `Scope`, `IfLet`, `IfCaseLet`, and `ForEachReducer`.
- Binding remains explicit through `@BindableField`, and SwiftUI bindings use projected key paths such as `\.$field`.
- `Store.preview(...)` and `#Preview` are the canonical preview entry points.

## Selection and derived state

- `SelectedStore` is the official derived-read model.
- Use `select(dependingOn:)` for a single explicit state slice; use the variadic `select(dependingOnAll:)` for two or more slices. Both forms keep selective invalidation regardless of arity.
- Closure-based `select { ... }` remains an always-refresh fallback when dependency reads cannot be declared soundly.

## Projection lifecycle contract

`ScopedStore` and `SelectedStore` are projections of a parent `Store`. Their
lifetime is bounded by the parent. SwiftUI observers, however, can read a
projection on the same run-loop tick that its parent is being released — a
race that is internal to the integration, not a programming error.

The framework handles this race explicitly:

- **Reads** (`ScopedStore.state`, `SelectedStore.value`, and their
  `@dynamicMemberLookup` subscripts) return the **last valid cached snapshot**
  when the parent is gone or the projection has been marked inactive. The
  observer refresh pass invalidates dependents within the next tick, so the
  stale read is bounded to one tick.
- **Writes** (`ScopedStore.send(_:)`) are **silent no-ops** once the parent is
  gone or the projection is inactive.
- Debug builds surface both cases via `assertionFailure`, so the race is
  immediately visible in development. Release builds do not abort.
- Programming errors that are **not** lifecycle races still trap — in
  particular, constructing a `ScopedStore` whose state resolver returns `nil`
  at init time, and reading `ScopedStore.id` when the stable identifier type
  does not match the child state's `Identifiable.ID`.

Callers that need to react to a released parent without consulting the cached
fallback can use the explicit accessors:

- `ScopedStore.isAlive` and `SelectedStore.isAlive` report whether the
  projection is still backed by a live parent and active observer state.
- `ScopedStore.optionalState` and `SelectedStore.optionalValue` return `nil`
  in the same situations where `state`/`value` would emit a debug assertion
  and a cached fallback. They are the contract-compliant way to ask
  "is this projection still meaningful?" from a release-tolerant call site
  and treat `nil` as "regenerate the projection."

These accessors do not change the cached-read or no-op-write semantics above;
they expose the same lifecycle signal to callers that prefer to branch on
liveness rather than rely on the cached snapshot.

This contract applies to single-child `Scope`, collection `ForEachReducer`
children, and derived `SelectedStore` projections alike.

## Phase-driven modeling

- `PhaseMap` is the canonical runtime phase ownership layer for phase-heavy features.
- `PhaseMap` is a post-reduce decorator and owns the declared phase key path.
- `phaseGraph = phaseMap.derivedGraph` remains the canonical pattern when a feature needs static topology checks and runtime phase ownership together.
- `PhaseTransitionGraph` stays topology-only and `validationReport(...)` remains the graph-level validation surface.
- `validatePhaseTransitions(...)` still exists for backward compatibility.
- Guard-bearing transitions remain intentionally out of scope for `PhaseTransitionGraph`; see [ADR-phase-transition-guards](docs/adr/ADR-phase-transition-guards.md).
- Conditional phase resolution lives in `PhaseMap`; see [ADR-declarative-phase-map](docs/adr/ADR-declarative-phase-map.md).

## Effects and runtime

- `EffectContext` is the canonical effect helper surface. Prefer `context.sleep(for:)` over raw `Task.sleep(...)` inside `.run`.
- Cancellation is cooperative. Runtime teardown continues as best-effort async cleanup.
- The runtime is designed to be deadlock-resistant and avoids coupling reducer semantics to middleware-style interception.

### `Store.send(_:)` scheduling contract

`Store.send(_:)` is synchronous. It guarantees two things and nothing more:

1. The reducer has finished running against the current state and any
   `.send(...)` follow-up actions returned by the reducer have been drained.
2. Any `.run { ... }` / `.merge(...)` / `.concatenate(...)` / `.debounce(...)` /
   `.throttle(...)` effect returned by the reducer has been **scheduled** onto
   an unstructured `Task`, but the body of that task has not necessarily started
   yet.

Reaching the first `await` inside an effect's operation requires scheduler
turns — the outer `Task`, the `EffectWalker`, and `driver.startRun` each cross
an actor boundary before the operation body runs. The number of scheduler turns
required is not stable across Swift optimization levels: release-mode WMO
eliminates some scheduling boundaries that debug keeps, but the remaining
actor hops still need turns.

**Tests must therefore poll for observable conditions, not fixed yield counts.**
A bounded poll like `for _ in 0..<200 { if condition { break }; await Task.yield() }`
is the idiomatic pattern and is used throughout `InnoFlowTests`.

`ManualTestClock` exposes `sleeperCount` for a related purpose: when a test
needs to confirm that a `.run` body or a `.debounce`/`.throttle` wrapper has
reached its `try await clock.sleep(...)` registration before the clock is
advanced, polling `await clock.sleeperCount == N` is the safe marker.

## Instrumentation

- `StoreInstrumentation.sink`, `.osLog`, `.signpost`, and `.combined` are the official instrumentation surfaces. `.signpost(signposter:name:)` brings the run lifecycle into Instruments without an external dependency; token, sequence, and cancellation identifiers stay visible in signpost messages, while action payloads are redacted unless `includeActions: true` is passed. Pair it with `.osLog(logger:)` through `.combined(...)` to keep both Console output and signpost-driven traces from the same store.
- External metrics backends such as `swift-metrics`, Datadog, or Prometheus should integrate through those sinks instead of changing reducer semantics.

## Accessibility and sample contract

- Canonical sample interactions keep stable `accessibilityIdentifier` values for hub rows, modal dismiss actions, destructive actions, and cancellation actions.
- Prefer explicit VoiceOver semantics over relying on button text alone.
- Prefer Dynamic Type-friendly system layout over fixed sizing.
