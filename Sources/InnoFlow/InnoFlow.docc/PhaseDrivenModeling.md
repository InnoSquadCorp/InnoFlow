# Phase-Driven Modeling

Use phase-driven modeling when a feature has a small set of domain phases and the
allowed transitions matter to readers, tests, or debug assertions.

InnoFlow keeps this opt-in. It does **not** turn the framework into a generic automata
runtime.

## Define the phase graph

```swift
import InnoFlow

enum LoadPhase: Hashable, Sendable {
  case idle
  case loading
  case loaded
  case failed
}

let phaseGraph: PhaseTransitionGraph<LoadPhase> = [
  .idle: [.loading],
  .loading: [.loaded, .failed],
  .loaded: [.loading],
  .failed: [.idle, .loading],
]
```

## Project the phase from state

```swift
@ObservableState
struct State {
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
```

## Validate transitions in tests

```swift
import InnoFlowTesting

await store.send(.load, tracking: \.phase, through: phaseGraph) {
  $0.phase = .loading
}

await store.receive(._loaded(items), tracking: \.phase, through: phaseGraph) {
  $0.phase = .loaded
  $0.items = items
}
```

If a reducer path introduces an undocumented transition, the test helper fails with the
offending `from -> to` change.

## When to use it

- `idle -> loading -> loaded`
- `draft -> validating -> submitting -> submitted`
- `signedOut -> authenticating -> signedIn`

Do not force it into features where simple scalar state is already clear.
