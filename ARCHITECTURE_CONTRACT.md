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
- `@InnoFlow` synthesizes action paths only for unlabeled single payloads
  (including a payload written `_ name: Payload`) and `id:action:` collection
  routes. Unsupported labeled or multi-payload cases warn unless `Action`
  declares the canonical `<caseName>CasePath` itself or the case carries
  `@InnoFlowCasePathIgnored`. The explicit marker suppresses both synthesis
  and unsupported-payload diagnostics for that case. The canonical static
  variable name is the syntactic manual-path signal, including when its value
  is expressed through a typealias or factory. A canonical manual path
  declared in the enum body takes precedence over synthesis for every case
  shape of `Action` and `Output`; one declared in an extension is invisible
  to the macro and redeclares a synthesized member.

## Selection and derived state

- `SelectedStore` is the official derived-read model.
- Use `select(dependingOn:)` for a single explicit state slice; use the variadic `select(dependingOnAll:)` for two or more slices. Both forms keep selective invalidation regardless of arity.
- Closure-based `select { ... }` remains an always-refresh fallback when dependency reads cannot be declared soundly.
- `IdentifiedArray` equality and hashing include stored ID-to-position mappings
  and ordered values. Identity-only changes invalidate root/scoped selections;
  custom identity projections must remain stable for stored elements.

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
- `finish()` is the terminal assertion. `.on` reports unreceived actions and outputs from one bounded terminal snapshot;
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
  keep one identity per owner, call site and key path while that selection is
  alive. Their cache entry is weak too; in addition the owner retains a
  key-path selection from a tracked read until the notification that consumes
  it, so a transient view-body read is still invalidated, and for one further
  notification so a reader that reads again keeps the same handle. A key-path
  selection that is never read, or that passes two notifications unread, is
  released, and a released selection leaves its dependency bucket at once, so
  the owner stops evaluating its key path. A liveness read (`isAlive`)
  records its Observation access on the owner's liveness — the parent
  `Store`'s release or the `ScopedStore`'s deactivation — instead of on the
  selection, so it never retains the selection, and its reader is notified
  when the owner is deactivated, even after the selection was released. A
  `ScopedStore` that is released without being deactivated (a single scope
  dropped before its store, or a row of a superseded family) notifies no
  one: its selections turn dead without a notification, so a reader that
  needs one holds the scope. The
  selection cannot tell a tracked value read from an untracked one: any value
  read starts the retention above.
  Key paths must therefore be valid for every state reachable while a reader
  holds the selection or the owner still retains it.
- A dependency bucket's change predicate is determined by its key. Key-path
  selections and single scopes compare values; collection scopes compare
  element identity in storage of their own, so neither can replace the
  other's comparison on the same key path.
- A collection scope refreshes the rows a state change can affect. A value
  change refreshes that element's row; a structural change (ids, order or
  count) lets the rows resolve their new positions once, together, and then
  refreshes only the rows whose element changed or was removed; an action
  that leaves the collection's storage untouched refreshes no row. Elements
  whose stored bytes are identical are treated as unchanged without calling
  `==`, so an element that did not change is not reported as changed even if
  its `==` is irreflexive (for example a `Double` NaN). The byte comparison
  is a shortcut, not a guarantee of speed: copies of an element type with
  padding and a non-trivial member can differ in padding bytes, and such
  elements fall back to `==`. A collection that exposes no contiguous
  storage is compared element by element and refreshes every row on a
  structural change. A removed row is deactivated by the pass that
  classifies the removal, also when an observation callback scopes the
  collection again in the middle of that pass, through the same or another
  action path. Rows of a row family that a later scope over the same key path
  superseded stay correct but resolve their element by scanning; the family
  that replaces them reports their vanished elements at the next structural
  change. A row whose id occurs more than once resolves its first occurrence.
  A scope in the middle of the pass, before or after the pass classifies the
  change, changes none of these rules: every row still compares its element
  with that element's previous value, so a row that only moved is not
  refreshed, a removed row of the active family does not scan, and a row
  whose id occurs more than once follows its first occurrence.
