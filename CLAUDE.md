# CLAUDE.md

This file explains the current InnoFlow authoring model and repository rules.

## Developer Guidelines

### Language policy

- Reply in Korean unless system-prompt handling requires English.
- PR descriptions should be written in Korean.

### Engineering expectations

- Solve root causes before proposing code changes.
- Do not optimize for passing tests with hard-coded behavior.
- Respect unidirectional flow and explicit side-effect boundaries.
- Prefer general-purpose architecture changes over case-specific patches.

## InnoFlow 5.0.0 development rules

These rules are source-of-truth and are enforced by macro diagnostics, tests, and principle gates.

1. `@InnoFlow` features must declare `var body: some Reducer<State, Action>`.
2. Public feature authoring must not directly implement `func reduce(into:action:)`.
3. Composition happens through `Reduce`, `CombineReducers`, and `Scope`.
4. `PhaseTransitionGraph` is an opt-in topology validator, and `PhaseMap` is the canonical post-reduce phase ownership layer.
5. Binding stays explicit through `@BindableField` (property wrapper) and `store.binding(\.$field, to:)`. The `to:` label is the canonical spelling; `send:` and unlabeled trailing-closure calls are semantically identical compatibility spellings that continue to resolve without deprecation.
6. `BindableProperty` is a low-level storage type — never authored directly in public features.
7. InnoFlow owns business/domain transitions only.

Macro-first means `@InnoFlow` is the canonical feature-authoring path, while
`InnoFlowCore` remains a deliberate compiler-plugin-free runtime and recovery
boundary. Keep plugin trust, SwiftSyntax fallback, sandbox, and CI guidance in
`docs/MACRO_OPERATIONS.md`, and enforce that contract with
`scripts/check-macro-operations.sh`.

Cross-framework ownership:

- The app boundary or another navigation layer owns concrete route stacks and navigation transitions.
- Transport and session lifecycle stay outside InnoFlow.
- Construction-time dependency graphs stay outside InnoFlow and enter reducers as explicit bundles.

## Project Overview

InnoFlow is a SwiftUI-native architecture framework built around:

- `Reducer<State, Action>`
- `Store`
- `EffectTask<Action>`
- `TestStore`
- `@InnoFlow`
- `@BindableField`

The data flow is:

`Action -> reducer composition -> state mutation + EffectTask -> Store runtime -> View`

## Official authoring style

```swift
import InnoFlow

@InnoFlow
struct Feature {
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

## Composition primitives

### `Reduce`

Closure-backed reducer primitive.

### `CombineReducers`

Runs reducers in declaration order and merges returned effects.

### `Scope`

Lifts child state, child actions, and child effects into a parent reducer space.

### `IfLet`

Runs child reducer while optional state is `Some`. Used for `.sheet(item:)` and `.navigationDestination` patterns.

### `IfCaseLet`

Runs child reducer while enum case matches. Used for tab-based or enum-state driven composition.

### `EffectTask.map`

Used to lift child effect actions while preserving cancellation, debounce, throttle, and animation semantics.

### CasePath auto-synthesis

`@InnoFlow` auto-generates CasePath for standard patterns:
- `case child(ChildAction)` → `Action.childCasePath`
- `case todo(id: ID, action: ChildAction)` → `Action.todoActionPath`
- `case _loaded(Output)` → `Action.loadedCasePath`

Collection `id/action` routing remains special-cased as `CollectionActionPath`, while single
unlabeled payload cases synthesize plain `CasePath`.

## Phase-driven modeling

Use `PhaseMap` when a feature has meaningful domain phases and the phase transitions themselves
should be declared as part of the reducer contract.

```swift
@InnoFlow
struct LoadingFeature {
  struct State: Equatable, Sendable, DefaultInitializable {
    enum Phase: Hashable, Sendable {
      case idle
      case loading
      case loaded
      case failed
    }

    var phase: Phase = .idle
    var output: String?
    var errorMessage: String?
  }

