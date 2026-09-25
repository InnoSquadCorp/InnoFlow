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

### Comprehensive review protocol

For whole-repository, "anything else to improve/fix?", or "is this the best?"
requests, establish the revision and dirty-input snapshot, complete module and
product inventory, cross-feature matrix, exclusions, and exit criteria before
investigating. Do not wait for repeated user questions to expand coverage.

- Include source, tests, public contracts, independent consumers/examples,
  toolchains/platforms, and CI/release trust boundaries. Track normal, failure,
  cancellation, concurrency, retry/restoration, resource-limit, observability,
  and security paths where applicable; state why other paths are inapplicable.
- Reproduce suspected defects through the actual implementation with a passing
  control, then run relevant regressions/integration checks. Keep review-only
  probes outside production source/test trees. Separate product defects from
  fixture, build, toolchain, and environment failures; deduplicate root causes.
- Close every matrix row with exact evidence or a specific unverified boundary.
  Label fresh, reused, static-only, blocked, and out-of-scope evidence explicitly.
  Report confirmed defects, unresolved candidates, optional improvements, and
  unverified boundaries separately. Never turn a missing check into a PASS.
- Stop when the fixed review criteria are accounted for, not at a finding count.
  A green suite or completed review does not mean no defects, fixes complete,
  or release readiness. Reopen affected rows when candidate inputs change.
- Review authorization alone does not permit production fixes, commits, pushes,
  external messages, tags, or releases. Preserve existing work. User-approved
  scope restrictions continue to apply; Mulbyul-specific validation is excluded
  from the current InnoFlow 6.0 release review.

Use `docs/COMPREHENSIVE_REVIEW_6_0_2026_09_23.md` as the initial inventory and
evidence-ledger example, not as reusable proof for a later revision.

## InnoFlow 6.0.0 development rules

These rules are source-of-truth and are enforced by macro diagnostics, tests, and principle gates.

1. `@InnoFlow` features must declare the third reducer generic explicitly:
   `var body: some Reducer<State, Action, Never>` without app-boundary output,
   or the feature's typed `Output` when it emits one.
2. Public feature authoring must not directly implement `func reduce(into:action:)`.
3. Composition happens through `Reduce`, `CombineReducers`, and `Scope`.
4. `PhaseTransitionGraph` is an opt-in topology validator, and `PhaseMap` is the canonical post-reduce phase ownership layer.
5. Binding stays explicit through `@BindableField` (property wrapper) and `store.binding(\.$field, to:)`. The `to:` label is the canonical spelling; `send:` and unlabeled trailing-closure calls are semantically identical compatibility spellings that continue to resolve without deprecation.
6. `BindableProperty` is a low-level storage type — never authored directly in public features.
7. InnoFlow owns business/domain transitions only.
8. `Store.send(_:)` returns a `FlowTask`; action-tree waiting and cancellation
   must remain scoped to the originating dispatch.
   Recheck dispatch cancellation before reducing queued actions and delivering
   immediate outputs; already-applied state changes are not rolled back.
9. Reducer `Output` is typed and ephemeral. Persisted or renderable data stays
   in `State`, and parent output lifting is explicit through `mapOutput(_:)`.
   Output-free reducers and effects may use `promoteOutput(to:)`, available
   only for `Output == Never`; real output must never be silently discarded.
10. `send(_:capturingOutputs:)` installs a single-consumer dispatch output
    stream before enqueue. It captures only the root action and descendants;
    store-wide `outputs()` remains the live broadcast surface.
    Cancelling the captured stream's awaiting task cancels only its dispatch;
    normal completion and broadcast subscriber cancellation must not do so.
11. `strictPhaseTotality: true` is an opt-in compile-time declaration gate. It
    requires `phaseManaged: true` and direct `Phase` source/target coverage;
    dynamic trigger semantics remain verified through `requireComplete(...)`.