- Creating a key-path selection seeds its snapshot without recording an
  Observation access on the parent, so a view that selects one value does
  not depend on the whole parent state; the owner retains the selection for
  its reader instead. A closure-based selection (`dependingOn:`,
  `dependingOnAll:`, a selector, with or without `id:`) has no such
  retention, so creating one during a tracked read records a read of the
  parent's state, as in 6.0.x, and so does getting another holder's live
  selection from the `id:` cache (a cache hit records that Observation access
  without reading the state, so a reducer can do it while its own store
  reduces). A view that obtains one in its body is
  therefore invalidated by any parent change until it holds the selection.
- A reducer-returned `.cancel`, a `cancelInFlight: true` replacement, a
  newer debounce request and a `latest` lane request are accepted in the
  MainActor turn of the reduction that returned them, whenever the
  interpreter would reach them without awaiting asynchronous work. From that
  turn on work of every earlier effect that they cancel or replace cannot
  have an action reduced, pending scheduled requests for the identifier are
  released, and only delivery of task cancellation to running operations
  remains outstanding. The effect that issued the request is interpreted in
  declaration order: an earlier `concatenate` sibling of a `.cancel` still
  runs, and the cancel covers its own effect when the interpreter reaches it
  (`merge` children run concurrently and have no order among themselves). A
  cancellation placed after asynchronous work in a `concatenate` is accepted
  when that work completes. A `latest` request that its lane will admit is
  accepted completely in the turn, like `cancelInFlight: true`: the lane's
  earlier request is displaced and reported as superseded, and every other
  earlier effect under the identifier is released and recorded, even when
  the replacing dispatch is then cancelled before its effect runs. A
  `latest` request that a lane with another policy will reject changes
  nothing. The turn decides every lane request it reaches against the lane
  state of that turn, with the rule admission applies, and the interpreter
  later reports exactly that decision: a request the lane rejects, or whose
  own tree already cancelled its lane identifier, completes without awaiting,
  so a cancellation after it in a `concatenate` is still accepted in the
  turn; a request the lane admits awaits its run. A lane request whose
  outcome depends on the order in which the interpreter runs `merge`
  children is not decided in the turn: one that shares its lane with a lane
  request in another branch of an enclosing `merge`, or whose identifiers
  another branch cancels or requests the cancellation of, wherever that work
  lies in its branch. The turn then accepts no `latest` replacement for it
  and nothing behind it in its branch, and its admission decides it; work
  whose context another branch's `.cancel` covers is treated the same way,
  even when the work's own path cancelled that identifier first.
  A `latest` request merged only with work that touches neither its lane nor
  its identifiers, such as `.merge(.send(.loading), latestRun)`, is still
  accepted in the turn. A `latest` lane displaced
  in a reduction turn stays the open `latest` lane under its identifier until
  its replacement is admitted or can no longer proceed, so a request with
  another policy meets a conflicting lane. A throttled subtree is the exception: whether it runs depends on its window,
  so cancellation inside it is accepted when the interpreter admits it.
  `Store` and `TestStore` share this acceptance, so a test receives the
  actions a production store reduces (see TestStore delivery below for the
  order, its known limits, and cancellations a test issues). A dispatch whose declared work
  an identifier cancellation releases before that work is registered records
  the cancellation in diagnostics when the interpreter skips the work.
- A run's task-cancellation handlers (`withTaskCancellationHandler`,
  `AsyncStream` termination) execute where cancellation is delivered, which
  can be the main thread inside `send`, `cancelEffects` or `Store.deinit`.
  They must not block on work the main thread is waiting to do.
- Store effect bookkeeping is MainActor-isolated end to end. Run tasks are
  registered in the turn that creates them, the emission decision and the
  delivery it authorizes share one MainActor turn, and cancellation marks
  tokens, cancels tasks and returns lane capacity in one synchronous step.
  `cancelEffects(identifiedBy:)` and `cancelAllEffects()` keep their `async`
  signatures and do not suspend. A run reads its own cancellation state
  without leaving its task.
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
- Cancellation is cooperative. The runtime delivers task cancellation synchronously, including on Store teardown; only the cooperative end of user operations remains outstanding.
- `EffectTask.concatenate` rechecks both task cancellation and the effect-sequence boundary before every child, including inside nested concatenations. Once cancellation is accepted, no remaining child starts.
- Every throttle window owns one generation-scoped drain through its original deadline, including leading-only windows with no pending value. This bounds per-ID scope/window state, lets a later trailing request reuse the same deadline, and makes the active window visible to TestStore terminal verification without delaying leading-only effect ordering.
- A reused trailing-throttle drain adopts the latest pending effect sequence
  and cancellation-ID ownership. Its timer is runtime-owned; each `FlowTask`
  observes completion without receiving authority to cancel another
  dispatch's pending work. Store and TestStore therefore apply stale ID/global
  cancellation to the same active throttle scope, while TestStore keeps one
  finish activity through post-fire recursion. A cancellation that removes
  the window's newest trailing request — through its dispatch or through an
  identifier only that request carries — removes only the retained requests
  it covers and hands the window, with its timer, to the newest remaining
  request that can still proceed (a window retains the newest request and up
  to seven it replaced); the window resets only when none remains.
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

