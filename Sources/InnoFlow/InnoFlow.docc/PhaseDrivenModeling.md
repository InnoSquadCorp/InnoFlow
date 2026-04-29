# Phase-Driven Modeling

Use phase-driven modeling when a feature has a small set of meaningful domain phases and the allowed transitions must stay documented.

InnoFlow keeps this opt-in. It does **not** turn the framework into a generic state-machine runtime.

For a full sample-backed implementation, see <doc:PhaseDrivenWalkthrough>.

## Declare the phase map

```swift
import InnoFlow
```

## Model the phase in state

```swift
@InnoFlow(phaseManaged: true)
struct ItemsFeature {
  struct State: Equatable, Sendable, DefaultInitializable {
    enum Phase: Hashable, Sendable {
      case idle
      case loading
      case loaded
      case failed
    }

    var phase: Phase = .idle
    var items: [Item] = []
    var errorMessage: String?
  }

  enum Action: Equatable, Sendable {
    case load
    case _loaded([Item])
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
      From(.loaded) {
        On(.load, to: .loading)
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
    Reduce { state, action in
      switch action {
      case .load:
        return .none
      case ._loaded(let items):
        state.items = items
        return .none
      case ._failed(let message):
        state.errorMessage = message
        return .none
      }
    }
  }
}
```

## Validate transitions in tests

```swift
import InnoFlowTesting

let phaseMap: PhaseMap<ItemsFeature.State, ItemsFeature.Action, ItemsFeature.State.Phase> =
  ItemsFeature.phaseMap

await store.send(.load, through: phaseMap) {
  $0.phase = .loading
}

await store.receive(._loaded(items), through: phaseMap) {
  $0.phase = .loaded
  $0.items = items
}
```

Rules:

- `PhaseMap` runs after the base reducer and owns the declared phase key path.
- Base reducers should not mutate that phase directly once `PhaseMap` is active.
- Same-phase actions are ignored by the phase layer.
- `PhaseMap` remains partial by default. Unmatched phase/action pairs are legal no-ops unless tests opt into stricter validation.
- Illegal transitions and undeclared dynamic targets assert in debug builds.
- `@InnoFlow(phaseManaged: true)` applies `Self.phaseMap` automatically and warns for Phase cases never referenced by name from the static phase map.
- `PhaseTransitionGraph` is a topology validation tool, not a general state-machine runtime.
- Prefer `On(CasePath, ...)` when payload drives the phase decision, `On(.equatableAction, ...)`
  for simple phase events, and keep `On(where:)` as an escape hatch.
- Guard-bearing graph metadata remains intentionally out of scope; see `docs/adr/ADR-phase-transition-guards.md`.
- Conditional phase resolution lives in `PhaseMap`; see `docs/adr/ADR-declarative-phase-map.md`.
- Stronger trigger coverage is opt-in; see `docs/adr/ADR-phase-map-totality-validation.md`.
- Tests should prefer `through: phaseMap` when a feature adopts `PhaseMap`.
- Adopt `PhaseMap` once a feature already has a phase enum, legal transitions matter to the business
  contract, and imperative `state.phase = ...` updates are spreading across reducer branches.

If the graph itself is part of the contract, validate it statically as well:

```swift
let report = ItemsFeature.phaseGraph.validationReport(
  allPhases: [.idle, .loading, .loaded, .failed],
  root: .idle,
  terminalPhases: [.loaded]
)

precondition(report.issues.isEmpty)

assertValidGraph(
  ItemsFeature.phaseGraph,
  allPhases: [.idle, .loading, .loaded, .failed],
  root: .idle,
  terminalPhases: [.loaded]
)
```

Use `PhaseMap` for runtime phase ownership, `assertValidGraph(...)` for static graph topology
checks, and `assertPhaseMapCovers(...)` for explicit trigger coverage. `validatePhaseTransitions(...)`
remains available for backwards compatibility.

If you want stronger trigger coverage without changing runtime behavior, validate explicit expected
triggers in tests:

```swift
let totalityReport = assertPhaseMapCovers(
  ItemsFeature.phaseMap,
  expectedTriggersByPhase: [
    .idle: [.action(.load)],
    .loading: [
      .casePath(ItemsFeature.Action.loadedCasePath, label: "loaded", sample: items),
      .casePath(ItemsFeature.Action.failedCasePath, label: "failed", sample: "boom")
    ]
  ]
)

precondition(totalityReport.isEmpty)
```

The phase-managed compile-time warning is intentionally name-based. It catches declared Phase
cases that never appear in the static `phaseMap`, but it does not prove graph reachability,
predicate exhaustiveness, or guard target completeness.

## When to use it

- `idle -> loading -> loaded`
- `draft -> validating -> submitting -> submitted`
- `signedOut -> authenticating -> signedIn`

Do not use it to duplicate route stacks, transport retries, reconnect windows, or session lifecycle.
Do not use it to model collection row ownership, effect bookkeeping, or dependency/container wiring either.
