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

## InnoFlow 6.0.2 and development rules

6.0.2 was published on 2026-10-08. `STABLE_VERSION` records that release;
new commits are unreleased until separately tagged and published. Use
[the documentation index](docs/DOCUMENTATION.md) for current guides and
historical evidence boundaries.

### CI-only release validation

All 28 required release preflight checks run only in the `Release Preflight`
GitHub Actions workflow on `main`, including all four OS 27 runtimes.
Do not install matrix runtimes on the user's Mac or run release-preflight
`execute`/`resume` locally. Local `plan`/`report`, static validation, focused
diagnostics and isolated tooling selftests remain allowed, but do not replace
CI evidence. The serialized policy stage retains its historical name
`local-preflight`; it now describes CI-produced evidence, not a local task.

Use GitHub-hosted runners only: `macos-26` / Xcode 26.6 for Swift 6.3,
`xcode-27` / Xcode 27.0 for Swift 6.4 and the release evidence producer.
There is no self-hosted release runner requirement. Preflight enumerates every
required policy check into isolated jobs (at most six concurrent), provisions
only each job's exact runtime if missing, then verifies all 28 required receipts
against the same SHA before uploading a complete bundle. Do not replace a
missing pinned toolchain/runtime with an unverified newer version.

The 2026-10-06 policy supersedes the earlier 32-check requirement: only
`runtime-ios-18.5`, `runtime-tvos-18.5`, `runtime-watchos-11.5`, and
`runtime-visionos-2.5` are optional, omitted from the required gate without an
automatic advisory run. Their failed/unavailable evidence is not a PASS or
final-candidate runtime verification. The five SDK checks, three sample SDK
checks, toolchains, source test inventories and minimum deployment support
(iOS 18 / macOS 15 / tvOS 18 / watchOS 11 / visionOS 2) remain unchanged.

Keep all 28 required checks and exact-SHA/raw-artifact verification. Missing CI
runners, toolchains or required runtimes block the CI gate; never waive them or
fall back to local execution. The tag producer accepts only a successful main
CI preflight run for that exact SHA, not a manually preloaded local bundle.
A new candidate requires a new preflight; the failed earlier run cannot be
reused as release evidence. Tag and Release
publication still require separate user authorization. See RELEASING.md.

### Framework contracts

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
   Optional-child ownership metadata must preserve bare send/output synchronous
   scheduling. A queued child action retains its owner through admission, while
   parent effects returned after admission remain independently owned.
   Recheck dispatch cancellation before reducing queued actions and delivering
   immediate outputs; already-applied state changes are not rolled back.
   Cancellation a reducer returns (`.cancel`, `cancelInFlight: true`, a newer
   debounce request, a `latest` lane request) is accepted in the MainActor
   turn of that reduction when the interpreter would reach it without awaiting
   asynchronous work: tokens of every earlier effect are marked and their
   MainActor-owned work is released before `send` returns, so the cancelled
   work can no longer have an action reduced. The effect that issued the
   request keeps its declaration order: an earlier `concatenate` sibling of a
   `.cancel` still runs, and the cancel covers its own effect when the
   interpreter reaches it (`merge` children have no order). A `latest` request only marks the superseded run in the turn;
   the lane displaces it at admission and reports it as superseded. A
   throttled subtree is accepted when its window admits it. `Store` and
   `TestStore` share this acceptance through
   `ReductionTurnCancellationAcceptor`; a test must receive exactly the
   actions a production store reduces. A dispatch whose effect is cancelled
   before it was interpreted still records the cancellation in diagnostics.
   No suspension may separate cancellation acceptance from releasing that
   work, with or without diagnostics. All Store effect bookkeeping, including
   run tasks, is MainActor-isolated: `cancelEffects(identifiedBy:)` and
   `cancelAllEffects()` complete without suspending, and `Store.deinit`
   delivers task cancellation synchronously. Task-cancellation handlers of an
   effect operation therefore run where cancellation is delivered, which can
   be the main thread.
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
    captured inputs and is weakly cached. A key-path-only selection keeps one
    identity while it is referenced, and its owner retains it from a read
    until that read's notification plus one more; a selection that is never
    read, or goes unread across two notifications, is released and its key
    path is no longer evaluated. A read of liveness alone (`isAlive`) is
    retained until the selection is deactivated, because no value change
    notifies that reader. Selection creation never records an Observation
    access on the parent and never traps: a selection created on a projection
    that is no longer alive reports that through its own accessors. Parent
    release invalidates tracked projection liveness and optional reads on
    MainActor before Store deinitialization finishes.
