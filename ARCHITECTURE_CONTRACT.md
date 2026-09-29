# Architecture Contract

This document captures the stable framework guarantees that should not drift with scorecards or release notes.

## Core ownership

- InnoFlow owns business and domain transitions only.
- The app layer owns window, scene, route, and spatial runtime concerns. On `visionOS`, immersive-space orchestration stays in the app layer.
- Transport, reconnect, and session lifecycle stay outside InnoFlow.
- Construction-time `Dependencies` bundles enter reducers explicitly. InnoFlow does not own the dependency graph. See [`docs/DEPENDENCY_PATTERNS.md`](docs/DEPENDENCY_PATTERNS.md) for the canonical single-service / composite-bundle / framework-provided-clock patterns, and [`docs/CROSS_FRAMEWORK.md`](docs/CROSS_FRAMEWORK.md) for the navigation / transport / DI ownership split.

## Official authoring surface

- Official feature authoring declares the reducer output generic explicitly:
  `var body: some Reducer<State, Action, Never>` without app-boundary output,
  or the feature's typed `Output` when it emits one.
- Composition happens through `Reduce`, `CombineReducers`, `Scope`, `IfLet`, `IfCaseLet`, and `ForEachReducer`.
- Binding remains explicit through `@BindableField`, and SwiftUI bindings use projected key paths such as `\.$field`.
- `Store.preview(...)` and `#Preview` are the canonical preview entry points.
- `@InnoFlow` synthesizes action paths only for unlabeled single payloads and
  `id:action:` collection routes. Unsupported labeled or multi-payload cases
  warn unless `Action` declares the canonical `<caseName>CasePath` itself or
  the case carries `@InnoFlowCasePathIgnored`. The explicit marker suppresses
  both synthesis and unsupported-payload diagnostics for that case. The
  canonical static variable name is the syntactic manual-path signal, including
  when its value is expressed through a typealias or factory.

## Selection and derived state

- `SelectedStore` is the official derived-read model.
- Use `select(dependingOn:)` for a single explicit state slice; use the variadic `select(dependingOnAll:)` for two or more slices. Both forms keep selective invalidation regardless of arity.
- Closure-based `select { ... }` remains an always-refresh fallback when dependency reads cannot be declared soundly.

## Reducer output contract

- A reducer's associated `Output` is a typed, ephemeral event channel for
  one-shot app-boundary intent. Renderable, restorable, or queryable values
  remain in `State`.
- Reducers emit with `Self.output(_:)`. `mapOutput(_:)` explicitly lifts a
  child's output to a parent output type.
  `promoteOutput(to:)` adapts only `Output == Never` reducers or effects;
  it preserves effects and cannot discard an inhabited output type.
- `Store.outputs()` is live, broadcast, and non-replaying. Subscribers must be
  active before emission. Each subscriber chooses its own `AsyncStream`
  buffering policy. The lossless default is unbounded because one-shot
  coordinator commands must not be silently dropped; a bounded policy is an
  explicit opt-in to loss and its memory/ordering tradeoff belongs to the host.
- `Store.send(_:capturingOutputs:)` installs a single-consumer capture before
  enqueue and returns `OutputFlowTask<Output>`. It contains synchronous root
  output and descendant output from only that dispatch, preserves the caller's
  explicit buffering policy, and terminates when the action tree becomes idle.
  Cancellation of the task awaiting this capture cancels its dispatch, not
  unrelated work. Normal completion and broadcast subscriber cancellation do
  not cancel dispatches. A retained capture abandoned via `break` must be
  explicitly cancelled by its owner.
- Output is delivered after the reducer's synchronous state mutation and
  observer refresh. It does not re-enter the action queue.
  Queued descendant actions recheck dispatch cancellation before reduction;
  immediate output also observes cancellation accepted during state/observer
  execution. Cancellation does not roll back already-applied state changes.
- Output is intent, never authorization. A coordinator that handles buffered
  output after logout, account switching, or other session change must recheck
  current domain state before navigating or starting protected work.
- Every delivery attempt emits a payload-free instrumentation event containing
  store-wide subscriber enqueue/drop/termination counts, dispatch-capture
  disposition, sequence, and cancellation-suppression state.

## Effect runtime failure contract

- A non-cancellation error escaping an active `EffectTask.run` sequence is
  forwarded to the host failure channel exactly once per run.
- Cancellation and failure eligibility are arbitrated against the host's
  MainActor-isolated cancellation boundary. If cancellation is accepted first,
  a later domain error from uncooperative work is discarded instead of being
  reclassified as a run failure.
