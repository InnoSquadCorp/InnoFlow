# Phase-Driven Modeling in InnoFlow

`PhaseMap` is the recommended way to declare domain phase transitions in InnoFlow.
It computes phase changes after the base reducer runs and still exposes `derivedGraph` so the same
contract can be validated as a `PhaseTransitionGraph`.

It is intentionally narrow:

- InnoFlow owns business/domain transitions.
- InnoRouter owns navigation transitions.
- InnoNetwork owns transport/session lifecycle.
- InnoDI owns construction-time lifecycle.
- `PhaseMap` remains partial by default; unmatched phase/action pairs are legal no-ops unless tests opt into stricter validation.

For the cross-library ownership matrix behind those bullets, see
[`docs/CROSS_FRAMEWORK.md`](docs/CROSS_FRAMEWORK.md). For dependency injection
patterns at those boundaries, see
[`docs/DEPENDENCY_PATTERNS.md`](docs/DEPENDENCY_PATTERNS.md).

## Recommended pattern

```swift
import InnoFlow

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

  var body: some Reducer<State, Action, Never> {
    let phaseMap: PhaseMap<State, Action, State.Phase> = Self.phaseMap

    return Reduce { state, action in
      switch action {
      case .load:
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

## Test-side validation

```swift
import InnoFlowTesting
import Testing

let store = TestStore(reducer: ProfileFeature())
let phaseMap: PhaseMap<ProfileFeature.State, ProfileFeature.Action, ProfileFeature.State.Phase> =
  ProfileFeature.phaseMap

await store.send(.load, through: phaseMap) {
  $0.phase = .loading
}
```

If a team wants stricter phase-contract checks, validate explicitly declared triggers in tests:

```swift
let report = ProfileFeature.phaseMap.validationReport(
  expectedTriggersByPhase: [
    .idle: [.action(.load)],
    .loading: [
      .casePath(ProfileFeature.Action.loadedCasePath, label: "loaded", sample: .fixture),
      .casePath(ProfileFeature.Action.failedCasePath, label: "failed", sample: "boom")
    ]
  ]
)
#expect(report.isEmpty)

// Or fail release setup directly:
try ProfileFeature.phaseMap.requireComplete(
  expectedTriggersByPhase: [
    .idle: [.action(.load)],
    .loading: [
      .casePath(ProfileFeature.Action.loadedCasePath, label: "loaded", sample: .fixture),
      .casePath(ProfileFeature.Action.failedCasePath, label: "failed", sample: "boom")
    ]
  ]
)
```

The throwing helper is intended for an opt-in test or release gate. Runtime
matching remains partial. The same topology can drive documentation without a
second source of truth:

```swift
let mermaid = ProfileFeature.phaseGraph.mermaidDiagram()
let graphviz = ProfileFeature.phaseGraph.dotGraph(name: "Profile loading")
```

## Compile-time declaration coverage

For a macro-managed feature whose directly authored phase map must mention
every declared phase, enable strict totality:

```swift
@InnoFlow(phaseManaged: true, strictPhaseTotality: true)
struct ProfileFeature {
  // State.Phase, Action, static phaseMap, and body
}
```

The macro turns a missing direct `Phase` source or target reference into a
compile-time error. This is intentionally syntax-level declaration coverage:
it does not execute `On(where:)` predicates, inspect helper-built DSL
fragments, prove dynamic `resolve` results, or compute graph reachability.
Keep `requireComplete(...)` tests for those semantic contracts. Without the
strict flag, phase-managed features retain the warning-grade diagnostic and
the runtime stays partial by default.

## Design rules

- Use `PhaseMap` only when the domain has meaningful legal transitions.
- Keep `phaseMap` and `phaseGraph = phaseMap.derivedGraph` as feature-local statics.
- Keep the base reducer focused on non-phase state mutation and effects.
- Use `PhaseTransitionGraph` as contract + validation, not as a full runtime engine.
- Prefer `CasePath` matching in `On` when payload matters, use equatable action matching for simple
  events, and reserve `where:` for escape-hatch cases.
- Treat `validationReport(expectedTriggersByPhase:)` and `requireComplete(...)`
  as opt-in contract checks, not as runtime requirements.
- Use `strictPhaseTotality: true` when omitted direct phase wiring should stop
  compilation; keep semantic totality and reachability in tests.

## Anti-patterns

Do not:

- mutate the declared phase directly inside the base reducer once `PhaseMap` is active
- move route stack ownership into InnoFlow state
- mirror InnoRouter path transitions as phase graph transitions
- mirror retry/reconnect/websocket/session lifecycle from InnoNetwork into business phases
- turn InnoFlow into a DFA/NFA/PDA framework