  enum Action: Equatable, Sendable {
    case load
    case _loaded(String)
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
      case ._loaded(let output):
        state.output = output
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

Rules:

- `PhaseMap` is post-reduce and owns the declared phase key path.
- Base reducers must not mutate that phase directly once `PhaseMap` is active.
- Same-phase actions are ignored by the phase layer.
- Illegal transitions assert in debug builds.
- Store runtime remains phase-agnostic.
- `PhaseTransitionGraph` remains topology-only. Guard-bearing graph metadata is still out of scope.
- Generated action path members strip one leading underscore, so `_loadedCasePath` becomes `loadedCasePath`.

## Testing

Use `TestStore` for deterministic reducer tests.

```swift
import InnoFlowTesting

@Test
@MainActor
func loadingFlow() async {
  let store = TestStore(reducer: LoadingFeature())
  let phaseMap: PhaseMap<LoadingFeature.State, LoadingFeature.Action, LoadingFeature.State.Phase> =
    LoadingFeature.phaseMap

  await store.send(.load, through: phaseMap) {
    $0.phase = .loading
  }

  await store.receive(._loaded(.fixture), through: phaseMap) {
    $0.phase = .loaded
  }

  await store.finish()
}
```

`TestStore.exhaustivity` defaults to `.on`. Every state mutation must be
described in the matching `send` or `receive` assertion closure, and every
effect action must be consumed with `receive`; omitting a closure asserts that
state does not change. Use `.off` only for intentionally partial tests. In that
mode, expected-state closures start from the actual post-reducer state,
unexpected actions are reduced, and `.off(showSkippedAssertions: true)` emits
non-failing warnings.

Use `finish()` as the terminal assertion. Exhaustive stores fail on unreceived
actions; non-exhaustive stores drain them and their follow-up effects until
idle. Use `assertNoBufferedActions()` only for an intermediate queue
checkpoint. `assertNoMoreActions()` is deprecated.

State mismatches include a `Diff:` section before the full expected/actual dump. The renderer defaults to 12 lines, can be overridden with `TestStore(..., diffLineLimit: 24)`, and also reads `INNOFLOW_TESTSTORE_DIFF_LINE_LIMIT`.

For child reducer assertions, project the parent harness instead of building a second store:

```swift
let store = TestStore(reducer: ParentFeature())
let child = store.scope(state: \.child, action: .childCasePath)

await child.send(.start) {
  $0.phase = .loading
}

await child.receive(.finished) {
  $0.phase = .loaded
}

await child.finish()
```

Scoped child state must conform to `Equatable`. `ScopedStore` keeps a cached child snapshot, refreshes that projection during the parent store's action drain, and only invalidates observers when that snapshot actually changes.

When `ParentFeature.Action` declares `case child(ChildAction)`, `@InnoFlow` synthesizes
`ParentFeature.Action.childCasePath` automatically. Reuse that generated path across both
`Scope` and `TestStore.scope`:

```swift
@InnoFlow
struct ParentFeature {
  enum Action: Equatable, Sendable {
    case child(ChildAction)
  }
}
```

Use `scope(collection:id:action:)` with a `CollectionActionPath` when you need to target a single identifiable child inside a collection. Public scoping stays on `CasePath` / `CollectionActionPath` so the authoring story matches `@InnoFlow` synthesis. Removal assertions stay on the parent `TestStore`.
Collection-scoped projections also preserve per-element `ScopedStore` identity by `id`, so sibling updates do not invalidate unrelated row observers.

## Repository Structure

```text
InnoFlow/
├── Sources/
│   ├── InnoFlow/                        # authoring facade + macro declarations
│   │   └── InnoFlow.swift
│   ├── InnoFlowCore/
│   │   ├── Reducer.swift
│   │   ├── ReducerComposition.swift
│   │   ├── Store.swift                  # main actor state owner + action queue entry point
│   │   ├── Store+EffectDriver.swift
│   │   ├── StoreEffectBridge.swift      # store/runtime bridge
│   │   ├── EffectRuntime.swift          # actor runtime bookkeeping
│   │   ├── StoreActionQueue.swift       # queued action drain support
│   │   ├── ProjectionObserverRegistry.swift
│   │   ├── StoreCaches.swift
│   │   ├── StoreLifetimeToken.swift
│   │   ├── ScopedStore.swift            # child projections + collection scoping
│   │   ├── SelectedStore.swift          # derived read models + dependency-aware refresh
│   │   ├── BindableField.swift
│   │   ├── BindableProperty.swift
│   │   ├── EffectTask.swift
│   │   ├── EffectWalker.swift
│   │   ├── EffectDriver.swift
│   │   ├── StoreInstrumentation.swift
│   │   ├── CasePath.swift
│   │   ├── CollectionActionPath.swift
│   │   ├── ActionMatcher.swift
│   │   ├── PhaseMap.swift
│   │   ├── PhaseTransitionGraph.swift
│   │   └── PhaseValidationReducer.swift
│   ├── InnoFlowSwiftUI/
│   │   ├── Store+SwiftUIBindings.swift  # binding surface
│   │   ├── Store+SwiftUIPreviews.swift  # Store.preview(...)
│   │   ├── Store+Presentation.swift
│   │   └── EffectTask+SwiftUI.swift
│   ├── InnoFlowMacros/                  # @InnoFlow implementation
│   └── InnoFlowTesting/
│       ├── TestStore.swift
│       ├── TestStore+Public.swift
│       ├── TestStore+EffectDriver.swift      # EffectDriver conformance only
│       ├── TestStore+EffectLifecycle.swift   # task and delayed-effect ownership
│       ├── TestStore+Finish.swift
│       ├── TestStoreActionQueue.swift        # deterministic test action delivery
│       ├── TestStoreRunSupport.swift         # run endpoint, bridge, and start gate
│       ├── ScopedTestStore.swift
│       └── ManualTestClock.swift
└── Examples/InnoFlowSampleApp/
```

## Commands

```bash
swift test --package-path .
swift test --package-path Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage --jobs 1
xcodebuild -jobs 1 -project Examples/InnoFlowSampleApp/InnoFlowSampleApp.xcodeproj -scheme InnoFlowSampleApp -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
./scripts/principle-gates.sh
```

## Contribution rule

If a change violates the documented authoring model or ownership rules, update:

- macro diagnostics
- tests
- principle gates
- CI

Do not leave the rule enforced only by prose.
