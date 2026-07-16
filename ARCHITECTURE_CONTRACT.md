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

## TestStore exhaustivity contract

- `TestStore.exhaustivity` defaults to `.on`. Every reducer state mutation must
  be described by the matching `send` or `receive` assertion closure, and every
  effect-emitted action must be consumed with `receive`.
- Omitting an assertion closure in exhaustive mode asserts that state does not
  change. Assertion closures describe the complete transition from the state
  before the action.
- Before sending a new user action, already-buffered effect actions are reduced
  to preserve runtime ordering. Exhaustive mode reports them as unreceived;
  non-exhaustive mode skips them silently or emits warnings according to the
  configured policy.
- A valid receive mismatch is reduced exactly once. Exhaustive mode reports it
  immediately. Non-exhaustive mode continues searching for the requested
  action, and mismatch recovery plus waiting share one total wall-clock
  deadline.
- `.off` enables partial state assertions. Its expected-state closure starts
  from the actual post-reducer state, and unexpected actions still run through
  the reducer and effect system. `.off(showSkippedAssertions: true)` emits
  non-failing warnings for skipped state or action assertions.
- Scoped test stores forward the parent exhaustivity policy. Exhaustive scoped
  assertions compare the complete root state; actions that intentionally
  change parent or sibling state should be asserted through the parent
  `TestStore`.
- `finish()` is the terminal assertion. `.on` fails on unreceived actions;
  `.off` reduces buffered, late, and follow-up actions until the harness is
  idle. `assertNoBufferedActions()` is an immediate intermediate checkpoint.
  The ambiguous `assertNoMoreActions()` API is deprecated in 5.x and planned
  for removal in 6.0.
- Deinitialization is a synchronous terminal safety net, not a second drain.
  If valid buffered actions or framework-owned run, composite, debounce, or
  throttle activity remains, `.on` records one failure,
  `.off(showSkippedAssertions: true)` records one warning, and `.off` remains
  silent. The snapshot is taken before remaining work is cancelled; stale
  actions are ignored, actions are never reduced, and a prior `finish()` result
  is not diagnosed again unless new work begins or arrives afterward.

## Projection lifecycle contract

`ScopedStore` and `SelectedStore` are projections of a parent `Store`. Their
lifetime is bounded by the parent. SwiftUI observers, however, can read a
projection on the same run-loop tick that its parent is being released — a
race that is internal to the integration, not a programming error.

The framework handles this race explicitly. `ScopedStore` and `SelectedStore`
expose the same tiered read contract:

- `ScopedStore.state` and `ScopedStore` dynamic-member reads return the **last
  valid cached snapshot** when the parent is gone or the projection has been
  marked inactive. This fallback exists only for SwiftUI's same-tick observer
  race; the API cannot bound how long an external handle is retained, so it is
  not a general lifecycle-aware read path.
- `ScopedStore.send(_:)` is a **silent no-op** once the parent is gone or the
  projection is inactive.
- `ScopedStore.optionalState` returns `nil` for the same dead-projection cases
  where `ScopedStore.state` would use its cached snapshot fallback.
- `SelectedStore.optionalValue` returns `nil` when the parent is gone or the
  projection is inactive. Treat `nil` as "regenerate the projection."
- `SelectedStore` dynamic-member reads follow the same observer-facing policy
  as `ScopedStore`: they diagnose a dead projection in debug and return the
  last valid cached snapshot in optimized builds.
- `ScopedStore.requireAlive()` and `SelectedStore.requireAlive()` trap with
  `preconditionFailure` when the projection is dead, including release builds.
  Use these explicit paths only when liveness is a caller-owned precondition.
- `SelectedStore.value` is removed from the 4.0.0 public surface; it is not a
  cached-fallback accessor.
- `ScopedStore.isAlive` and `SelectedStore.isAlive` report the same liveness
  signal as a `Bool` for sites that only need to gate work and do not read the
  projected value.
- Repeated `Store.scope(state:action:)` calls reuse a live `ScopedStore` only
  when source location, state key path, child types, and the opaque `CasePath`
  identity token all match. The parent cache holds the projection weakly, so
  cache reuse never extends its lifetime. A newly constructed `CasePath` is a
  safe cache miss and cannot inherit an older action transform.
- Macro-generated computed action paths use the specialized root action type
  and a private per-member marker as their opaque identity. Generic and
  extension accessors therefore preserve cache identity across repeated reads,
  while application-constructed paths retain reference identity.
- `Store.scope(collection:action:)` retains one active row family per
  collection key path. Matching child types and opaque `CollectionActionPath`
  identity reuse the ID-keyed rows across source locations. A signature change
  replaces the complete cached family; existing external row handles keep
  their original action transform, while the parent never pins multiple path
  families for one collection.
- Programming errors that are **not** lifecycle races still trap — in
  particular, constructing a `ScopedStore` whose state resolver returns `nil`
  at init time, and reading `ScopedStore.id` when the stable identifier type
  does not match the child state's `Identifiable.ID`.

**Recommended for new code:** use `optionalState` / `optionalValue` or
`isAlive` for release-tolerant non-UI handling. Reserve `ScopedStore.state` and
both stores' dynamic-member reads for SwiftUI view bodies and similar
tick-bounded observers that must always return a snapshot. The API cannot
enforce that short lifetime, so long-lived handles must use the optional or
`requireAlive()` accessors instead. Use `requireAlive()` for ownership paths
where a dead projection is a programming error.

This contract applies to single-child `Scope`, collection `ForEachReducer`
children, and derived `SelectedStore` projections.

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