12. Scheduled run lanes are Store-local and bounded. Handle admission
    rejection explicitly; serial execution is not a persistence transaction,
    retry, rollback, or exactly-once guarantee. A `latest` replacement must
    publish its new lane generation before any suspension. Inherited effect
    cancellation IDs also own pending scheduled requests: cancelling one
    removes its pending request and returns queue capacity immediately. A
    running serial or drop lane keeps its physical slot until the operation
    actually returns.
13. `FlowScope` owns only explicitly tracked dispatches. Closing one scope must
    not cancel sibling scopes, untracked work, or an entire Store. Cancelling
    the caller starts owned cancellation even while the scope body is awaiting
    unrelated work; every normal, throwing, and cancelled return still joins
    the same close operation.
14. `StoreDiagnostics` remains opt-in, bounded, and payload-free. `DispatchID`
    is correlation metadata, not a domain identity or effect cancellation ID.
    Only a submitted dispatch can become active; late events may remain in
    bounded history but must never resurrect terminated work.
15. Test invariants run once after composed reduction. Scenarios and scoped
    output helpers remain testing-only and must preserve root queue semantics.
16. Closure-based `select` calls are independent by default, even at one
    call site. A stable semantic `id:` may reuse only a live handle with the
    same owner, call site, selector signature, and value type; it must cover
    captured inputs and is weakly cached. Key-path-only selection retains
    stable identity. Parent release invalidates tracked projection liveness
    and optional reads on MainActor before Store deinitialization finishes.

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

- `Reducer<State, Action, Output>` (`Output == Never` for reducers without app-boundary events)
- `Store`
- `EffectTask<Action>`
- `FlowTask`
- `TestStore`
- `@InnoFlow`
- `@BindableField`

The data flow is:

`Action -> reducer composition -> state mutation + ReducerEffect/Output -> Store runtime -> View or coordinator`

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

### Dispatch lifetime and output

`Store.send(_:)` and `ScopedStore.send(_:)` return `FlowTask`. Its `finish()`
waits for descendant effects and emitted actions; `cancel()` affects only that
dispatch tree. Reducers declare one-shot coordinator events as nested `Output`,
emit them with `Self.output(_:)`, and lift child values with `mapOutput(_:)`.
Never use output as a replacement for restorable state.

Use `send(_:capturingOutputs:)` when a coordinator needs output correlated to
one dispatch. The resulting `OutputFlowTask` buffers synchronous output before
`send` returns, follows descendant effects, and finishes its single-consumer
stream with the dispatch tree.
Task cancellation while awaiting the capture cancels its dispatch. A plain
`break` while retaining the stream requires explicit `cancel()` to abandon work.
TestStore receives outputs by exact value, predicate, or case path. Each form
honors exhaustivity and one total deadline; cancellation is not a test timeout.

### CasePath auto-synthesis

`@InnoFlow` auto-generates CasePath for standard patterns:
- `case child(ChildAction)` → `Action.childCasePath`
- `case todo(id: ID, action: ChildAction)` → `Action.todoActionPath`
- `case _loaded(Output)` → `Action.loadedCasePath`
- nested `Output` enum cases → `Output.<caseName>CasePath`

Output helper declarations retain the case's availability attributes and are
emitted inside the same recursively mirrored `#if` / `#elseif` / `#else`
structure. Mutually exclusive branches may use the same case/helper name;
collisions in one active conditional context still diagnose.

Collection `id/action` routing remains special-cased as `CollectionActionPath`, while single
unlabeled payload cases synthesize plain `CasePath`.

