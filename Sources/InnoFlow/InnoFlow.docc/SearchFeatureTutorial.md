# Build a Search Feature, One Level at a Time

Start with a complete local search, then add composition and asynchronous ownership
only when the feature needs them. Finish by measuring actual phase transitions and
exploring a reproducible sequence of interactions.

This tutorial searches a small article catalog. The catalog is deliberately local:
network transport, authentication, navigation, and dependency construction belong to
the app. The final feature accepts a client so an app can supply its own transport.

Keep the declarations from each step in the same module. The three feature names
are different so each level remains independently usable. Put the test functions
in a test target that imports `InnoFlow` and `InnoFlowTesting`. Only the view in
step 2 additionally requires `InnoFlowSwiftUI` and SwiftUI on an Apple platform.

## Level 1: search with State, Action, Reduce, and Store

### 1. Make one complete synchronous feature

`State` contains the editable query and renderable results. `Action` describes the
user's intent. `Reduce` is the only place that changes those values. An empty query
returns no results; matching is case-insensitive and preserves catalog order.

```swift
import InnoFlow

enum TutorialCatalog {
  static let titles = ["Swift Concurrency", "Reducer Testing", "State and Actions"]

  static func matches(_ query: String) -> [String] {
    guard !query.isEmpty else { return [] }
    return titles.filter { $0.lowercased().contains(query.lowercased()) }
  }
}

@InnoFlow
struct BasicSearchFeature {
  struct State: Equatable, Sendable, DefaultInitializable {
    @BindableField var query = ""
    var titles: [String] = []
  }

  enum Action: Equatable, Sendable {
    case setQuery(String)
    case search
  }

  var body: some Reducer<State, Action, Never> {
    Reduce { state, action in
      switch action {
      case .setQuery(let query):
        state.query = query
      case .search:
        state.titles = TutorialCatalog.matches(state.query)
      }
      return .none
    }
  }
}
```

The third reducer generic is explicitly `Never`: this feature has no app-boundary
output. It needs no phase map, cancellation identifier, or asynchronous effect.

### 2. Bind a view through actions

The `Store` owns state. A binding sends `setQuery` instead of mutating the store
from the view. The Search button is a separate action, so typing alone does not
submit a search.

```swift
import InnoFlowSwiftUI
import SwiftUI

@MainActor
struct BasicSearchView: View {
  @State private var store = Store(reducer: BasicSearchFeature())

  var body: some View {
    VStack {
      TextField("Search articles", text: store.binding(\.$query, to: BasicSearchFeature.Action.setQuery))
        .accessibilityIdentifier("search.query")
      Button("Search") { store.send(.search) }
        .accessibilityIdentifier("search.submit")
      List(store.titles, id: \.self) { title in
        Text(title)
      }
    }
  }
}
```

The catalog's titles are unique, so `id: \.self` is sufficient here. Real articles
should carry stable IDs independent of their editable titles.

### 3. Test everything at Level 1

`TestStore` is exhaustive by default. Each assertion describes every state change;
an omitted closure means there is no change. `finish()` is the terminal check.

```swift
import InnoFlowTesting
import Testing

@Test @MainActor
func searchTutorialLevelOne() async {
  let store = TestStore(reducer: BasicSearchFeature())
  await store.send(.setQuery("SWIFT")) { $0.query = "SWIFT" }
  await store.send(.search) { $0.titles = ["Swift Concurrency"] }
  await store.send(.setQuery("missing")) { $0.query = "missing" }
  await store.send(.search) { $0.titles = [] }
  await store.send(.setQuery("")) { $0.query = "" }
  await store.send(.search)
  await store.finish()
}
```

Stop here if this solves your feature. The next levels solve additional needs.

## Level 2: compose results and emit navigation intent

### 4. Give the result list a narrow responsibility

Extract selection into `SearchResultsFeature`. Its output is a one-shot request to
open an article. The app still owns the concrete route and navigation stack. The
parent keeps query editing and searching, scopes result actions to the child, and
explicitly translates child output into its own output type.