- `StoreInstrumentation.didFailRun` is invoked only after that arbitration.
  Instrumentation callbacks are synchronous observation hooks and should remain
  short and non-blocking.

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
- Exhaustivity never hides runtime failures. A non-cancellation error escaping
  an active `EffectTask.run` sequence records one hard failure at the public
  action assertion that created the run, including through delayed and
  composed effects. Multiple reports from one run use a first-error-wins
  contract; cancellation accepted first discards a later error under the host
  arbitration contract above.
- Scoped test stores forward the parent exhaustivity policy. Exhaustive scoped
  assertions compare the complete root state; actions that intentionally
  change parent or sibling state should be asserted through the parent
  `TestStore`.
- `finish()` is the terminal assertion. `.on` fails on unreceived actions;
  `.off` reduces buffered, late, and follow-up actions until the harness is
  idle. It also fails on unreceived reducer outputs. `receiveOutput(_:)`
  consumes outputs explicitly. `assertNoBufferedActions()` is an immediate
  intermediate checkpoint. The ambiguous `assertNoMoreActions()` API was
  removed in 6.0.
- Output reception supports exact values, predicates, and case-path payload
  extraction without imposing `Equatable` on every output. It follows the same
  exhaustive/non-exhaustive policy and single total deadline as action matching,
  including invalidated buffered values. Caller cancellation is not a timeout.
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
- `ScopedStore.send(_:)` returns a completed `FlowTask` and is a **silent
  no-op** once the parent is gone or the projection is inactive.
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
  projected value. Parent `Store` release invalidates tracked liveness and
  optional reads of live external projections on the MainActor before the
  store finishes deinitializing. When a collection element is removed, Observation invalidates
  tracked reads of these liveness values and of `optionalState` / `optionalValue`;
  removing a sibling element does not invalidate an unaffected projection.
- Closure-based selections are independent by default, including declared-
  dependency and memoized forms. An explicit semantic `id` opts into live-
  handle reuse at a matching call site, selector signature and value type;
  the ID must include captured inputs that affect the result. The ID cache
  holds handles weakly and compacts dead entries. Key-path-only selections
  retain their stable, strongly cached identity.
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
  families for one collection. When an ID leaves the source collection, the
  parent refresh immediately evicts that inactive row and its cached offset;
  releasing the final external handle therefore needs no later scope pass.
- Programming errors that are **not** lifecycle races still trap — in
  particular, constructing a `ScopedStore` whose state resolver returns `nil`
  at init time, and reading `ScopedStore.id` when the stable identifier type
  does not match the child state's `Identifiable.ID`. `ScopedStore` and its
  `Identifiable` conformance are MainActor-isolated; read collection projection
  IDs on that actor rather than moving their type-erased storage across
  executors.

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
- `PhaseMap.requireComplete(...)` is an opt-in throwing gate over explicitly
  declared trigger expectations. It does not change partial runtime semantics.
- `@InnoFlow(phaseManaged: true, strictPhaseTotality: true)` upgrades missing
  direct `Phase` source/target references from warnings to compile-time errors.
  The syntax-only macro does not claim arbitrary predicate, helper-built DSL,
  or payload-domain exhaustiveness; those remain `requireComplete(...)` tests.
- `PhaseTransitionGraph.mermaidDiagram()` and `dotGraph(name:)` export stable,
  deterministic documentation source from the same declared topology.
- `validatePhaseTransitions(...)` still exists for backward compatibility.
- Guard-bearing transitions remain intentionally out of scope for `PhaseTransitionGraph`; see [ADR-phase-transition-guards](docs/adr/ADR-phase-transition-guards.md).
- Conditional phase resolution lives in `PhaseMap`; see [ADR-declarative-phase-map](docs/adr/ADR-declarative-phase-map.md).

## Effects and runtime

- `EffectContext` is the canonical effect helper surface. Prefer `context.sleep(for:)` over raw `Task.sleep(...)` inside `.run`.
- Scheduled `.run(id:policy:onAdmission:)` lanes are Store-local. Admission
  order follows reducer effect reception; serial lanes advance only after the
  active run closure physically returns. Rejection is data, not a trap.
- Execution admission does not replace domain revisions, transactions, retry,
  rollback, or exactly-once persistence. Cancellation remains cooperative.
- `FlowScope` owns only explicitly tracked dispatch handles and must never use
  Store-wide cancellation to close a lexical scope. Core remains SwiftUI-free.
- Prefer `EffectTask.perform(operation:success:failure:)` for one throwing
  request that maps to exactly one success or failure action. Accepted
  cancellation emits neither terminal action.
- `Reducer.onChange(of:perform:)` observes one narrow equatable state slice
  after the base reducer. It merges the returned effect only on a value change.