17. `IdentifiedArray` equality and hashing include stored ID-to-position mappings
    as well as ordered element values. Identity-only replacement must refresh
    root/scoped key-path, dependency, and memoized selections. Custom identity
    projections must remain stable for each stored element.
18. `ManualTestClock.sleep(for:)` must check pre-existing task cancellation even
    for zero or negative durations, matching `StoreClock.continuous`. Uncancelled
    nonpositive sleeps must not park; cancelled sleepers must release their
    registration and leave the clock reusable. Every clock wait is bounded: a
    wait whose event never happens throws `ManualTestClock.WaitTimeout` instead
    of suspending the test. `advance(by:)` moves time in one jump; periodic
    work is driven with `advance(by:inStepsOf:onceSleepersReach:)`. A wait
    without `timeout:` uses the clock's own `waitTimeout`
    (`ManualTestClock(waitTimeout:)`, default ten seconds). The stepped
    advance threshold counts every suspended sleeper, and a zero duration
    still waits once.
19. `TestStore` records at initialization whether a Swift Testing test owns it
    and reports deinitialization diagnostics through that framework. An
    isolated deinitializer cannot observe `Test.current`, so the safety net
    must not depend on it.
20. Weakly referenced scopes and tokens remove their own registry entry from
    a deinitializer that takes the registry lock. A reference loaded from weak
    storage must leave the critical section before it is released; a
    critical section may prune entries whose weak reference is already nil,
    but it never drops a strong reference it loaded.
21. A projection dependency key determines its change predicate. Key-path
    selections and single scopes compare values; collection scopes compare
    element identity in their own registry storage. Registry storage is never
    accessed while an observer callback runs or an observer reference is
    released.
22. A collection scope refreshes only the rows a change can affect: the
    changed element's row for a value change, the changed or removed
    elements' rows for a structural change, and none when the collection
    storage is untouched. Rows index their positions once per structural
    change; a row of the active row family never scans the collection to
    find or miss its element when the collection has contiguous storage.
    Bitwise-identical elements are unchanged by definition; elements whose
    copies differ only in padding fall back to `==`. A removed row is
    deactivated by the pass that classifies its removal, also when a
    callback scopes the collection again during that pass.

`IdentifiedArrayTests` and `ManualTestClockTests` lock contract 17 and the
sleep rules of contract 18 and are included in the focused platform runtime
inventory. The contracts added after them are locked by host suites that are
not in that inventory: `ReducerCancellationAcceptanceTests`,
`ThrottleTrailingFallbackTests`, `TestStoreReductionTurnCancellationTests`,
`ProjectionLifetimeConsistencyTests`, `CollectionProjectionRefreshTests`,
`EffectCancellationScopeTests`, `ManualTestClockDeadlineTests`,
`ClockStepDeadlineTests` and `TestStoreOwnerFrameworkReportingTests`. Run
targeted local tests when changing them; the full release/runtime matrix
remains CI-only.

Macro-first means `@InnoFlow` is the canonical feature-authoring path, while
`InnoFlowCore` remains a deliberate compiler-plugin-free runtime and recovery
boundary. Keep plugin trust, SwiftSyntax fallback, sandbox, and CI guidance in
`docs/MACRO_OPERATIONS.md`, and enforce that contract with
`scripts/check-macro-operations.sh`.

Cross-framework ownership:

- The app boundary or another navigation layer owns concrete route stacks and navigation transitions.
- Transport and session lifecycle stay outside InnoFlow.
- Construction-time dependency graphs stay outside InnoFlow and enter reducers as explicit bundles.