```swift
@InnoFlow
struct SearchResultsFeature {
  struct State: Equatable, Sendable, DefaultInitializable {
    var titles: [String] = []
  }
  enum Action: Equatable, Sendable { case choose(String) }
  enum Output: Equatable, Sendable { case selected(String) }

  var body: some Reducer<State, Action, Output> {
    Reduce { state, action in
      switch action {
      case .choose(let title):
        guard state.titles.contains(title) else { return .none }
        return Self.output(.selected(title))
      }
    }
  }
}

@InnoFlow
struct ComposedSearchFeature {
  struct State: Equatable, Sendable, DefaultInitializable {
    @BindableField var query = ""
    var results = SearchResultsFeature.State()
  }
  enum Action: Equatable, Sendable {
    case setQuery(String)
    case search
    case results(SearchResultsFeature.Action)
  }
  enum Output: Equatable, Sendable { case openArticle(String) }

  var body: some Reducer<State, Action, Output> {
    CombineReducers {
      Reduce { state, action in
        switch action {
        case .setQuery(let query): state.query = query
        case .search: state.results.titles = TutorialCatalog.matches(state.query)
        case .results: break
        }
        return .none
      }
      Scope(state: \.results, action: Action.resultsCasePath, reducer: SearchResultsFeature())
        .mapOutput { output in
          switch output {
          case .selected(let title): return Output.openArticle(title)
          }
        }
    }
  }
}
```

The macro synthesizes `Action.resultsCasePath` from the single-payload action.
Reuse that path in runtime projections and tests. A scoped test still uses the
parent's queue and output type; it is not a second independent store.

### 5. Select a read model and verify output

A result-count badge can hold one `SelectedStore<Int>`. Its explicit dependency
is the list of titles, so editing the query alone does not recompute the count.
Keep this handle while using it. Closure selections are independent by default;
if you later add an `id:` for reuse, that semantic ID must cover captured inputs.

```swift
@Test @MainActor
func searchTutorialComposition() async {
  let runtime = Store(reducer: ComposedSearchFeature())
  let count = runtime.select(dependingOn: \.results.titles) { $0.count }
  let results = runtime.scope(state: \.results, action: ComposedSearchFeature.Action.resultsCasePath)
  runtime.send(.setQuery("swift"))
  #expect(count.optionalValue == 0)
  runtime.send(.search)
  #expect(count.optionalValue == 1)
  #expect(results.state.titles == ["Swift Concurrency"])

  let store = TestStore(reducer: ComposedSearchFeature())
  let child = store.scope(state: \.results, action: ComposedSearchFeature.Action.resultsCasePath)
  await store.send(.setQuery("swift")) { $0.query = "swift" }
  await store.send(.search) { $0.results.titles = ["Swift Concurrency"] }
  await child.send(.choose("missing"))
  await child.send(.choose("Swift Concurrency"))
  await store.receiveOutput(.openArticle("Swift Concurrency"))
  await store.finish()
}
```

Use `optionalValue` outside a view when the parent might have been released.
Results stay in state; output is not a restorable history. A live store-wide
`outputs()` subscription must be installed before sending. Step 9 shows a
single-dispatch capture that is installed before the action is enqueued.

## Level 3: own asynchronous searches and their phases

### 6. Add one client, one run lane, and one phase owner

Replace the local lookup with an injected client. The deterministic fixture below
throws for `offline`, letting tests exercise failure and retry without a network.
The effect waits 120 milliseconds on the store clock before calling the client.
This is a simulated request delay, not debounce: Search still submits explicitly.

`submittedQuery` records which query owns the displayed request. The user can edit
`query` during loading without changing that in-flight request. A new Search uses
the latest query and supersedes the older scheduled run.