- Cancellation is cooperative. Runtime teardown continues as best-effort async cleanup.
- `EffectTask.concatenate` rechecks both task cancellation and the effect-sequence boundary before every child, including inside nested concatenations. Once cancellation is accepted, no remaining child starts.
- Every throttle window owns one generation-scoped drain through its original deadline, including leading-only windows with no pending value. This bounds per-ID scope/window state, lets a later trailing request reuse the same deadline, and makes the active window visible to TestStore terminal verification without delaying leading-only effect ordering.
- A reused trailing-throttle drain adopts the latest pending effect sequence
  and cancellation-ID ownership. Its timer is runtime-owned; each `FlowTask`
  observes completion without receiving authority to cancel another
  dispatch's pending work. Store and TestStore therefore apply stale ID/global
  cancellation to the same active throttle scope, while TestStore keeps one
  finish activity through post-fire recursion.
- A `FlowTask` retains cancellation scopes weakly. Live effect contexts keep
  their own scopes alive, while completed descendants do not accumulate behind
  one long-running sibling.
- The runtime is designed to be deadlock-resistant and avoids coupling reducer semantics to middleware-style interception.

### `Store.send(_:)` scheduling contract

`Store.send(_:)` synchronously accepts the action and returns a `FlowTask`. It
guarantees two things before returning:

1. The reducer has finished running against the current state and any
   `.send(...)` follow-up actions returned by the reducer have been drained.
2. Any `.run { ... }` / `.merge(...)` / `.concatenate(...)` / `.debounce(...)` /
   `.throttle(...)` effect returned by the reducer has been **scheduled** onto
   an unstructured `Task`, but the body of that task has not necessarily started
   yet.

`FlowTask.finish()` then waits until every effect and follow-up action descended
from that dispatch becomes idle. `FlowTask.cancel()` requests cancellation only
for that tree; it does not cancel work started by another send. Cancellation
remains cooperative inside user operations.

Reaching the first `await` inside an effect's operation requires scheduler
turns — the outer `Task`, the `EffectWalker`, and `driver.startRun` each cross
an actor boundary before the operation body runs. The number of scheduler turns
required is not stable across Swift optimization levels: release-mode WMO
eliminates some scheduling boundaries that debug keeps, but the remaining
actor hops still need turns.

**Tests must therefore poll for observable conditions, not fixed yield counts.**
A bounded poll like `for _ in 0..<200 { if condition { break }; await Task.yield() }`
is the idiomatic pattern and is used throughout `InnoFlowTests`.

`ManualTestClock` goes further for the clock-advance case: when a test needs
to confirm that a `.run` body or a `.debounce`/`.throttle` wrapper has reached
its `try await clock.sleep(...)` registration before the clock is advanced,
use the deterministic waits — `waitForSleepers(atLeast:)` /
`advance(by:onceSleepersReach:)`, or `waitForSleepRegistrations(toReach:)`
when a restart replaces a pending sleeper without changing `sleeperCount`.
They suspend on the registration event itself, so neither a poll interval nor
a yield count is involved. `sleeperCount` remains available as an observable
condition for bounded polls in scenarios the deterministic waits do not
cover.

## Instrumentation

- `StoreInstrumentation.sink`, `.osLog`, `.signpost`, and `.combined` are the official instrumentation surfaces. `.signpost(signposter:name:)` brings the run lifecycle into Instruments without an external dependency. Action, error, and cancellation-ID payloads are redacted by default; exposing any of them requires its explicit opt-in. Reducer output payloads are never included: `outputDelivered` carries only delivery counts, dispatch-capture disposition, suppression state, and sequence. Pair `.signpost` with `.osLog(logger:)` through `.combined(...)` to keep both Console output and signpost-driven traces from the same store.
- External metrics backends such as `swift-metrics`, Datadog, or Prometheus should integrate through those sinks instead of changing reducer semantics.
- A root `DispatchID` is propagated through descendant actions, runs, outputs,
  and cancellation events. It is distinct from effect IDs, run tokens, and
  admission sequence numbers.
- `StoreDiagnostics` is opt-in, bounded, and payload-free. History truncation
  is explicit and active snapshots reflect live queued/running ownership.

## Testing-only contracts

- `TestStoreInvariant` runs exactly once after the fully composed reducer for
  every reduction entry path, before its returned effect is interpreted.
- `TestStoreScenario` is deterministic test input, not a production recording
  or state replay facility.
- Scoped output matching consumes the root output queue and preserves one
  ordering, exhaustivity, and deadline contract across root and child views.

## Accessibility and sample contract

- Canonical sample interactions keep stable `accessibilityIdentifier` values for hub rows, modal dismiss actions, destructive actions, and cancellation actions.
- Prefer explicit VoiceOver semantics over relying on button text alone.
- Prefer Dynamic Type-friendly system layout over fixed sizing.