Cross-platform implementations live in this repository and share the semantic
contract in `contracts/SEMANTICS.md`. Swift remains macro-first, Kotlin offers
`@InnoFlow` KSP generation with a compiler-plugin-free `FlowFeature` fallback,
and TypeScript uses the declaration-first `defineFlow` boundary. Platform
packages have independent release versions; changes to shared semantics must
update the affected conformance tests, the repository gate, and CI. Do not
reshape the existing Swift API merely to match the Kotlin or TypeScript 1.0
runtime.

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

The Kotlin/Android and React/TypeScript package layout, consumption examples,
and independent release boundary are documented in
[`docs/MULTIPLATFORM.md`](docs/MULTIPLATFORM.md).

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

Macro identifier comparison uses logical names, independent of optional backticks. Generated members preserve raw identifier spelling (with source escaping), strip exactly one leading underscore, and never replace spaces or punctuation. Phase totality and collision/manual-path checks use the same logical identity. Actual compiler consumers and negative diagnostics enforce this contract.

`@InnoFlow` auto-generates CasePath for standard patterns:
- `case child(ChildAction)` → `Action.childCasePath`
- `case todo(id: ID, action: ChildAction)` → `Action.todoActionPath`
- `case _loaded(Output)` → `Action.loadedCasePath`
- nested `Output` enum cases → `Output.<caseName>CasePath`

`Action` and `Output` helper declarations share one traversal: both copy the
case's availability attributes (on one line, without comments or `renamed:`),
skip a case that is unavailable everywhere, and are emitted inside the same
recursively mirrored `#if` / `#elseif` / `#else` structure. A canonical static
path declared in the enum body takes precedence over synthesis for every shape
of both enums; in a narrower condition than its case it leaves the helper
synthesized under the complement. Helpers with one name diagnose when their
cases can be active together. Cases that redeclare each other (same name and
argument labels, or a payload-free case of that name) never can, so each keeps
its helper inside its own clause. A payload written `_ name: Payload` has no
argument label and synthesizes like an unlabeled payload in both enums. A case
made unavailable by `obsoleted:` needs `@InnoFlowCasePathIgnored`.

`@InnoFlow` adds `Reducer` conformance only when the feature does not state
it; `struct Feature: Reducer` is accepted. Under `phaseManaged: true`, a
`.phaseMap(...)` in the child part of a composing call belongs to that child:
every argument of `Scope`, `IfLet`, `IfCaseLet`, `ForEachReducer`,
`ForEachIdentifiedReducer` and `optionalChild`, and the arguments of
`OptionalChildLifetime(parent:…reducer:)` other than `parent:`, in the
`Name(...)`, `Name<...>(...)` and `Name.init(...)` spellings. The rule is
syntactic: a child hoisted into a local constant or a combinator behind a
typealias is still read as the feature's own phase map.

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
For a shape the macro synthesizes, a manual path in an extension redeclares the generated member;
move it into the enum body, delete it, or mark the case.

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

`TestStore` deadlines default to `TestStoreDefaults.effectTimeout` (one
second). They are failure backstops, never pacing: raise them for a saturated
or parallel run with `INNOFLOW_TESTSTORE_EFFECT_TIMEOUT=<seconds>` instead of
editing tests. An override that is not used as written (clamped above one
day, or not a positive number) is reported once on standard error. Repository
test helpers scale their own deadlines with `INNOFLOW_TEST_WAIT_SCALE`, and
every suite declares a `.timeLimit`.

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
│   │   ├── Store+CancellationAcceptance.swift  # reduction-turn cancellation
│   │   ├── ReductionTurnCancellation.swift     # acceptance pass shared with TestStore
│   │   ├── StoreOutputHub.swift         # live typed reducer-output broadcast
│   │   ├── StoreEffectBridge.swift      # store/runtime bridge
│   │   ├── EffectRuntime.swift          # MainActor run-task bookkeeping
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
INNOFLOW_TESTSTORE_EFFECT_TIMEOUT=10 INNOFLOW_TEST_WAIT_SCALE=5 swift test --package-path . --parallel
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