```swift
struct TutorialSearchClient: Sendable {
  var search: @Sendable (String) async throws -> [String]

  enum Failure: Error { case offline }
  static let fixture = Self { query in
    if query.lowercased() == "offline" { throw Failure.offline }
    return TutorialCatalog.matches(query)
  }
}

@InnoFlow(phaseManaged: true, strictPhaseTotality: true)
struct ManagedSearchFeature {
  struct State: Equatable, Sendable, DefaultInitializable {
    enum Phase: Hashable, Sendable { case idle, searching, loaded, failed }
    var phase: Phase = .idle
    @BindableField var query = ""
    var submittedQuery = ""
    var results = SearchResultsFeature.State()
    var errorMessage: String?
  }
  enum Action: Equatable, Sendable {
    case setQuery(String)
    case search
    case cancelSearch
    case results(SearchResultsFeature.Action)
    case _loaded([String])
    case _failed(String)
  }
  enum Output: Equatable, Sendable { case openArticle(String) }
  struct Dependencies: Sendable { let client: TutorialSearchClient }
  private enum WorkID: Hashable, Sendable { case search }
  let dependencies: Dependencies

  init(client: TutorialSearchClient = .fixture) {
    dependencies = Dependencies(client: client)
  }

  static var phaseMap: PhaseMap<State, Action, State.Phase> {
    PhaseMap(\.phase) {
      From(.idle) { On(.search, to: .searching) }
      From(.searching) {
        On(.search, to: .searching, selfTransitionPolicy: .allow)
        On(Action.loadedCasePath, to: .loaded)
        On(Action.failedCasePath, to: .failed)
        On(.cancelSearch, to: .idle)
      }
      From(.loaded) { On(.search, to: .searching) }
      From(.failed) { On(.search, to: .searching) }
    }
  }

  var body: some Reducer<State, Action, Output> {
    CombineReducers {
      Reduce { state, action in
        switch action {
        case .setQuery(let query):
          state.query = query
          return .none
        case .search:
          state.submittedQuery = state.query
          state.results.titles = []
          state.errorMessage = nil
          let query = state.submittedQuery
          let client = dependencies.client
          return .run(id: EffectID(WorkID.search), policy: .latest) { send, context in
            do {
              try await context.sleep(for: .milliseconds(120))
              let titles = try await client.search(query)
              try await context.checkCancellation()
              await send(._loaded(titles))
            } catch {
              guard !Task.isCancelled else { return }
              await send(._failed("Search unavailable"))
            }
          }
        case .cancelSearch:
          return .cancel(EffectID(WorkID.search))
        case ._loaded(let titles):
          state.results.titles = titles
          return .none
        case ._failed(let message):
          state.errorMessage = message
          return .none
        case .results:
          return .none
        }
      }
      Scope(state: \.results, action: Action.resultsCasePath, reducer: SearchResultsFeature())
        .mapOutput { output in
          switch output {
          case .selected(let title): return Output.openArticle(title)
          }
        }
    }
  }
}
```

`PhaseMap` runs after composed reduction and owns `phase`; the base reducer never
writes it. The phase-managed macro applies the map, so do not also append
`.phaseMap(...)`. Strict totality checks direct phase declarations at compile time,
not all payloads, predicates, or possible user sequences. Coverage below measures
seven executable edges, including the explicitly allowed replacement self-edge.

The private typed work ID reserves one `.latest` lane in this example. Do not reuse
that ID with another policy. More general `.dropWhileRunning` or bounded `.serial`
flows need `onAdmission:` handling when rejection changes visible ownership.
Latest replacement cancels cooperatively and suppresses obsolete emissions; it
cannot forcibly stop a client that ignores cancellation or roll back its external
side effects. Transport retries, persistence, and transactions remain outside the
run lane.

### 7. Bound clock coordination explicitly

Manual time removes scheduling guesses. Wait for a registered sleeper before
advancing; do not insert a fixed sleep to give the effect time to start.
However, `ManualTestClock` registration waits and plain scenario advances have no
built-in deadline. This test-only helper adds a two-second wall-clock watchdog to
cooperative operations. The timer is a failure bound, not the feature's clock.

