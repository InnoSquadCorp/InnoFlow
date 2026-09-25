# InnoFlow

English | [한국어](./README.kr.md) | [日本語](./README.jp.md) | [简体中文](./README.cn.md)

> The English README is the canonical, most up-to-date version. The localized README files are companion entry points that summarize the framework and link back to the English source of truth.

InnoFlow is a SwiftUI-first unidirectional architecture framework for business and domain state transitions.

## InnoFlow 6.0.0

This source revision documents the 6.0.0 release candidate and target API.
Version 5.1.1 was the published stable baseline at candidate freeze; verify
the live 6.0.0 tag and GitHub Release status before treating it as published.

The framework now treats the following as source-of-truth principles:

- Official feature authoring declares the third reducer generic explicitly:
  use `Never` when no app-boundary output is emitted, or the feature's typed
  `Output` when it is.
- `@InnoFlow` features implement `Reducer` through `body`, and the macro generates the required `reduce(into:action:)` entry point from that composition.
- Composition happens through `Reduce`, `CombineReducers`, `Scope`, `IfLet`, `IfCaseLet`, and `ForEachReducer`.
- `PhaseTransitionGraph` is an opt-in validation layer, not a generic automata runtime.
- Binding remains explicit opt-in through `@BindableField`, and SwiftUI bindings use projected key paths such as `\.$step`.
- The `TestStore.exhaustivity` contract defaults to `.on`, requiring complete state-transition and effect-action assertions; uncancelled runtime effect errors always fail independently of that policy.
- Every `Store.send(_:)` returns a `FlowTask` that can finish or cancel only that dispatch's complete descendant effect tree.
- Reducers may emit typed, ephemeral `Output` values to a live app-boundary stream without putting navigation commands in restorable state.
- `Store` serializes effect cancellation and run-failure arbitration on the MainActor. Once cancellation wins, a late error from uncooperative work is not reclassified as `didFailRun`.
- InnoFlow owns business/domain transitions only.

Cross-framework ownership stays explicit:

- App-layer navigation state or another navigation library owns concrete route stacks.
- Transport and session lifecycle stay outside InnoFlow.
- Construction-time dependency graphs stay outside InnoFlow and enter reducers as explicit bundles.

Boundary references:

- [`docs/ADVANCED_AUTHORING.md`](docs/ADVANCED_AUTHORING.md) bridges dependencies, instrumentation, and cross-framework boundaries for non-trivial features
- [`docs/CROSS_FRAMEWORK.md`](docs/CROSS_FRAMEWORK.md) for navigation / transport / DI ownership
- [`docs/DEPENDENCY_PATTERNS.md`](docs/DEPENDENCY_PATTERNS.md) for reducer-facing dependency construction patterns
- [`MIGRATION.md`](MIGRATION.md) for 6.0.0 changes and prior release migrations
- [`docs/INSTRUMENTATION_COOKBOOK.md`](docs/INSTRUMENTATION_COOKBOOK.md) for `.sink`, `.osLog`, `.signpost`, and `.combined` examples
- [`docs/PERFORMANCE_BASELINES.md`](docs/PERFORMANCE_BASELINES.md) for maintainer baseline policy
- [`docs/FRAMEWORK_COMPARISON.md`](docs/FRAMEWORK_COMPARISON.md) for TCA, ReactorKit, ReSwift, and SwiftRex positioning
- [InnoFlow API reference](https://innosquadcorp.github.io/InnoFlow/documentation/innoflow/) for the facade, core runtime, composition, and phase symbols
- [InnoFlowTesting API reference](https://innosquadcorp.github.io/InnoFlow/testing/documentation/innoflowtesting/) for the public test harness, clock, and instrumentation symbols

For stable framework guarantees that should not drift with scorecards or line counts, see
[`ARCHITECTURE_CONTRACT.md`](./ARCHITECTURE_CONTRACT.md).

Project stewardship is documented in [`GOVERNANCE.md`](GOVERNANCE.md).
Before opening an issue or pull request, see [`SUPPORT.md`](SUPPORT.md),
[`CONTRIBUTING.md`](CONTRIBUTING.md), the
[`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md), and [`SECURITY.md`](SECURITY.md).

## Why InnoFlow over TCA?

TCA remains the stronger default when a team wants a broad application
architecture with integrated dependency management, navigation patterns,
testing conventions, and a large ecosystem. Choose InnoFlow when the framework
boundary should stay smaller: reducers own business transitions, dependencies
are constructor-injected bundles, navigation and transport stay at the app
boundary, and SwiftUI-specific conveniences live in the optional
`InnoFlowSwiftUI` product.

See [`docs/FRAMEWORK_COMPARISON.md`](docs/FRAMEWORK_COMPARISON.md) for the
longer comparison against TCA, ReactorKit, ReSwift, and SwiftRex.

## Installation

InnoFlow 6.0.0 requires a Swift 6.3 or newer toolchain and compiles all package
targets in Swift 6 language mode. The canonical sample and DocC workflow use
the same toolchain contract.

### Swift Package Manager

```swift
dependencies: [
  .package(url: "https://github.com/InnoSquadCorp/InnoFlow.git", from: "6.0.0")
]
```

```swift
.target(
  name: "YourDomain",
  dependencies: ["InnoFlowCore"]
),

.target(
  name: "YourSwiftUIApp",
  dependencies: ["InnoFlow", "InnoFlowSwiftUI"]
),

.testTarget(
  name: "YourAppTests",
  dependencies: ["InnoFlowCore", "InnoFlowTesting"]
)
```

Runtime-only feature and domain targets can depend on `InnoFlowCore` alone.
Use `InnoFlow` when a target needs the `@InnoFlow` macro; it reexports
`InnoFlowCore` and owns the macro declarations. SwiftUI app targets should also
depend on `InnoFlowSwiftUI`, which provides
`Store.binding`, `ScopedStore.binding`, `Store.preview`, and
`EffectTask.animation(Animation?)` without making the core runtime import
SwiftUI. `InnoFlowSwiftUI` and `InnoFlowTesting` reexport `InnoFlowCore`, but
macro users must still import `InnoFlow` directly.

For compiler-plugin trust, SwiftSyntax prebuilt fallback, sandbox policy, CI
flags, cache keys, and the intentional `InnoFlowCore` recovery path, see
[`docs/MACRO_OPERATIONS.md`](docs/MACRO_OPERATIONS.md).

### Known toolchain workarounds (Swift 6.3)

`Store.deinit` and `TestStore.deinit` are annotated with `@_optimize(none)` to
sidestep a Swift 6.3 release-mode SIL crash in `EarlyPerfInliner`
([swiftlang/swift#88173](https://github.com/swiftlang/swift/issues/88173))
that triggers when the compiler tries to inline the generic `R.Action`-typed
deinit. The deinit path is not a hot loop — the lost optimization is
negligible — and `@MainActor isolated deinit` semantics are unchanged. If your
own consumer crashes during release builds with a similar SIL trace, see
[`docs/SWIFT_TOOLCHAIN_TRACKING.md`](docs/SWIFT_TOOLCHAIN_TRACKING.md) for the
retest procedure and removal trigger. The principle gates also emit a
non-blocking warning on Swift 6.4+ so the workaround does not silently outlive
the upstream fix.

## Quick Start

### Define a feature

```swift
import InnoFlow

@InnoFlow
struct CounterFeature {
  struct State: Equatable, Sendable, DefaultInitializable {
    var count = 0
    @BindableField var step = 1
  }

  enum Action: Equatable, Sendable {
    case increment
    case decrement
    case setStep(Int)
  }

  var body: some Reducer<State, Action, Never> {
    Reduce { state, action in
      switch action {
      case .increment:
        state.count += state.step
        return .none

      case .decrement:
        state.count -= state.step
        return .none

      case .setStep(let step):
        state.step = max(1, step)
        return .none
      }
    }
  }
}
```

### Use it in SwiftUI

```swift
import InnoFlow
import InnoFlowSwiftUI
import SwiftUI

struct CounterView: View {
  @State private var store: Store<CounterFeature>

  init(store: Store<CounterFeature> = Store(reducer: CounterFeature())) {
    _store = State(initialValue: store)
  }

  var body: some View {
    VStack(spacing: 20) {
      Text("Count: \(store.count)")
        .font(.largeTitle)

      HStack(spacing: 24) {
        Button("−") { store.send(.decrement) }
        Button("+") { store.send(.increment) }
      }

      Stepper(
        "Step: \(store.step)",
        value: store.binding(\.$step, to: CounterFeature.Action.setStep)
      )
    }
  }
}
```

`binding(_:to:)` is the canonical spelling. `binding(_:send:)` and existing trailing-closure calls such as `store.binding(\.$step) { .setStep($0) }` are semantically identical compatibility spellings that stay supported without deprecation; prefer `to:` in new code.

## Composition Surface

The InnoFlow 6.0 development line uses a small composition surface instead of multiple authoring styles.

### `Reduce`

`Reduce` is the closure-backed primitive reducer.

```swift
Reduce<State, Action, Never> { state, action in
  // mutate state
  // return EffectTask<Action>
}
```

### `CombineReducers`

`CombineReducers` runs reducers in declaration order and merges child effects.

```swift
var body: some Reducer<State, Action, Never> {
  CombineReducers {
    Reduce { state, action in
      // parent logic
      .none
    }

    AnalyticsReducer()
  }
}
```

### `Scope`

`Scope` lifts child state, child action, and child effects into a parent reducer space.
Scoped child state must conform to `Equatable`. The reducer primitive and runtime projection API
are separate: `Store.scope(state:action:)` returns a `ScopedStore` that caches the latest child
snapshot, refreshes during the parent store's action drain, and only invalidates observers when the
child snapshot actually changes.
Repeated `Store.scope(state:action:)` calls from the same source location reuse the same live
projection when their state key path, child types, and `CasePath` identity match. The cache is weak,
so discarding every external reference still releases the `ScopedStore`; constructing a new
`CasePath` explicitly creates a separate projection instead of reusing an outdated action transform.
Macro-generated paths keep a stable identity even when generic or extension contexts require a
computed static accessor.
Collection scoping retains one active ID-keyed row family per collection key path. It reuses that
family across source locations when the child types and `CollectionActionPath` identity match;
changing that signature replaces the whole family. Previously returned rows keep their original
action transform, while newly scoped rows route through the new path. Repeated macro-generated path
access preserves row identity; an explicitly reconstructed path is an intentional safe replacement.
Public scoping APIs use `CasePath` and `CollectionActionPath` exclusively. Closure-based action lifting is kept internal to the framework implementation.

```swift
var body: some Reducer<State, Action, Never> {
  CombineReducers {
    Reduce { state, action in
      switch action {
      case .load:
        state.isLoading = true
        return .send(.child(.start))
      case .child(.finished):
        state.isLoading = false
        return .none
      }
    }

    Scope(
      state: \.child,
      action: .childCasePath,
      reducer: ChildFeature()
    )
  }
}
```

When `@InnoFlow` is attached, the matching `Action` case path is synthesized automatically:

```swift
@InnoFlow
struct ParentFeature {
  enum Action: Equatable, Sendable {
    case child(ChildFeature.Action)
  }
}
```

That declaration gives you `ParentFeature.Action.childCasePath` automatically. Likewise,
`case todo(id: ID, action: ChildAction)` synthesizes `todoActionPath`, and a single unlabeled
payload case such as `case _loaded(Output)` synthesizes `loadedCasePath`.

Labeled and multi-payload cases outside those standard patterns are not synthesized. If one needs
a custom path, declare `static let <caseName>CasePath` inside `Action`; `@InnoFlow` recognizes the
canonical name and suppresses its unsupported-shape warning. If the case intentionally has no path,
or its manual path must live in an extension, annotate the enum case with
`@InnoFlowCasePathIgnored`. That marker opts the case out of both synthesis and the warning.
The canonical static variable name is the syntactic manual-path signal, so its value may use a
`CasePath` typealias or factory.

### `IfLet`

`IfLet` runs a child reducer only while optional child state is present. Child actions still use the
same lifted parent `Action` case path as `Scope`.

```swift
IfLet(
  state: \.child,
  action: .childCasePath,
  reducer: ChildFeature()
)
```

When the optional state is `nil`, child actions are ignored in release builds and asserted in debug builds.

### `IfCaseLet`

`IfCaseLet` runs a child reducer only while enum parent state matches a specific case. State matching is
expressed with a `CasePath` and action lifting still uses the synthesized child action path.

```swift
static let detailState = CasePath<State, DetailFeature.State>(
  embed: State.detail,
  extract: { state in
    guard case .detail(let childState) = state else { return nil }
    return childState
  }
)

IfCaseLet(
  state: Self.detailState,
  action: .childCasePath,
  reducer: DetailFeature()
)
```

### `ForEachReducer`

`ForEachReducer` is the declarative collection companion to `Scope`. It routes row actions with a
`CollectionActionPath` while preserving the same row identity, stale-row contract, and revision
cache that power runtime collection scoping.

```swift
ForEachReducer(
  state: \.todos,
  action: .todoActionPath,
  reducer: TodoRowFeature()
)
```

### `SelectedStore`

`SelectedStore` is a read-only derived projection for expensive `Equatable` read models. Use it when
you want a view to refresh only when the selected value actually changes.
Dynamic-member reads are SwiftUI view-body conveniences: they diagnose stale
ownership in debug and use the last cached snapshot in optimized builds. Use
`requireAlive()` when liveness is a precondition, or `optionalValue` when a
released projection should be handled as absence.

```swift
let summary = store.select { state in
  DashboardSummary(
    title: state.profile.name,
    isReady: state.permissions.isReady && state.profile.isReady
  )
}

Text(summary.title)
```

When the derived value depends on a single explicit slice of state, use the
dependency-annotated overload so InnoFlow can keep the selection on a selective-refresh bucket:

```swift
let summary = store.select(dependingOn: \.profile) { profile in
  ProfileSummary(name: profile.name, canEdit: profile.isAdmin)
}
```

```swift
let badge = store.select(dependingOnAll: \.profile, \.permissions) { profile, permissions in
  DashboardBadge(
    title: profile.name,
    isReady: profile.isReady && permissions.isReady
  )
}
```

For projections that depend on two or more slices, use
`select(dependingOnAll:)` with a comma-separated list of key paths. The
parameter-pack overload preserves explicit dependency tracking without falling
back to always-refresh selection regardless of arity:

```swift
let summary = store.select(
  dependingOnAll: \.a, \.b, \.c, \.d, \.e, \.f, \.g
) { a, b, c, d, e, f, g in
  Summary(a, b, c, d, e, f, g)
}
```

`select { state in ... }` remains available as an always-refresh fallback because InnoFlow cannot
infer which fields a general closure reads. Use it when the dependency cannot be expressed as
typed key paths or when always-refresh behavior is intentional.

Closure-based selections (including `dependingOn:`, `dependingOnAll:`, and
`memoize:`) are independent on every call by default: a shared source line
does not prove that their captured inputs have the same meaning. To reuse a
live selection from the same call site, pass a stable semantic `id` that
includes every captured input that can affect the result:

```swift
let rowSummary = store.select(dependingOn: \.rows, id: "row-\(rowID)") { rows in
  rows.first { $0.id == rowID }?.summary
}
```

The explicit-ID cache is weak; retain the `SelectedStore` when identity must
survive repeated view evaluations. Key-path-only `select(\.phase)` keeps its
existing stable cache behavior.

Use `SelectedStore` for read-only projections. Keep mutable child flows on `ScopedStore`.

## Dependency Integration

Keep dependency ownership outside `InnoFlow` and pass constructor-time bundles into reducers.

See [`docs/DEPENDENCY_PATTERNS.md`](docs/DEPENDENCY_PATTERNS.md) for the canonical single-service / composite-bundle / framework-provided-clock patterns, the three test-substitution scenarios, and the anti-patterns InnoFlow explicitly rejects.

```swift
import InnoFlow

@InnoFlow
struct ProfileFeature {
  struct Dependencies: Sendable {
    let apiClient: any APIClientProtocol
    let logger: any LoggerProtocol
  }

  struct State: Equatable, Sendable, DefaultInitializable {
    var name = ""
    var errorMessage: String?
  }

  enum Action: Equatable, Sendable {
    case load
    case _loaded(String)
    case _failed(String)
  }

  let dependencies: Dependencies

  init(dependencies: Dependencies) {
    self.dependencies = dependencies
  }

  var body: some Reducer<State, Action, Never> {
    Reduce { state, action in
      switch action {
      case .load:
        state.errorMessage = nil
        let apiClient = dependencies.apiClient
        let logger = dependencies.logger
        return .run { send, context in
          do {
            try await context.checkCancellation()
            logger.log("Loading profile")
            let name = try await apiClient.fetchName()
            try await context.checkCancellation()
            await send(._loaded(name))
          } catch is CancellationError {
            return
          } catch {
            await send(._failed(String(describing: error)))
          }
        }
      case ._loaded(let name):
        state.name = name
        return .none
      case ._failed(let message):
        state.errorMessage = message
        return .none
      }
    }
  }
}

@MainActor
func makeProfileStore() -> Store<ProfileFeature> {
  let feature = ProfileFeature(
    dependencies: .init(
      apiClient: APIClient.live,
      logger: Logger.live
    )
  )
  return Store(reducer: feature)
}
```

If a SwiftUI view owns environment-specific values, resolve them in the view layer and forward the
derived bundle or action into the reducer.

This keeps reducer dependencies explicit:

- the app or coordinator owns the `AppContainer`
- `Dependencies(container:)` snapshots the bundle at construction time
- the reducer stores `let dependencies: Dependencies`
- `.run` captures the dependencies it needs explicitly

### `EffectTask.map`

`Scope` relies on `EffectTask.map` to lift child effects while preserving cancellation, debounce, throttle, and animation semantics.

### Dispatch lifetimes and reducer output

`Store.send(_:)` and `ScopedStore.send(_:)` return a `FlowTask`. Direct UI
sends can ignore the discardable result. Coordinators and SwiftUI `.task`
closures can wait for, or cancel, only the complete action tree they started:

```swift
let task = store.send(.load)
await task.finish()

let search = store.send(.search(query))
search.cancel()
await search.finish()
```

A reducer may declare an `Output` for one-shot app-boundary intent. Subscribe
before sending because `outputs()` is live and non-replaying; renderable or
restorable data still belongs in `State`.

```swift
@InnoFlow
struct DetailFeature {
  struct State: Equatable, Sendable, DefaultInitializable {
    init() {}
  }

  enum Action: Equatable, Sendable {
    case done
  }

  enum Output: Equatable, Sendable {
    case dismiss
  }

  var body: some Reducer<State, Action, Output> {
    Reduce { _, action in
      switch action {
      case .done:
        return Self.output(.dismiss)
      }
    }
  }
}

var outputs = store.outputs().makeAsyncIterator()
await store.send(.done).finish()
#expect(await outputs.next() == .dismiss)
```

When a coordinator needs output from one specific dispatch, capture it
atomically instead of filtering the store-wide broadcast. The capture is
installed before the action is enqueued, includes synchronous root output and
all descendant effects, and finishes with that action tree:

```swift
let task = store.send(.done, capturingOutputs: .unbounded)
var outputs = task.outputs.makeAsyncIterator()

await task.finish()
#expect(await outputs.next() == .dismiss)
#expect(await outputs.next() == nil)
```

`OutputFlowTask.outputs` is single-consumer. Its buffering policy is required
at the call site because bounded loss is a domain decision. Store-wide
`outputs()` remains the live broadcast for long-lived coordinators.
Cancelling a task awaiting captured outputs also cancels that dispatch's effect
tree, so a `for await` consumer in SwiftUI `.task` follows the view lifetime.
Normal stream completion does not cancel anything; cancelling a store-wide
broadcast subscriber does not cancel dispatches. If you exit iteration with
`break` while retaining the capture, call `task.cancel()` explicitly to stop work.

Use `mapOutput(_:)` where a child output becomes a parent output. In tests,
consume it with `receiveOutput(_:)`; exhaustive `finish()` reports any output
left unhandled.

A child with `Output == Never` needs no artificial output or impossible mapping
closure. Use `ChildFeature().promoteOutput(to: Output.self)` at the composition
boundary. The same helper on `EffectTask<Action>` reuses output-free effect
helpers inside a typed-output reducer. Promotion is unavailable for real output
types, so it cannot silently discard child events.

Outputs need only be `Sendable`, not `Equatable`. `TestStore` also supports
`receiveOutput(where:description:timeout:)` to return a matching output and
`receiveOutput(_:caseName:timeout:)` with a `CasePath` to extract its payload.
All three forms enforce ordering in exhaustive mode, skip mismatches according
to the non-exhaustive policy, and share one total wall-clock timeout. A cancelled
receive returns without reporting a false timeout.

## Effect Model

`ReducerEffect<Action, Output>` is the complete effect DSL.
`EffectTask<Action>` remains its source-friendly `Output == Never` alias for
reducers that emit no app-boundary output:

- `.none`
- `.send(action)`
- `.run { send, context in ... }`
- `.perform(operation:success:failure:)`
- reducer-typed `Self.output(value)`
- `.run { context in asyncSequence }`
- `.run(sequence:transform:)`
- `.merge(...)`
- `.concatenate(...)`
- `.cancel(id)`
- `.cancellable(id:cancelInFlight:)`
- `.debounce(id:for:)`
- `.throttle(id:for:leading:trailing:)`
- `.animation(_:)`

`EffectID<RawValue>` accepts any `Hashable & Sendable` raw value, so cancellation IDs can be
string literals, dynamic strings, UUIDs, or domain-specific key types. Use `StaticEffectID` for the
common string-literal case:

```swift
let refreshID: StaticEffectID = "refresh"
let sessionID = EffectID(session.uuid)
```

Built-in Console and Instruments adapters redact cancellation-ID descriptions
by default. Opt in with `includeCancellationIDs: true` only when those values
are safe to expose outside the process.

`EffectContext` exposes the store clock inside `.run`, so time-sensitive effects can stay deterministic
in both runtime code and tests:

```swift
return .run { send, context in
  do {
    try await context.sleep(for: .milliseconds(300))
    try await context.checkCancellation()
    await send(.finished)
  } catch is CancellationError {
    return
  }
}
```

The older `.run { send in ... }` overload still works, but new code should prefer
`context.sleep(for:)` and `context.checkCancellation()` over `Task.sleep(...)` plus ad-hoc
cancellation checks. If an effect needs a non-throwing probe, call
`await context.isCancellationRequested()`; it uses the same store/runtime boundary as
`checkCancellation()`.

Store deinit and explicit effect cancellation are still cooperative. InnoFlow guarantees
that late emissions are dropped immediately, but runtime teardown continues as best-effort
async cleanup. Long-running work should call `checkCancellation()` around suspension points
if it needs prompt shutdown.

Operational logging stays lightweight on purpose. Use `StoreInstrumentation.osLog(...)` for a
default log sink, `StoreInstrumentation.signpost(...)` for Instruments timelines, or fan out
vendor-specific counters and traces through `StoreInstrumentation.sink(...)` and `combined(...)`.
That is the intended extension point for Datadog, Prometheus bridges, or `swift-metrics` wrappers:

```swift
let instrumentation: StoreInstrumentation<Feature.Action> = .combined(
  .osLog(logger: logger),
  .sink { event in
    switch event {
    case .runStarted:
      metrics.increment("feature.effect.run_started")
    case .runFinished:
      metrics.increment("feature.effect.run_finished")
    case .actionEmitted(let actionEvent):
      metrics.increment("feature.effect.emitted", tags: ["action": "\(actionEvent.action)"])
    case .actionDropped(let actionEvent):
      metrics.increment("feature.effect.dropped", tags: ["reason": "\(actionEvent.reason)"])
    case .actionQueueDrained(let queueEvent):
      metrics.gauge("feature.action_queue.high_water", value: queueEvent.pendingActionHighWaterMark)
    case .effectsCancelled:
      metrics.increment("feature.effect.cancelled")
    case .runFailed:
      metrics.increment("feature.effect.failed")
    }
  }
)
```

If a team standardizes on one backend later, prefer an optional ecosystem package such as
`InnoFlowMetrics` over adding vendor dependencies to the core package graph.
For concrete adapter examples, see [`docs/INSTRUMENTATION_COOKBOOK.md`](docs/INSTRUMENTATION_COOKBOOK.md).

Every reducer output also emits a payload-free `outputDelivered` event. It
reports live subscriber counts, `AsyncStream` enqueues/drops/terminations,
dispatch-capture disposition, and cancellation suppression without exposing
the output value. `StoreInstrumentationMetricsCollector` aggregates those
signals through `outputDelivered`, `outputWithoutSubscribers`,
`outputSubscriberDrops`, `outputDispatchCaptureDrops`, and
`outputSuppressedByCancellation`.

### Ordering contract

Store dispatch is queue-based.

- `.send` emits an immediate follow-up action, but it is queued rather than reducer-reentrant.
- `.run` emits actions after its async boundary, and those actions re-enter the same queue.
- `.concatenate` preserves declared effect order.
- `.merge` observes child completion order, not declaration order.
- The queue never drops or collapses actions. It compacts consumed prefixes during long drains and
  retains at most 64 KiB of reusable queue storage after a drain; larger allocations are released.
- `StoreInstrumentation.ActionQueueEvent` reports per-drain pending/storage high-water marks and
  whether excess retained capacity was released. Use domain-level throttle, debounce, or batching
  when the pending high-water indicates producer back-pressure.

## Phase Validation

`PhaseMap` is the canonical way to declare domain phase transitions. It wraps a base reducer as a
post-reduce decorator, computes the next phase from the final reducer state plus the current action,
and exposes `derivedGraph` so the same contract remains available as a `PhaseTransitionGraph`.
For a full sample-backed walkthrough, see [`PhaseDrivenWalkthrough.md`](./Sources/InnoFlow/InnoFlow.docc/PhaseDrivenWalkthrough.md).

```swift
@InnoFlow(phaseManaged: true)
struct ProfileFeature {
  struct State: Equatable, Sendable, DefaultInitializable {
    enum Phase: Hashable, Sendable {
      case idle
      case loading
      case loaded
      case failed
    }

    var phase: Phase = .idle
    var profile: UserProfile?
    var errorMessage: String?
  }

  enum Action: Equatable, Sendable {
    case load
    case _loaded(UserProfile)
    case _failed(String)
  }

  static var phaseMap: PhaseMap<State, Action, State.Phase> {
    PhaseMap(\.phase) {
      From(.idle) {
        On(.load, to: .loading)
      }
      From(.loading) {
        On(Action.loadedCasePath, to: .loaded)
        On(Action.failedCasePath, to: .failed)
      }
      From(.failed) {
        On(.load, to: .loading)
      }
    }
  }

  static var phaseGraph: PhaseTransitionGraph<State.Phase> {
    phaseMap.derivedGraph
  }

  var body: some Reducer<State, Action, Never> {
    Reduce { state, action in
      switch action {
      case .load:
        state.errorMessage = nil
        return .none
      case ._loaded(let profile):
        state.profile = profile
        return .none
      case ._failed(let message):
        state.errorMessage = message
        return .none
      }
    }
  }
}
```

Use these rules:

- `PhaseMap` owns the declared phase key path; base reducers should not mutate it directly.
- Matching transitions are evaluated against the previous phase after the base reducer finishes.
- The first matching `On` rule wins. Returning `nil` from a guard means “consume the action, keep the current phase”.
- `PhaseMap` remains partial by default. Unmatched phase/action pairs are legal no-ops unless a team opts into stricter validation in tests.
- `@InnoFlow(phaseManaged: true, strictPhaseTotality: true)` makes every
  directly declared `Phase` case appear as a static `From` source or `On`
  target at compile time. Predicate and payload semantics still require
  `requireComplete(...)` tests.
- `PhaseTransitionGraph` remains a topology validation tool, not a general state-machine runtime.
- `validatePhaseTransitions(...)` still exists for backward compatibility, but new examples should prefer `PhaseMap`.
- Generated action path members strip one leading underscore, so `_loadedCasePath` becomes `loadedCasePath`.
- Prefer `On(CasePath, ...)` when the action carries meaningful payload, `On(.equatableAction, ...)` for simple events, and keep `On(where:)` as an escape hatch when the trigger cannot be expressed cleanly otherwise.
- Adopt `PhaseMap` when a feature already has a phase enum, legal transitions are part of the business contract, and imperative `state.phase = ...` updates are spreading across multiple reducer branches.

Design rationale:

- `PhaseTransitionGraph` stays focused on static topology checks such as reachability, unknown successors, and terminal validation.
- `PhaseMap` owns runtime phase movement and conditional resolution after the reducer has finished mutating non-phase state.
- Guard-bearing graph metadata remains intentionally out of scope.
- `@InnoFlow(phaseManaged: true)` keeps the name-based unreferenced-case
  warning. Adding `strictPhaseTotality: true` promotes that declaration check
  to an error; neither mode claims graph reachability, arbitrary predicate, or
  payload-domain exhaustiveness.

If you need the reasoning behind those boundaries, see
[ADR-phase-transition-guards](./docs/adr/ADR-phase-transition-guards.md),
[ADR-declarative-phase-map](./docs/adr/ADR-declarative-phase-map.md), and
[ADR-phase-map-totality-validation](./docs/adr/ADR-phase-map-totality-validation.md).

For static graph checks, build a report from `phaseMap.derivedGraph`:

```swift
let report = ProfileFeature.phaseGraph.validationReport(
  allPhases: [.idle, .loading, .loaded, .failed],
  root: .idle,
  terminalPhases: [.loaded]
)

precondition(report.issues.isEmpty)
```

If a team wants stricter trigger coverage without changing runtime behavior, add an opt-in
validation pass in tests:

```swift
let totalityReport = assertPhaseMapCovers(
  ProfileFeature.phaseMap,
  expectedTriggersByPhase: [
    .idle: [.action(.load)],
    .loading: [
      .casePath(ProfileFeature.Action.loadedCasePath, label: "loaded", sample: .fixture),
      .casePath(ProfileFeature.Action.failedCasePath, label: "failed", sample: "boom")
    ]
  ]
)

#expect(totalityReport.isEmpty)
```

This helper validates only the triggers you explicitly declare. It does not change `PhaseMap`
runtime semantics, and unmatched actions remain legal no-ops by default.

## Testing

`InnoFlowTesting` provides `TestStore` for deterministic reducer tests.
`TestStore.exhaustivity` defaults to `.on`: every reducer state mutation must
appear in the matching `send` or `receive` assertion, and every effect-emitted
action must be consumed with `receive`. Omitting an assertion closure means
"the state does not change," not "skip state checking."

```swift
import InnoFlowTesting
import Testing

@Test
@MainActor
func loadFlow() async {
  let store = TestStore(reducer: ProfileFeature())

  let phaseMap: PhaseMap<ProfileFeature.State, ProfileFeature.Action, ProfileFeature.State.Phase> =
    ProfileFeature.phaseMap

  await store.send(.load, through: phaseMap) {
    $0.phase = .loading
  }

  // The reducer's `.load` branch returns `.none`; send the result explicitly.
  await store.send(._loaded(.fixture), through: phaseMap) {
    $0.phase = .loaded
    $0.profile = .fixture
  }

  await store.finish()
}
```

`finish()` is the terminal test assertion. With exhaustive mode `.on`, it waits
for all framework-owned effects and fails when any emitted action was not
received. With `.off`, it reduces buffered, late, and follow-up actions until
the harness is idle. Its timeout uses wall time and never advances a
`ManualTestClock`, so advance manual time before finishing when a debounce or
active throttle window (including leading-only) remains, or cancel that work
before finishing. A scoped test store delegates `finish()` to the same parent
queue and effect lifecycle. Use
`assertNoBufferedActions()` only as an intermediate, immediate queue
checkpoint. The ambiguous `assertNoMoreActions()` API was removed in 6.0.0
after its 5.x deprecation window.

An `AsyncSequence` consumed by `EffectTask.run` may terminate with
`CancellationError` normally. Any other error from an active run is a hard
`TestStore` failure, reported once at the `send` or `receive` assertion that
created the effect even when debounce, throttle, animation, or composition
delays the run. This runtime-error contract also applies when `exhaustivity` is
`.off`. If the host accepts cancellation first, a late domain error from
uncooperative work is discarded instead of being reclassified as a run
failure.

If a `TestStore` leaves scope with valid buffered actions or active
framework-owned effects, deinitialization provides a synchronous safety net.
It records one failure in `.on`, one non-failing warning in
`.off(showSkippedAssertions: true)`, and remains silent in `.off`. The safety
net cancels remaining work but neither waits for effects nor reduces buffered
actions, and it does not report an idle store merely because `finish()` was
omitted. A completed or failed `finish()` is not reported again during
deinitialization unless new work begins or arrives afterward.

For migration or intentionally partial tests, opt out explicitly:

```swift
store.exhaustivity = .off(showSkippedAssertions: true)
```

In `.off` mode, assertion closures start from the actual post-reducer state and
therefore describe only the fields being checked. Unexpected effect actions
are reduced by `send`, `receive`, and `finish`, and
`showSkippedAssertions: true` reports non-failing warnings for skipped state,
action, or terminal assertions. Deinitialization itself never reduces actions.

Each receive assertion can override the harness timeout. Case-path and
predicate overloads also support actions that are not `Equatable`. In `.on`
mode, a valid mismatch is reduced once and then reported immediately. In
`.off` mode, mismatches are reduced while the receive continues searching for
the requested action under one total wall-clock deadline.

```swift
await store.receive(.finished, timeout: .milliseconds(250)) {
  $0.phase = .finished
}

let payload = await store.receive(
  Feature.Action.loadedCasePath,
  caseName: "loaded",
  timeout: .seconds(1)
) { state, payload in
  state.value = payload
}

let action = await store.receive(
  where: { $0.isSuccessfulResponse },
  description: "successful response"
) { state, _ in
  state.phase = .finished
}
```

The timeout is one wall-clock budget even when cancelled effect actions are
discarded. Cancelling the waiting task removes its queue waiter without
consuming actions delivered afterward. For an optional case-path payload, the
return value is intentionally nested (`Payload??`) so a matched `nil` remains
distinct from mismatch, timeout, or cancellation.

State mismatch diagnostics now include a `Diff:` section before full expected/actual dumps. The renderer shows 12 lines by default, can be overridden per harness with `TestStore(..., diffLineLimit: 24)`, and also respects `INNOFLOW_TESTSTORE_DIFF_LINE_LIMIT`.

For deeply composed reducers, project the parent `TestStore` instead of creating an independent child harness:

```swift
let store = TestStore(reducer: ParentFeature())
let child = store.scope(state: \.child, action: ParentFeature.Action.childCasePath)

await child.send(.start) {
  $0.phase = .loading
}

await child.receive(.finished) {
  $0.phase = .loaded
}

await child.finish()
```

That projection assumes `ParentFeature.Action.childCasePath`, which `@InnoFlow` now synthesizes for matching single-payload child action cases.
Exhaustive scoped assertions still compare the complete root state. When a
child action intentionally changes parent or sibling state, assert that action
through the parent `TestStore`.
Collection-scoped projections keep per-element `ScopedStore` identity stable by `id`, and row observers only invalidate when their own element snapshot changes.
If an element is removed, discard any old row-scoped handle and recreate projections from the parent store. Observation invalidates tracked `isAlive`, `optionalState`, and `optionalValue` reads for the removed projection without invalidating surviving sibling rows. `ScopedStore.state` and projection dynamic-member reads keep a cached snapshot fallback for SwiftUI observer races, stale scoped sends become no-ops when the projection is dead, and non-UI callers should use `optionalState` / `optionalValue` for graceful absence or `requireAlive()` when a dead projection is a programmer error. `ScopedTestStore` keeps the testing contract louder and traps stale direct access via `preconditionFailure`.

For store-level debounce and throttle tests, inject a `StoreClock`:

```swift
let clock = ManualTestClock()
let store = Store(
  reducer: ProfileFeature(),
  initialState: .init(),
  clock: .manual(clock)
)
```

Collection-scoped testing uses an element id and shares the same parent queue. Element removal is still asserted at the parent `TestStore` level.

```swift
let todo = store.scope(
  collection: \.todos,
  id: targetID,
  action: ParentFeature.Action.todoActionPath
)

await todo.send(.setIsDone(true)) {
  $0.isDone = true
}
```

For expensive derived read-models, prefer `SelectedStore` over ad-hoc recomputation:

```swift
let status = store.select(\.phase)
#expect(status.requireAlive() == .idle)
```

If the read model is derived from a single explicit `Equatable` slice, use the
dependency-annotated form; for two or more slices use the variadic
`select(dependingOnAll:)`:

```swift
let title = store.select(dependingOn: \.child.title) { $0.uppercased() }
#expect(title.requireAlive() == "CHILD")
```

## Canonical Sample

The single reference app is [`Examples/InnoFlowSampleApp`](./Examples/InnoFlowSampleApp).

It contains ten demos:

- `Basics`
- `Orchestration`
- `Phase-Driven FSM` (`@InnoFlow(phaseManaged: true)` + `PhaseMap`)
- `App-Boundary Navigation`
- `Authentication Flow`
- `List-Detail Pagination`
- `Offline-First`
- `Realtime Stream`
- `Form Validation`
- `Bidirectional WebSocket`

This sample is the official integration reference for `InnoFlow`-only flows, explicit dependency
bundles, app-owned SwiftUI navigation state, and explicitly labeled cross-framework transport
integration.

The sample hub also defines the stable accessibility identifiers used by UI smoke tests:

- `sample.basics`
- `sample.orchestration`
- `sample.phase-driven-fsm`
- `sample.router-composition`
- `sample.authentication-flow`
- `sample.list-detail-pagination`
- `sample.offline-first`
- `sample.realtime-stream`
- `sample.form-validation`
- `sample.bidirectional-websocket`

Launch-environment direct demo mode (`INNOFLOW_SAMPLE_DEMO`) remains available for feature-focused UI regression tests.

## SwiftUI Integration Guidance

- Resolve `@Environment` values in the view layer, then forward the derived action or dependency value into the reducer.
- Prefer explicit nested `Dependencies` bundles over repeated ad-hoc captures in view code.
- Prefer stable `accessibilityIdentifier(...)` values on sample and test-targeted controls.
- Add explicit VoiceOver labels and hints when button text or dense layouts do not fully describe the action.
- Prioritize explicit accessibility metadata on demo hub rows, modal dismiss actions, and long-running or destructive controls where context can be ambiguous in VoiceOver.
- Prefer system controls and Dynamic Type-friendly layouts over custom fixed-size controls.
- Use `SelectedStore` only for expensive read-only derived values. Use `select(dependingOn:)` for a single explicit state slice and the variadic `select(dependingOnAll:)` for two or more slices; reserve plain `select { ... }` for the always-refresh fallback. Keep mutable child flows on `ScopedStore`.
- A closure selection has independent identity unless it has an explicit semantic `id` covering its captured inputs; retain an ID-keyed selection when stable view identity matters.
- Use `Store.preview(...)` as the default path for preview and accessibility review passes so preview-only setup never changes production store wiring.

## Cross-framework notes

- Keep direct composition at the app/coordinator boundary.
- Do not duplicate concrete route stacks inside feature state.
- Reducers emit business intent; the app layer owns navigation state and dependency construction.
- Retry, reconnect, websocket, and transport/session lifecycle stay outside `PhaseTransitionGraph`.
- Use [`docs/CROSS_FRAMEWORK.md`](./docs/CROSS_FRAMEWORK.md) as the single ownership guide for
  navigation, transport, and DI boundaries.
- Use [`docs/DEPENDENCY_PATTERNS.md`](./docs/DEPENDENCY_PATTERNS.md) when the question is
  specifically about reducer-facing `Dependencies` bundles.

## 6.0 orchestration and verification

Use scheduled runs when independent dispatches contend for one Store-local
resource. Admission is ordered when the Store receives the effect, not when an
unstructured task happens to start:

```swift
return .run(
  id: EffectID("save"),
  policy: .serial(maxPending: 2),
  onAdmission: { .saveAdmission($0) }
) { send, context in
  // Send success or failure actions explicitly.
}
```

`.latest` cooperatively cancels displaced work, `.dropWhileRunning` reports
`.rejected(.busy)`, and bounded serial lanes report queue overflow. A serial
lane advances after the current run closure physically returns. These policies
do not provide persistence transactions, retries, rollback, or exactly-once
delivery.

Group caller-owned dispatches without introducing SwiftUI into the core:

```swift
await withFlowScope { scope in
  let profile = await scope.track(store.send(.loadProfile))
  let permissions = await scope.track(store.send(.loadPermissions))
  await profile.finish()
  await permissions.finish()
}
```

For production diagnostics, pass an opt-in `StoreDiagnostics(capacity:)` to a
Store and inspect bounded, payload-free snapshots keyed by `DispatchID`. For
tests, attach post-reduction `TestStoreInvariant` values and reusable
`TestStoreScenario` scripts. `@InnoFlow` also synthesizes supported `Output`
case paths, including optional payloads, for root and scoped output assertions.

See [MIGRATION.md](./MIGRATION.md),
[the orchestration ADR](./docs/adr/ADR-effect-admission-and-flow-lifetime.md),
and [the instrumentation cookbook](./docs/INSTRUMENTATION_COOKBOOK.md) for the
complete ownership and privacy boundaries.

## Roadmap

The core architecture is stable. Remaining work is conditional roadmap material, not required
redesign.

- **Dynamic PhaseMap semantic totality** — strict macro mode now proves direct
  phase declaration coverage at compile time, while `requireComplete(...)`
  validates explicit sample triggers. Arbitrary predicates, helper-built DSL,
  and payload domains remain runtime semantics and are not falsely presented
  as compiler-proven.
- **Opaque selector memoization** — explicit key-path dependencies are covered by `select(dependingOn:)`
  for a single slice and the variadic `select(dependingOnAll:)` for two or more slices. Memoizing
  arbitrary closure selectors remains future work because general closures do not expose their read set.
- **Optional metrics ecosystem package** — `StoreInstrumentation.sink(...)`, `.osLog(...)`,
  `.signpost(...)`, and `.combined(...)` are the supported extension points today. If a standard backend emerges, an
  optional `InnoFlowMetrics`-style package can sit on top without changing the core graph.
- **PhaseMap adoption expansion** — `PhaseMap` is the canonical path for phase-heavy features, but
  further migration should follow real feature demand rather than sample-driven expansion.
- **Accessibility and documentation polish** — sample/docs coverage can continue to improve, but
  this is product polish rather than a missing core capability.
- **Scoped phase examples** — the canonical sample now covers phase-managed authoring; additional
  payment, permission, or onboarding examples should be added when real product flows need them.

## Development

Use these commands locally:

```bash
swift test --package-path .
swift test --package-path Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage --jobs 1
xcodebuild -jobs 1 -project Examples/InnoFlowSampleApp/InnoFlowSampleApp.xcodeproj -scheme InnoFlowSampleApp -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

Principles are enforced through macro diagnostics, architecture tests, and `scripts/principle-gates.sh`.

## Preview Guidance

Use `Store.preview(...)` in `#Preview` blocks so preview setup stays explicit without changing
production store semantics.

```swift
#Preview("Counter") {
  CounterView(
    store: .preview(
      reducer: CounterFeature(),
      initialState: .init(count: 3, step: 2)
    )
  )
}
```

Package support is declared for iOS 18, macOS 15, tvOS 18, watchOS 11, and visionOS 2 or newer. The 4.0.0 release raised the floor from iOS 17 / macOS 14 to take advantage of Swift 6.0 standard-library primitives (typed throws, `sending` parameters, `~Copyable` generics) without availability branches.
The canonical sample still treats iOS as the primary interactive shell, while CI package builds
cover the package-level visionOS contract.

For visionOS-specific guidance, keep the same ownership split:

- reducers still own business and domain transitions
- the app layer owns window, volume, and immersive-space orchestration
- `PhaseTransitionGraph` stays a topology validator rather than a spatial runtime

See [VisionOSIntegration](Sources/InnoFlow/InnoFlow.docc/VisionOSIntegration.md) for the docs-only
visionOS integration contract. Dedicated immersive samples are intentionally outside the current
canonical sample.