Lifetime ownership metadata does not introduce a scheduling boundary. A bare
child `.send` or output stays synchronous through `optionalChild`; emitted
actions retain the captured owner until queue admission. Reentrant removal or
replacement can reject that queued action with the normal drop observation.
Once an action is admitted, the new reducer composition determines ownership:
parent effects outside the child wrapper remain independent. Explicit merge,
concatenate and run operations keep their asynchronous scheduling semantics.

`FlowTask.finish()` then waits until every effect and follow-up action descended
from that dispatch becomes idle. `FlowTask.cancel()` requests cancellation only
for that tree; it does not cancel work started by another send. Cancellation
remains cooperative inside user operations.

Reaching the first `await` inside an effect's operation requires scheduler
turns — the root interpreter `Task`, the run `Task` it starts, and the hop
from the MainActor to the operation's concurrent executor. The number of
scheduler turns required is not stable across Swift optimization levels:
release-mode WMO eliminates some scheduling boundaries that debug keeps, but
the remaining hops still need turns.

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

`ManualTestClock.sleep(for:)` checks task cancellation before returning for a
zero or negative duration, matching `StoreClock.continuous`. Uncancelled
nonpositive waits do not park or advance time. Cancellation of a parked sleeper
removes that sleeper and leaves the clock reusable.

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

## Macro identifier contract

Phase declarations and references compare the same logical Swift identifier, regardless of optional backticks. Action and Output path names preserve raw spelling and strip exactly one leading underscore. Code emission separately escapes generated members, case references, and payload labels. Missing cases and active-context member collisions remain errors; manual paths and ignored cases keep their existing meaning. Valid language spellings are tested through real consumers, including keywords, spaces, punctuation, numbers, and Unicode.

### TestStoreDispatch