```swift
enum SearchTutorialTimeout: Error { case expired }

@MainActor
func withSearchTutorialTimeout<Value: Sendable>(
  _ operation: @escaping @MainActor @Sendable () async throws -> Value
) async throws -> Value {
  try await withThrowingTaskGroup(of: Value.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: .seconds(2))
      throw SearchTutorialTimeout.expired
    }
    defer { group.cancelAll() }
    guard let value = try await group.next() else { throw SearchTutorialTimeout.expired }
    return value
  }
}
```

Structured cancellation still joins both children. This helper cannot impose a
hard deadline on noncooperative work. Here the losing child is either a cancellable
clock wait or the watchdog's cancellable sleep. `TestStore.receive` and dispatch
`finish(timeout:)` have their own finite assertion budgets.

### 8. Observe coverage, failure, retry, replacement, and cancellation

Pass the recorder to the store explicitly. It records transitions actually applied
by the reducer, even without `through:` assertions. A map passed only to `through:`
does not install a recorder or fabricate coverage.

After the first successful search, only two of seven edges are covered. The rest
of this test exercises failure, retry, replacement, and cancellation to cover all
seven. The replacement waits for a new sleep registration, rather than merely
checking that some old sleeper still exists.

```swift
@Test @MainActor
func searchTutorialPhaseCoverage() async throws {
  let clock = ManualTestClock()
  let map = ManagedSearchFeature.phaseMap
  let coverage = PhaseCoverageRecorder(map)
  let store = TestStore(
    reducer: ManagedSearchFeature(), phaseCoverage: coverage,
    clock: clock, effectTimeout: .seconds(2)
  )
  await store.send(.setQuery("swift")) { $0.query = "swift" }
  let first = await store.send(.search, through: map) {
    $0.phase = .searching
    $0.submittedQuery = "swift"
  }
  try await withSearchTutorialTimeout {
    try await clock.advance(by: .milliseconds(120), onceSleepersReach: 1)
  }
  await store.receive(._loaded(["Swift Concurrency"]), through: map) {
    $0.phase = .loaded
    $0.results.titles = ["Swift Concurrency"]
  }
  await first.finish(timeout: .seconds(2))
  #expect(first.effectLedger.events.contains(.admitted(.started)))
  #expect(first.effectLedger.events.last == .finished)
  #expect(coverage.report().covered.count == 2)
  #expect(coverage.report().uncovered.count == 5)
  #expect(coverage.report().mermaid().contains("uncovered"))

  await store.send(.setQuery("offline")) { $0.query = "offline" }
  await store.send(.search, through: map) {
    $0.phase = .searching
    $0.submittedQuery = "offline"
    $0.results.titles = []
  }
  try await withSearchTutorialTimeout {
    try await clock.advance(by: .milliseconds(120), onceSleepersReach: 1)
  }
  await store.receive(._failed("Search unavailable"), through: map) {
    $0.phase = .failed
    $0.errorMessage = "Search unavailable"
  }

  await store.send(.setQuery("swift")) { $0.query = "swift" }
  let retry = await store.send(.search, through: map) {
    $0.phase = .searching
    $0.submittedQuery = "swift"
    $0.errorMessage = nil
  }
  try await withSearchTutorialTimeout { try await clock.waitForSleepers(atLeast: 1) }
  let registrations = await clock.sleepRegistrationCount
  await store.send(.setQuery("reducer")) { $0.query = "reducer" }
  let replacement = await store.send(.search, through: map) { $0.submittedQuery = "reducer" }
  try await withSearchTutorialTimeout {
    try await clock.waitForSleepRegistrations(toReach: registrations + 1)
  }
  await retry.finish(timeout: .seconds(2))
  #expect(retry.effectLedger.events.contains(.superseded))
  await store.send(.cancelSearch, through: map) { $0.phase = .idle }
  await replacement.finish(timeout: .seconds(2))
  #expect(await clock.sleeperCount == 0)
  #expect(store.state.results.titles.isEmpty)
  #expect(coverage.report().covered.count == 7)
  coverage.assertPhaseCoverage(minimum: .all)
  await store.finish()
}
```