Labeled or multi-payload cases outside those standard patterns emit an unsupported-shape warning.
Declare the canonical `static let <caseName>CasePath` inside `Action` when a custom path is needed;
the macro recognizes that declaration and does not warn. Add `@InnoFlowCasePathIgnored` to the enum
case when no path is needed, or when the manual path lives in an extension that the attached macro
cannot inspect. The marker skips both synthesis and unsupported-payload diagnostics for that case.
The canonical static variable name is the syntactic manual-path signal, so typealiases and factories
are supported without requiring the macro to resolve their semantic result type. `Output` cases never
synthesize collection-action paths; labeled multi-payload output uses a labeled tuple payload.

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

  var body: some Reducer<State, Action, Never> {
    let phaseMap: PhaseMap<State, Action, State.Phase> = Self.phaseMap

    return Reduce { state, action in
      switch action {
      case .load:
        return .send(._loaded("fixture"))
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
- Use `requireComplete(...)` only when a feature opts into explicit trigger
  completeness. Runtime PhaseMap matching remains partial by default.
- Use `@InnoFlow(phaseManaged: true, strictPhaseTotality: true)` when every
  directly declared `Phase` case must be referenced as a source or target at
  compile time. It does not prove predicate or payload-domain exhaustiveness.
- Mermaid and DOT exports must stay deterministic for documentation diffs.
- Generated action path members strip one leading underscore, so `_loadedCasePath` becomes `loadedCasePath`.

## Testing

Use `TestStore` for deterministic reducer tests.

```swift
import InnoFlowTesting
import Testing

@Test
@MainActor
func loadingFlow() async {
  let store = TestStore(reducer: LoadingFeature())
  let phaseMap: PhaseMap<LoadingFeature.State, LoadingFeature.Action, LoadingFeature.State.Phase> =
    LoadingFeature.phaseMap

  await store.send(.load, through: phaseMap) {
    $0.phase = .loading
  }

  await store.receive(._loaded("fixture"), through: phaseMap) {
    $0.phase = .loaded
    $0.output = "fixture"
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
checkpoint. `assertNoMoreActions()` was removed in 6.0.0.

State mismatches include a `Diff:` section before the full expected/actual dump. The renderer defaults to 12 lines, can be overridden with `TestStore(..., diffLineLimit: 24)`, and also reads `INNOFLOW_TESTSTORE_DIFF_LINE_LIMIT`.

For child reducer assertions, project the parent harness instead of building a second store:

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

Scoped child state must conform to `Equatable`. `ScopedStore` keeps a cached child snapshot, refreshes that projection during the parent store's action drain, and only invalidates observers when that snapshot actually changes.

When `ParentFeature.Action` declares `case child(ChildFeature.Action)`, `@InnoFlow` synthesizes
`ParentFeature.Action.childCasePath` automatically. Reuse that generated path across both
`Scope` and `TestStore.scope`:

```swift
@InnoFlow
struct ChildFeature {
  struct State: Equatable, Sendable, DefaultInitializable {
    enum Phase: Equatable, Sendable { case idle, loading, loaded }
    var phase: Phase = .idle
  }

  enum Action: Equatable, Sendable { case start, finished }

  var body: some Reducer<State, Action, Never> {
    Reduce { state, action in
      switch action {
      case .start:
        state.phase = .loading
        return .send(.finished)
      case .finished:
        state.phase = .loaded
        return .none
      }
    }
  }
}

@InnoFlow
struct ParentFeature {
  struct State: Equatable, Sendable, DefaultInitializable {
    var child = ChildFeature.State()
  }

  enum Action: Equatable, Sendable {
    case child(ChildFeature.Action)
  }

  var body: some Reducer<State, Action, Never> {
    Scope(state: \.child, action: Action.childCasePath, reducer: ChildFeature())
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
│   │   ├── ReducerOnChange.swift
│   │   ├── ReducerOutputMapping.swift
│   │   ├── Store.swift                  # main actor state owner + action queue entry point
│   │   ├── Store+EffectDriver.swift
│   │   ├── StoreOutputHub.swift         # live typed reducer-output broadcast
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
│   │   ├── FlowTask.swift               # per-dispatch effect-tree lifetime
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
│       ├── TestStore+Output.swift
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
./scripts/principle-gates.sh            # full suite: static gates + release builds + test runs
./scripts/principle-gates.sh --static   # fast local iteration: static gates only
./scripts/principle-gates-selftest.sh  # negative controls for validation tooling
./scripts/run-coverage.sh              # candidate-bound instrumented coverage + module floor
```

## Contribution rule

If a change violates the documented authoring model or ownership rules, update:

- macro diagnostics
- tests
- principle gates
- CI

Do not leave the rule enforced only by prose.