### Runtime completion and result mapping

A throttle window fires the newest trailing request that can still proceed: cancelling the newest request's dispatch gives the window back to the request it replaced (a bounded number of superseded requests is retained), independent of whether the cancelled effect had been interpreted. The runtime owns shared throttle completion even when callers discard every handle. Dispatch observers detach independently on cancellation; they never cancel another dispatch's shared timer. Completion and cleanup are idempotent. `perform` maps directly thrown CancellationError to failure unless authoritative cancellation was accepted; general run/AsyncSequence cancellation remains a separate contract.

### Testing dispatch ownership

`TestStore.send`, scoped sends, and phase sends return discardable `TestStoreDispatch`. Effect actions retain their originating context and a queue activity lease through reduction and descendant registration. Task `finish(timeout:)` is non-consuming and diagnoses only its own unverified actions/outputs in both exhaustivity modes. It never drains another dispatch. Global store finish remains the terminal/draining API. In `.off`, receiveOutput progresses necessary FIFO actions, checks output between actions, and shares one total deadline. Exhaustive global finish snapshots actions and outputs together before cleanup.

### Optional child ownership

Use opt-in `OptionalChildLifetime` / `.optionalChild(state:action:instanceID:reducer:)` to bind child effects to an explicit instance ID. Child reduction precedes the complete parent; all owner invalidations apply before effect execution. Instance IDs must change on reopening. Slots, collection elements, nested owners and Stores isolate equal raw effect IDs. Final composed state revalidates active ownership after parent collection removal or replacement. Instance-ID projections must be pure and stable. IfCaseLet lifetime identity uses declaration source coordinates; same-helper overlapping paths require distinct stable lifetimeID values. Parent/sibling work survives child closure, and noncooperative tasks remain physically active until return. Existing IfLet runtime behavior is unchanged; its state key-path input, like Scope, ForEachReducer, ForEachIdentifiedReducer, optionalChild and PhaseMap, must preserve Sendable. Hoisted key paths use `any WritableKeyPath<...> & Sendable`; captured subscript indices must be Sendable. Lifetime projections execute as MainActor Sendable closures without unchecked lock storage. See docs/OPTIONAL_CHILD_LIFETIME.md and MIGRATION.md.

### Macro migration diagnostics

Third-generic diagnostics offer source Fix-Its using the feature's actual Output or Never. Swift.Never is accepted as the same output-free type. Explicit-reduce repairs never silently discard typed output. Strict Phase totality evaluates active Phase and phaseMap conditional branches using the compiler build configuration; unavailable configuration is an explicit strict error, not fail-open coverage. Synthesized path helpers preserve availability but do not copy constructor-specific renamed metadata.

### Scheduler admission completeness

Scheduled runs recheck their exact cancellation context before reserving capacity. A delayed older sequence cannot supersede the current latest lane. Start admission occurs exactly once after task attachment; serial promotion skips invalid pending reservations without releasing a still-running physical slot. EffectAdmission includes cancelledBeforeStart and superseded. serial(maxPending:) and queueFull capacities use UInt, removing runtime invalidCapacity rejection. Public enum cases are fixed within 6.x; additions require a major-version review.

### Testing diagnostics and reproducible lifetimes

A scenario or explorer clock step waits for its sleeper threshold within the store's `effectTimeout` only; an unmet threshold is a reported failure (scenario) or a `.configuration` failure (explorer), never a completed step or a reducer reproduction. Canonical Testing assertions carry fileID, filePath, line and column through asynchronous and scoped paths. Explicit legacy file: calls remain supported without default-call ambiguity. Active Swift Testing records a source-located Issue; XCTest uses XCTFail at filePath/line because XCTest exposes no column parameter. Public FlowScope construction is lexical via withFlowScope only. Scenario advance requires onceSleepersReach explicitly. Dispatch effectLedger is testing-only, bounded, typed, and closes after physical completion; it never changes reducer/runtime semantics.