Coverage is a transition metric, not proof that every client failure, query, or
race is handled. The effect ledger is testing-only and bounded; the assertions
above distinguish a physically finished dispatch from one merely cancelled.
`TestStoreDispatch.finish` does not consume pending actions or outputs, so receive
them before finishing the handle.

### 9. Keep caller lifetime separate from domain state

A `FlowTask` cancels one dispatch tree. A `FlowScope` owns only handles explicitly
tracked in its body. Neither cancellation rolls back an already-reduced phase.
Here closing a caller scope cancels its search, while the independent query edit
survives. While searching, send `cancelSearch` separately when the domain should
return to idle.

This test also captures selection output before synchronous reduction can emit it.
Diagnostics retain bounded lifecycle metadata, never search queries or results.

```swift
@Test @MainActor
func searchTutorialDispatchOwnership() async throws {
  let clock = ManualTestClock()
  let diagnostics = StoreDiagnostics(capacity: 32)
  let store = Store(
    reducer: ManagedSearchFeature(), clock: .manual(clock), diagnostics: diagnostics
  )
  store.send(.setQuery("swift"))
  try await withFlowScope { scope in
    await scope.track(store.send(.search))
    try await withSearchTutorialTimeout { try await clock.waitForSleepers(atLeast: 1) }
    await store.send(.setQuery("edited independently")).finish()
  }
  #expect(await clock.sleeperCount == 0)
  #expect(store.state.query == "edited independently")
  #expect(store.state.phase == .searching)
  await store.send(.cancelSearch).finish()
  #expect(store.state.phase == .idle)
  #expect(diagnostics.snapshot().activeDispatches.isEmpty)
  #expect(diagnostics.snapshot().records.count <= 32)

  let selections = Store(reducer: ComposedSearchFeature())
  selections.send(.setQuery("swift"))
  selections.send(.search)
  let selection = selections.send(.results(.choose("Swift Concurrency")), capturingOutputs: .unbounded)
  var outputs = selection.outputs.makeAsyncIterator()
  await selection.finish()
  #expect(await outputs.next() == .openArticle("Swift Concurrency"))
  #expect(await outputs.next() == nil)
}
```

A SwiftUI screen can use `innoFlowTask` when an action should be owned by that
view's task lifetime. Use a DEBUG-only `InnoFlowInspector` in an app to visualize
phase topology and payload-free diagnostics. Neither changes reducer semantics;
see <doc:PhaseDrivenWalkthrough> for the sample-app integration.

### 10. Explore state-aware interactions, then replay them

Build a fresh store, clock, and invariant for every attempt. The generator offers
two query choices, then submits, advances logical time only after registration,
and receives the exact expected response before observing loaded state. No live
network, wall-clock reads, or racing response choices enter the generator.