TestStore delivery: a `Store` reduces an effect action, and publishes an output, when an effect delivers it; a `TestStore` buffers the value and reduces an action when the test receives it. Both buffers keep the order in which a `Store` handles the values in the schedule where every buffered value was handled at its delivery. When a received action's reduction returns a plain `.send` or `.output` (also mapped, lifted by `Scope`, or under optional-child ownership), a `Store` drains it with the reduction: the value is queued right behind the action, and an output ahead of every output published after the action, at every depth of a plain chain; this is the only order a `Store` has. A `Store` hands any other effect to a root interpreter task it creates while it handles the action, and MainActor tasks run in the order they are created. A test store queues a MainActor marker task, the action's anchor, at every effect-action delivery outside the synchronous part of a walk it follows, and at every send (also scoped or phase) when it begins; a value a followed walk delivers takes the walk's next level instead, and a marker takes its position when it runs. The test store starts a received or sent action's interpreted effect only once its anchor has run, and queues the values the synchronous part of that walk delivers at the anchor's position: behind everything delivered before the anchor ran, such as the later sends of the `concatenate` job that delivered the action or a run emission whose MainActor job was already queued when the action was delivered or sent, and ahead of everything delivered after it, such as the emitting run's next emission or a `concatenate` step after a run. A buffered value keeps that position however late the test receives. `send` and `receive` of such an action let the MainActor jobs queued before the anchor run before they start the effect, and the jobs a test queues after they return run after the anchors of the interpreter tasks that walk creates. The anchor of an interpreted value's own interpreter is queued when the anchor of the interpreter that delivered it runs, where a `Store` creates that task, for four levels; deeper values share the fourth position, and an anchor chain whose actions were all reduced or dropped queues no further marker. A send takes its place, and queues its anchor, when it begins: a `Store` reduces the sent action, and creates its interpreter task, in the MainActor job in which the send begins, before any job queued by then runs. The test store first reduces the buffered values a `Store` handled before the send (those delivered before it, their plain follow-ups, and the values of interpreter tasks that ran before the send began), then the sent action, whose plain follow-ups share the send's place, and only then starts, in anchor order, the effects of the drained actions whose anchors had not run when the send began; every value delivered from the send on stays buffered behind the sent action. This holds also when the drain suspends, as a drained walk of a throttle or a scheduled run does: the values other jobs deliver meanwhile come after the send's place, and the markers queued meanwhile run after the send's anchor. The test store follows the drained walk itself until it returns: a `Store` ran that interpreter task before the send began, and resumes it after its clock read or admission behind every MainActor job queued before it first ran, at the earliest at the position of the anchor's next level, which the test store takes for what the walk delivers after it first suspends; the drain reduces those values before the sent action. Work the walk starts in another task — a run, a composite child, a timer — delivers at its delivery: what it delivers from the send on is behind the sent action, which can cancel it, although a `Store`, which started that work when it reduced the drained action, typically reduced those values before the send, a known limitation since 6.0.x. Against MainActor jobs queued in a fixed order this is the only order a `Store` has, as long as no earlier interpreter walk of the `Store` is still suspended (below). Where the `Store` order is a race, such as a run's next emission against the interpreter task created while the follow-up of its previous emission is reduced, the test store's own scheduling decides it, and a test can receive either order. A `Store` also starts an interpreter walk only once the interpreter task it created before has finished, and a walk can suspend before it finishes: a throttle suspends to read its clock before it delivers anything, and a scheduled run (`.run(id:policy:)`) suspends while it waits for admission. MainActor jobs queued behind both tasks then run first. A test store models neither wait: a throttled value keeps the anchor's position, or its delivery order when the test store's clock read suspends, and the walk of an interpreter task created right behind a suspended one keeps its own anchor's position, so their order against other MainActor jobs can differ from a `Store`'s, a known limitation. Values delivered after a walk first suspends — every child of a `merge` or `concatenate`, runs, timers — values of independent effects and of other dispatches stay in delivery order. That includes a composite follow-up of a run's emission, whose first values a `Store` reduces before a following `merge` step of the emitting `concatenate`: a test that receives late can receive the `merge` children first, a known limitation. A cancellation applied while the test reduces a received or sent action removes the covered actions and outputs a `Store` would have delivered after it — after the action for its reduction and reduction-turn acceptance (for a sent action, after the send's place, which includes what a suspended drain let through), after its anchor for the synchronous part of its effect walk — except the values its own walk delivered. A cancellation the test issues — `cancelEffects(identifiedBy:)`, `cancelAllEffects()`, a `TestStoreDispatch.cancel()` or another dispatch cancellation, and the cancellation of remaining work when a drain times out or `finish()` fails — removes every covered buffered value: the test chooses the schedule in which it lands first. No other cancellation removes a delivered value: not the delivering effect's own continuation, another dispatch's effect, an asynchronous continuation, or a debounce, `latest` or throttle replacement outside such a reduction; a sent action's cancellation keeps every value delivered before the send began.

Root, scoped, and phase helper sends return one discardable TestStoreDispatch. Queued actions keep their dispatch activity until the receive reduction has registered follow-up work. Runtime completion is separate from unverified delivered outputs. Dispatch finish never consumes either queue, regardless of exhaustivity, and can be retried after explicit receive. Timeout/caller cancellation cancels only that dispatch and does not mark uncooperative physical work finished. Handles weakly reference their store. Non-exhaustive receiveOutput takes a ready matching output; before it skips a ready output that does not match, it reduces the buffered actions a `Store` reduced before that output, so it never skips an output a `Store` publishes after the expected one. Otherwise it advances intermediate actions using a non-consuming shared queue revision, preserving per-queue FIFO and one total deadline.

### Optional-child lifetime boundary

OptionalChildLifetime is an opt-in composition wrapper around the complete parent reducer. It observes child instance identity before and after child-first/parent-second reduction, resolves all lifetime changes synchronously, and invalidates old owners before action/output admission. Stable business identity does not imply instance lifetime. Namespaced effect IDs and composition paths isolate siblings and nested scopes, including the same reusable reducer under different Scope locations. Parent/sibling work keeps its own lifetime. Owners are reclaimed after outstanding work releases them; no unbounded tombstone history is maintained. Existing IfLet semantics are unchanged.
