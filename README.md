# InnoFlow

English | [한국어](./README.kr.md) | [日本語](./README.jp.md) | [简体中文](./README.cn.md)

> The English README is the canonical, most up-to-date version. The localized README files are companion entry points that summarize the framework and link back to the English source of truth.

InnoFlow is a SwiftUI-first unidirectional architecture framework for business and domain state transitions.

## InnoFlow 3.0.0 direction

The framework now treats the following as source-of-truth principles:

- Official feature authoring is `var body: some Reducer<State, Action>`.
- `@InnoFlow` features implement `Reducer` through `body`, and the macro generates the required `reduce(into:action:)` entry point from that composition.
- Composition happens through `Reduce`, `CombineReducers`, `Scope`, `IfLet`, `IfCaseLet`, and `ForEachReducer`.
- `PhaseTransitionGraph` is an opt-in validation layer, not a generic automata runtime.
- Binding remains explicit opt-in through `@BindableField`, and SwiftUI bindings use projected key paths such as `\.$step`.
- InnoFlow owns business/domain transitions only.

Cross-framework ownership stays explicit:

- App-layer navigation state or another navigation library owns concrete route stacks.
- Transport and session lifecycle stay outside InnoFlow.
- Construction-time dependency graphs stay outside InnoFlow and enter reducers as explicit bundles.

For stable framework guarantees that should not drift with scorecards or line counts, see
[`ARCHITECTURE_CONTRACT.md`](./ARCHITECTURE_CONTRACT.md).

## Installation

### Swift Package Manager

```swift
dependencies: [
  .package(url: "https://github.com/InnoSquadCorp/InnoFlow.git", from: "3.0.2")
]
```