```swift
@Test @MainActor
func searchTutorialExploration() async throws {
  func makeStore(client: TutorialSearchClient = .fixture) -> TestStore<ManagedSearchFeature> {
    let store = TestStore(
      reducer: ManagedSearchFeature(client: client), clock: ManualTestClock(), effectTimeout: .seconds(2)
    )
    store.addInvariant("loaded results match the submitted query") { state in
      state.phase != .loaded || state.results.titles == TutorialCatalog.matches(state.submittedQuery)
    }
    store.addInvariant("failed searches explain the failure") { state in
      state.phase != .failed || state.errorMessage != nil
    }
    return store
  }

  func makeExplorer(faulty: Bool = false) -> TestStoreExplorer<ManagedSearchFeature> {
    TestStoreExplorer(
      seed: 0x600,
      makeStore: {
        let client = faulty ? TutorialSearchClient { _ in ["Wrong result"] } : .fixture
        return makeStore(client: client)
      },
      generator: { context in
        switch context.state.phase {
        case .idle where context.state.query.isEmpty:
          return [
            .send(.setQuery("swift"), source: ".setQuery(\"swift\")", weight: 3),
            .send(.setQuery("missing"), source: ".setQuery(\"missing\")", weight: 1),
          ]
        case .idle:
          return [.send(.search, source: ".search")]
        case .searching where context.elapsedTime < .milliseconds(120):
          return [.advance(by: .milliseconds(120), onceSleepersReach: 1)]
        case .searching:
          let titles = faulty ? ["Wrong result"] : TutorialCatalog.matches(context.state.submittedQuery)
          let expression = faulty ? "._loaded([\"Wrong result\"])" :
            (titles.isEmpty ? "._loaded([])" : "._loaded([\"Swift Concurrency\"])")
          return [.receive(._loaded(titles), source: expression)]
        case .loaded, .failed:
          return []
        }
      }
    )
  }
  let first = await makeExplorer().run(maxSteps: 8)
  let second = await makeExplorer().run(maxSteps: 8)
  #expect(first.failure == nil)
  #expect(first.cleanupCompleted)
  #expect(first.steps.count == 4)
  #expect(first.steps == second.steps)
  #expect(first.scenario.seed == 0x600)

  let replay = makeStore()
  replay.exhaustivity = .off
  let replayResult = try await withSearchTutorialTimeout { await first.scenario.run(on: replay) }
  #expect(!replayResult.wasCancelled)
  #expect(replayResult.completedStepCount == 4)
  #expect(replay.state.phase == .loaded)
  await replay.finish()

  let bug = await makeExplorer(faulty: true).run(maxSteps: 8)
  #expect(bug.failure?.kind == .diagnostic)
  #expect(bug.failure?.signature == "TestStore invariant failed: loaded results match the submitted query")
  #expect(bug.replayValidated)
  #expect(bug.cleanupCompleted)
  #expect(bug.minimizedSteps.count == 4)
  #expect(bug.scenarioSource(reducerType: "ManagedSearchFeature").contains("seed: 1536"))
}
```

The explorer uses a fixed seeded PRNG and limits each initial search to eight
interactions here. Failure replay and minimization make additional fresh attempts;
`maxSteps` is not a total wall-clock budget. Clock-registration waits use the
store timeout. This small generator
searches a request with two query choices. Its normal client succeeds; the
explicitly faulty client returns a wrong title and must fail the named invariant.
Both fixtures are deterministic. This generator does not prove cancellation or
transport-failure coverage; the preceding explicit tests cover those paths.
A seed alone cannot make real transport or unsynchronized effects deterministic.

On an invariant or reducer failure, inspect `failure`, `replayValidated`, and
`cleanupCompleted` before trusting `minimizedSteps`. Replay validation means a
fresh attempt reproduced the same failure signature; deletion-minimization keeps
generator prerequisites valid and does not claim a globally minimal input.
Configuration failures are separate from reducer bugs. If cleanup cannot join a
noncooperative effect within budget, further attempts stop.

`result.scenarioSource(reducerType: "ManagedSearchFeature")` produces copyable
scenario code for an equivalently configured fresh store and clock. A scenario
executes recorded steps, not new random choices. Keep the watchdog when running
copied plain clock advances. The faulty-client run above discovers and
replay-validates the invariant failure.
All four steps remain necessary because the state-aware generator requires a query,
submission, and time advance before receiving a result. A successful bounded search
reports no found failure, not that no bug exists. For a failure with removable
noise actions, see the `PhaseExplorationConsistencyTests` regression fixture.

## What to keep

- Level 1 is sufficient for the complete local search and its exhaustive test
- Level 2 adds reusable child ownership, selective read models, and typed app intent
- Level 3 adds explicit request lifetime, domain phases, diagnostics, and stronger tests
- The app supplies transport and navigation; InnoFlow continues to own business transitions

All Swift fences in this article are inputs to `scripts/check-doc-copyable-examples.rb`.
`SearchTutorial` compiles the non-UI declarations and executes five named tests;
`SearchTutorialView` separately compiles the SwiftUI view. The fence gate requires
an Apple toolchain. A static review or a Linux compatibility probe does not verify
SwiftUI, macro loading on Apple, or the full release/runtime matrix.
