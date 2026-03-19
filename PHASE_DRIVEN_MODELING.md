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

  var body: some Reducer<State, Action> {
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

precondition(report.isEmpty)
```

## Design rules

- Use `PhaseMap` only when the domain has meaningful legal transitions.
- Keep `phaseMap` and `phaseGraph = phaseMap.derivedGraph` as feature-local statics.
- Keep the base reducer focused on non-phase state mutation and effects.
- Use `PhaseTransitionGraph` as contract + validation, not as a full runtime engine.
- Prefer `CasePath` matching in `On` when payload matters, use equatable action matching for simple
  events, and reserve `where:` for escape-hatch cases.
- Treat `validationReport(expectedTriggersByPhase:)` as an opt-in contract check, not as a runtime requirement.

## Anti-patterns

Do not:

- mutate the declared phase directly inside the base reducer once `PhaseMap` is active
- move route stack ownership into InnoFlow state
- mirror InnoRouter path transitions as phase graph transitions
- mirror retry/reconnect/websocket/session lifecycle from InnoNetwork into business phases
- turn InnoFlow into a DFA/NFA/PDA framework