```swift
.target(
  name: "YourApp",
  dependencies: ["InnoFlow"]
)

.testTarget(
  name: "YourAppTests",
  dependencies: ["InnoFlow", "InnoFlowTesting"]
)
```

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

  var body: some Reducer<State, Action> {
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
        value: store.binding(\.$step, send: CounterFeature.Action.setStep)
      )
    }
  }
}
```

## Composition Surface

InnoFlow 3.0.0 uses a small composition surface instead of multiple authoring styles.

### `Reduce`

`Reduce` is the closure-backed primitive reducer.

```swift
Reduce<State, Action> { state, action in
  // mutate state
  // return EffectTask<Action>
}
```

### `CombineReducers`

`CombineReducers` runs reducers in declaration order and merges child effects.

```swift
var body: some Reducer<State, Action> {
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
Scoped child state must conform to `Equatable`. The resulting `ScopedStore` caches the latest child snapshot, refreshes that projection during the parent store's action drain, and only invalidates observers when the child snapshot actually changes.
Public scoping APIs use `CasePath` and `CollectionActionPath` exclusively. Closure-based action lifting is kept internal to the framework implementation.

```swift
var body: some Reducer<State, Action> {
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

```swift
let summary = store.select { state in
  DashboardSummary(
    title: state.profile.name,
    isReady: state.permissions.isReady && state.profile.isReady
  )
}

Text(summary.title)
```

When the derived value depends on one to three explicit slices of state, prefer the
dependency-annotated overload so InnoFlow can keep the selection on a selective-refresh bucket:

```swift
let summary = store.select(dependingOn: \.profile) { profile in
  ProfileSummary(name: profile.name, canEdit: profile.isAdmin)
}
```

```swift
let badge = store.select(dependingOn: (\.profile, \.permissions)) { profile, permissions in
  DashboardBadge(
    title: profile.name,
    isReady: profile.isReady && permissions.isReady
  )
}
```

`select { state in ... }` remains available as an always-refresh fallback because InnoFlow cannot
infer which fields a general closure reads. Use it when the closure truly needs multiple parts of
state, or introduce a dedicated derived property in state when you need the optimized path for four
or more inputs.

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
  }

  enum Action: Equatable, Sendable {
    case load
    case _loaded(String)
  }

  let dependencies: Dependencies

  init(dependencies: Dependencies) {
    self.dependencies = dependencies
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .load:
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
          }
        }
      case ._loaded(let name):
        state.name = name
        return .none
      }
    }
  }
}

let feature = ProfileFeature(
  dependencies: .init(
    apiClient: APIClient.live,
    logger: Logger.live
  )
)
let store = Store(reducer: feature)
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

## Effect Model

`EffectTask<Action>` remains the only effect DSL:

- `.none`
- `.send(action)`
- `.run { send, context in ... }`
- `.merge(...)`
- `.concatenate(...)`
- `.cancel(id)`
- `.cancellable(id:cancelInFlight:)`
- `.debounce(id:for:)`
- `.throttle(id:for:leading:trailing:)`
- `.animation(_:)`

`EffectID` is still compile-time-literal oriented. Use static string literals for cancellation IDs.

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
cancellation checks.

Store deinit and explicit effect cancellation are still cooperative. InnoFlow guarantees
that late emissions are dropped immediately, but runtime teardown continues as best-effort
async cleanup. Long-running work should call `checkCancellation()` around suspension points
if it needs prompt shutdown.

Operational logging stays lightweight on purpose. Use `StoreInstrumentation.osLog(...)` for a
default log sink, or fan out vendor-specific counters and traces through
`StoreInstrumentation.sink(...)` and `combined(...)`. That is the intended extension point for
Datadog, Prometheus bridges, or `swift-metrics` wrappers:

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
    case .effectsCancelled:
      metrics.increment("feature.effect.cancelled")
    }
  }
)
```

If a team standardizes on one backend later, prefer an optional ecosystem package such as
`InnoFlowMetrics` over adding vendor dependencies to the core package graph.

### Ordering contract

Store dispatch is queue-based.

- `.send` emits an immediate follow-up action, but it is queued rather than reducer-reentrant.
- `.run` emits actions after its async boundary, and those actions re-enter the same queue.
- `.concatenate` preserves declared effect order.
- `.merge` observes child completion order, not declaration order.

## Phase Validation

`PhaseMap` is the canonical way to declare domain phase transitions. It wraps a base reducer as a
post-reduce decorator, computes the next phase from the final reducer state plus the current action,
and exposes `derivedGraph` so the same contract remains available as a `PhaseTransitionGraph`.
For a full sample-backed walkthrough, see [`PhaseDrivenWalkthrough.md`](./Sources/InnoFlow/InnoFlow.docc/PhaseDrivenWalkthrough.md).

```swift
@InnoFlow
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

  var body: some Reducer<State, Action> {
    let phaseMap: PhaseMap<State, Action, State.Phase> = Self.phaseMap

    return Reduce { state, action in
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
    .phaseMap(phaseMap)
  }
}
```

Use these rules:

- `PhaseMap` owns the declared phase key path; base reducers should not mutate it directly.
- Matching transitions are evaluated against the previous phase after the base reducer finishes.
- The first matching `On` rule wins. Returning `nil` from a guard means “consume the action, keep the current phase”.
- `PhaseMap` remains partial by default. Unmatched phase/action pairs are legal no-ops unless a team opts into stricter validation in tests.
- `PhaseTransitionGraph` remains a topology validation tool, not a general state-machine runtime.
- `validatePhaseTransitions(...)` still exists for backward compatibility, but new examples should prefer `PhaseMap`.
- Generated action path members strip one leading underscore, so `_loadedCasePath` becomes `loadedCasePath`.
- Prefer `On(CasePath, ...)` when the action carries meaningful payload, `On(.equatableAction, ...)` for simple events, and keep `On(where:)` as an escape hatch when the trigger cannot be expressed cleanly otherwise.
- Adopt `PhaseMap` when a feature already has a phase enum, legal transitions are part of the business contract, and imperative `state.phase = ...` updates are spreading across multiple reducer branches.

Design rationale:

- `PhaseTransitionGraph` stays focused on static topology checks such as reachability, unknown successors, and terminal validation.
- `PhaseMap` owns runtime phase movement and conditional resolution after the reducer has finished mutating non-phase state.
- Guard-bearing graph metadata remains intentionally out of scope.

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
let totalityReport = ProfileFeature.phaseMap.validationReport(
  expectedTriggersByPhase: [
    .idle: [.action(.load)],
    .loading: [
      .casePath(ProfileFeature.Action.loadedCasePath, label: "loaded", sample: .fixture),
      .casePath(ProfileFeature.Action.failedCasePath, label: "failed", sample: "boom")
    ]
  ]
)

precondition(totalityReport.isEmpty)
```

This helper validates only the triggers you explicitly declare. It does not change `PhaseMap`
runtime semantics, and unmatched actions remain legal no-ops by default.

## Testing

`InnoFlowTesting` provides `TestStore` for deterministic reducer tests.

```swift
import InnoFlowTesting

@Test
@MainActor
func loadFlow() async {
  let store = TestStore(reducer: ProfileFeature())

  let phaseMap: PhaseMap<ProfileFeature.State, ProfileFeature.Action, ProfileFeature.State.Phase> =
    ProfileFeature.phaseMap

  await store.send(.load, through: phaseMap) {
    $0.phase = .loading
  }

  await store.send(._loaded(.fixture), through: phaseMap) {
    $0.phase = .loaded
    $0.profile = .fixture
  }

  await store.assertNoMoreActions()
}
```

State mismatch diagnostics now include a `Diff:` section before full expected/actual dumps. The renderer shows 12 lines by default, can be overridden per harness with `TestStore(..., diffLineLimit: 24)`, and also respects `INNOFLOW_TESTSTORE_DIFF_LINE_LIMIT`.

For deeply composed reducers, project the parent `TestStore` instead of creating an independent child harness:

```swift
let store = TestStore(reducer: ParentFeature())
let child = store.scope(state: \.child, action: .childCasePath)

await child.send(.start) {
  $0.phase = .loading
}

await child.receive(.finished) {
  $0.phase = .loaded
}
```

That projection assumes `ParentFeature.Action.childCasePath`, which `@InnoFlow` now synthesizes for matching single-payload child action cases.
Collection-scoped projections keep per-element `ScopedStore` identity stable by `id`, and row observers only invalidate when their own element snapshot changes.
If an element is removed, discard any old row-scoped handle and recreate projections from the parent store; direct access to a stale collection-scoped store is treated as programmer error and traps via `preconditionFailure`.

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

await todo.send(.setDone(true))
todo.assert {
  $0.isDone.value = true
}
```

For expensive derived read-models, prefer `SelectedStore` over ad-hoc recomputation:

```swift
let status = store.select(\.phase)
#expect(status.value == .idle)
```

If the read model is derived from one to three explicit `Equatable` slices, prefer the
dependency-annotated form:

```swift
let title = store.select(dependingOn: \.child.title) { $0.uppercased() }
#expect(title.value == "CHILD")
```

## Canonical Sample

The single reference app is [`Examples/InnoFlowSampleApp`](./Examples/InnoFlowSampleApp).

It contains eight demos:

- `Basics`
- `Orchestration`
- `Phase-Driven FSM`
- `App-Boundary Navigation`
- `Authentication Flow`
- `List-Detail Pagination`
- `Offline-First`
- `Realtime Stream`

This sample is the official integration reference for `InnoFlow`-only flows, explicit dependency
bundles, and app-owned SwiftUI navigation state.

The sample hub also defines the stable accessibility identifiers used by UI smoke tests:

- `sample.basics`
- `sample.orchestration`
- `sample.phase-driven-fsm`
- `sample.router-composition`
- `sample.authentication-flow`
- `sample.list-detail-pagination`
- `sample.offline-first`
- `sample.realtime-stream`

Launch-environment direct demo mode (`INNOFLOW_SAMPLE_DEMO`) remains available for feature-focused UI regression tests.

## SwiftUI Integration Guidance

- Resolve `@Environment` values in the view layer, then forward the derived action or dependency value into the reducer.
- Prefer explicit nested `Dependencies` bundles over repeated ad-hoc captures in view code.
- Prefer stable `accessibilityIdentifier(...)` values on sample and test-targeted controls.
- Add explicit VoiceOver labels and hints when button text or dense layouts do not fully describe the action.
- Prioritize explicit accessibility metadata on demo hub rows, modal dismiss actions, and long-running or destructive controls where context can be ambiguous in VoiceOver.
- Prefer system controls and Dynamic Type-friendly layouts over custom fixed-size controls.
- Use `SelectedStore` only for expensive read-only derived values. Prefer `select(dependingOn:..., transform:)` when the value comes from one to three explicit state slices, and treat plain `select { ... }` as the always-refresh fallback. Keep mutable child flows on `ScopedStore`.
- Use `Store.preview(...)` as the default path for preview and accessibility review passes so preview-only setup never changes production store wiring.

## Cross-framework notes

- Keep direct composition at the app/coordinator boundary.
- Do not duplicate concrete route stacks inside feature state.
- Reducers emit business intent; the app layer owns navigation state and dependency construction.
- Retry, reconnect, websocket, and transport/session lifecycle stay outside `PhaseTransitionGraph`.

## Roadmap

The core architecture is stable. Remaining work is conditional roadmap material, not required
redesign.

- **PhaseMap strict totality enforcement** — `PhaseMap` is intentionally partial by default and
  unmatched actions remain legal no-ops. Stronger enforcement remains a future design decision,
  not a current runtime contract.
- **Derived-state optimization beyond 3 explicit slices** — `select(dependingOn:transform:)`
  currently covers one to three explicit `Equatable` slices. `4+`-dependency optimization and
  opaque expensive selector memoization remain trigger-based backlog items and should only open
  when repeated real-world patterns and hot-path profiling justify them.
- **Optional metrics ecosystem package** — `StoreInstrumentation.sink(...)`, `.osLog(...)`, and
  `.combined(...)` are the supported extension points today. If a standard backend emerges, an
  optional `InnoFlowMetrics`-style package can sit on top without changing the core graph.
- **PhaseMap adoption expansion** — `PhaseMap` is the canonical path for phase-heavy features, but
  further migration should follow real feature demand rather than sample-driven expansion.
- **Accessibility and documentation polish** — sample/docs coverage can continue to improve, but
  this is product polish rather than a missing core capability.
- **SelectedStore API surface reduction** — the 1/2/3-dependency overloads on both `Store` and
  `ScopedStore` can be unified via Swift parameter packs once the feature stabilizes.
- **StoreSupport file organization** — six independent types live in a single file. Per-type
  extraction improves navigability without changing module boundaries.

## Development

Use these commands locally:

```bash
swift test --package-path .
swift test --package-path Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage
xcodebuild -project Examples/InnoFlowSampleApp/InnoFlowSampleApp.xcodeproj -scheme InnoFlowSampleApp -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
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

Package support is declared for iOS, macOS, tvOS, watchOS, and visionOS. The canonical sample
still treats iOS as the primary interactive shell, while CI package builds cover the package-level
visionOS contract.

For visionOS-specific guidance, keep the same ownership split:

- reducers still own business and domain transitions
- the app layer owns window, volume, and immersive-space orchestration
- `PhaseTransitionGraph` stays a topology validator rather than a spatial runtime

See [VisionOSIntegration](Sources/InnoFlow/InnoFlow.docc/VisionOSIntegration.md) for the docs-only
visionOS integration contract. Dedicated immersive samples are intentionally outside the current
canonical sample.
