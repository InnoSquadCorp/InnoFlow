# Phase-Driven Walkthrough

This walkthrough uses the canonical sample app's `PhaseDrivenTodoFeature` to show how phase-driven modeling fits into a real InnoFlow feature.

Use this pattern when a feature has a small set of meaningful domain phases and the legal transitions are part of the feature contract.

## 1. Declare a narrow phase map

```swift
static var phaseMap: PhaseMap<State, Action, State.Phase> {
  PhaseMap(\.phase) {
    From(.idle) {
      On(.loadTodos, to: .loading)
    }
    From(.loading) {
      On(Action.loadedCasePath, to: .loaded)
      On(Action.failedCasePath, to: .failed)
    }
    From(.loaded) {
      On(.loadTodos, to: .loading)
    }
    From(.failed) {
      On(.loadTodos, to: .loading)
      On(.dismissError, targets: [.idle, .loaded]) { state in
        state.todos.isEmpty ? .idle : .loaded
      }
    }
  }
}

static var phaseGraph: PhaseTransitionGraph<State.Phase> {
  phaseMap.derivedGraph
}
```

Keep the graph focused on business lifecycle only. In the sample, the phase contract answers "can
the todo screen load, succeed, fail, or retry?" It does **not** encode navigation, reconnect
windows, or session lifecycle.

## 2. Keep the reducer phase-focused

The sample reducer uses `@InnoFlow(phaseManaged: true)` so the macro applies the static
`phaseMap` as a post-reduce decorator:

```swift
var body: some Reducer<State, Action> {
  Reduce { state, action in
    switch action {
    case .loadTodos:
      state.errorMessage = nil
      let shouldFail = state.shouldFail
      let todoService = self.todoService
      return .run { send, context in
        do {
          try await context.sleep(for: .milliseconds(120))
          try await context.checkCancellation()
          let todos = try await todoService.loadTodos(shouldFail: shouldFail)
          await send(._loaded(todos))
        } catch is CancellationError {
          return
        } catch {
          await send(._failed(error.localizedDescription))
        }
      }
      .cancellable("phase-load", cancelInFlight: true)

    case ._loaded(let todos):
      state.todos = todos
      state.errorMessage = nil
      return .none

    case ._failed(let message):
      state.errorMessage = message
      return .none

    default:
      return .none
    }
  }
}
```

The important split is:

- `Reduce` owns non-phase state mutation and effect kickoff.
- The phase-managed macro applies `Self.phaseMap`; `PhaseMap` owns how actions move the feature between legal phases.
- `phaseGraph = phaseMap.derivedGraph` keeps the topology contract visible for tests and docs.
- `.run` stays a domain effect, not a state-machine runtime, and uses `EffectContext` for deterministic delays.
- Prefer `CasePath`-based `On(...)` rules first, `Equatable` actions second, and keep `On(where:)`
  as an escape hatch for triggers that cannot be expressed more directly.

If the base reducer tries to mutate the declared phase directly while `PhaseMap` is active, the
phase layer treats that as a programmer error: it asserts in debug builds, restores the previous
phase, and then applies the declared `PhaseMap` transition.

## 3. Render with `Store` and collection-scoped rows

The sample view keeps the parent `Store` in SwiftUI and projects each todo row with
`scope(collection:action:)`:

```swift
let todoStores = store.scope(
  collection: \.todos,
  action: PhaseDrivenTodoFeature.Action.todoActionPath
)

ForEach(todoStores) { todoStore in
  PhaseDrivenTodoRowView(store: todoStore)
}
```

This keeps the parent feature in charge of ownership while allowing row-level bindings:

```swift
Toggle(
  isOn: store.binding(\.$isDone, to: PhaseDrivenTodoRowFeature.Action.setIsDone)
) {
  Text(store.title)
}
```

As in the rest of InnoFlow, prefer explicit binding argument labels here: `send:` and `to:` are both valid. Existing trailing-closure calls continue to resolve to `send:` for source compatibility.

The row projection is still a view concern. The phase contract remains at the parent feature level.

## 4. Assert the phase map and child behavior in tests

The sample tests use `TestStore` for phase assertions and a collection-scoped child projection for
row behavior:

```swift
let phaseMap: PhaseMap<
  PhaseDrivenTodoFeature.State,
  PhaseDrivenTodoFeature.Action,
  PhaseDrivenTodoFeature.State.Phase
> = PhaseDrivenTodoFeature.phaseMap

await store.send(.loadTodos, through: phaseMap) {
  $0.phase = .loading
}

await store.receive(._loaded(MockTodoService.fixtures), through: phaseMap) {
  $0.phase = .loaded
  $0.todos = MockTodoService.fixtures
}
```

```swift
let todo = store.scope(
  collection: \.todos,
  id: targetID,
  action: PhaseDrivenTodoFeature.Action.todoActionPath
)

await todo.send(.setIsDone(true))
todo.assert {
  $0.isDone.value = true
}
```

Use the parent `TestStore` for removal, loading, and phase transitions. Use the scoped child harness
when the child behavior itself is the contract under test.

If the graph definition itself is part of the feature contract, keep validating the derived graph:

```swift
let report = PhaseDrivenTodoFeature.phaseGraph.validationReport(
  allPhases: [.idle, .loading, .loaded, .failed],
  root: .idle
)

precondition(report.issues.isEmpty)
```

If your team wants stronger trigger coverage without changing runtime semantics, add an opt-in
PhaseMap validation pass:

```swift
let totalityReport = assertPhaseMapCovers(
  PhaseDrivenTodoFeature.phaseMap,
  expectedTriggersByPhase: [
    .idle: [.action(.loadTodos)],
    .loading: [
      .casePath(PhaseDrivenTodoFeature.Action.loadedCasePath, label: "loaded", sample: MockTodoService.fixtures),
      .casePath(PhaseDrivenTodoFeature.Action.failedCasePath, label: "failed", sample: "boom")
    ]
  ]
)

precondition(totalityReport.isEmpty)
```

This stays opt-in. `PhaseMap` itself remains partial by default, so unmatched actions are still
legal runtime no-ops.

## 5. What not to put in the phase contract

Do not model these in `PhaseMap` or `PhaseTransitionGraph`:

- route stacks or pending deep links
- reconnect timers or retry windows
- transport/session lifecycle
- low-level task bookkeeping

Those belong to the owning layer, not to the phase contract. Keep the phase contract small enough
that a reader can understand it at a glance.

For the conceptual rules, see <doc:PhaseDrivenModeling>. For the entry path into InnoFlow, start at
<doc:GettingStarted>.
