// MARK: - TestStoreCoreTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import Testing
import os

@testable import InnoFlowCore
@testable import InnoFlowTesting

// MARK: - TestStore Core Tests

@Suite("TestStore Core Tests", .serialized)
@MainActor
struct TestStoreCoreTests {
  @Test("TestStore validates send + receive with deterministic flow")
  func testStoreReceive() async {
    let store = TestStore(
      reducer: AsyncFeature(),
      initialState: .init(),
      // CI can heavily saturate the cooperative executor while multiple suites
      // start together. Keep this basic smoke test tolerant of startup jitter;
      // the stronger 40-iteration test below still validates deterministic
      // first-delivery behavior under the tighter budget.
      effectTimeout: .seconds(60)
    )

    await store.send(.load) {
      $0.isLoading = true
    }

    await store.receive(._loaded("Hello, InnoFlow")) {
      $0.value = "Hello, InnoFlow"
      $0.isLoading = false
    }

    await store.assertNoBufferedActions()
  }

  @Test("TestStore run effects deliver their first emission deterministically")
  func testStoreRunEffectsDeliverFirstEmissionDeterministically() async {
    for _ in 0..<40 {
      let store = TestStore(
        reducer: AsyncFeature(),
        initialState: .init(),
        effectTimeout: .seconds(60)
      )

      await store.send(.load) {
        $0.isLoading = true
      }

      await store.receive(._loaded("Hello, InnoFlow")) {
        $0.value = "Hello, InnoFlow"
        $0.isLoading = false
      }

      await store.assertNoBufferedActions()
    }
  }

  @Test("TestStore async cancellation API prevents pending effect emission")
  func testStoreCancelEffects() async {
    let store = TestStore(reducer: CancellableFeature(), initialState: .init())

    await store.send(.start(1)) {
      $0.requested = 1
    }

    await store.cancelEffects(identifiedBy: "load")
    await store.assertNoMoreActions()
  }

  @Test("TestStore drops emissions from cancelled uncooperative effects")
  func testStoreDropsCancelledEffectEmission() async {
    let store = TestStore(
      reducer: UncooperativeCancellableFeature(),
      initialState: .init()
    )

    await store.send(.start)
    await store.cancelEffects(identifiedBy: "uncooperative")
    await store.assertNoMoreActions()
  }

  @Test("TestStore outer cancellation reaches nested cancellable run tasks")
  func testStoreOuterCancellationReachesNestedCancellableRunTasks() async {
    let clock = ManualTestClock()
    let store = TestStore(
      reducer: NestedCancellableFeature(),
      initialState: .init(),
      clock: clock,
      effectTimeout: .milliseconds(20)
    )

    await store.send(.start)
    _ = await waitUntilAsync {
      await clock.sleeperCount == 1
    }

    await store.cancelEffects(identifiedBy: "outer-cancellation")
    await clock.advance(by: .milliseconds(100))

    await store.assertNoMoreActions()
  }

  @Test("TestStore drops direct .send actions after a cancellation boundary")
  func testStoreDirectSendDropsAfterCancellationBoundary() async {
    let store = TestStore(
      reducer: DirectSendCancellationBoundaryFeature(),
      initialState: .init(),
      effectTimeout: .milliseconds(100)
    )

    await store.send(.start)
    await store.assertNoMoreActions()
  }

  @Test("TestStore filters stale queued actions at assertion time")
  func testStoreFiltersStaleQueuedActionsAtAssertionTime() async {
    let id = AnyEffectID(StaticEffectID("queued-stale-action"))
    let context = EffectExecutionContext(cancellationID: id, sequence: 1)
    let store = TestStore(
      reducer: CounterFeature(),
      initialState: .init(),
      effectTimeout: .milliseconds(20)
    )

    store.deliverAction(.increment, context: context)
    await drainAsyncWork()
    await store.cancelEffects(id: id, context: .init(sequence: 1))

    await store.assertNoBufferedActions()
    await store.assertNoMoreActions()
  }

  @Test("TestStore cancelled run tasks do not start after the gate opens")
  func testStoreCancelledRunTasksDoNotStartAfterGateOpens() async {
    let probe = RunStartGateRaceProbe()
    let store = TestStore(
      reducer: RunStartGateRaceFeature(probe: probe),
      initialState: .init(),
      effectTimeout: .milliseconds(20)
    )

    await store.send(.start) {
      $0.requested = true
    }
    await store.cancelEffects(identifiedBy: "start-gate-race")
    await drainAsyncWork()

    #expect(await probe.started == 0)
    await store.assertNoBufferedActions()
  }

  @Test("TestStore debounce skips stale effects at cancellation boundaries")
  func testStoreDebounceSkipsStaleEffectsAtCancellationBoundaries() async {
    let id = AnyEffectID(StaticEffectID("teststore-stale-debounce"))
    let store = TestStore(reducer: CounterFeature(), initialState: .init())
    let probe = InstrumentationProbe()

    await store.cancelEffects(id: id, context: .init(sequence: 1))
    await store.debounce(
      EffectTask<CounterFeature.Action>.none,
      id: id,
      interval: .milliseconds(0),
      context: .init(cancellationID: id, sequence: 1),
      awaited: true
    ) { _, _, _ in
      probe.record("recursed")
    }

    #expect(probe.events.isEmpty)
  }

  @Test("TestStore trailing throttle skips stale effects at cancellation boundaries")
  func testStoreTrailingThrottleSkipsStaleEffectsAtCancellationBoundaries() async {
    let id = AnyEffectID(StaticEffectID("teststore-stale-throttle"))
    let store = TestStore(reducer: CounterFeature(), initialState: .init())
    let context = EffectExecutionContext(cancellationID: id, sequence: 1)
    let probe = InstrumentationProbe()

    await store.cancelEffects(id: id, context: .init(sequence: 1))
    store.throttleState.storePending(
      EffectTask<CounterFeature.Action>.none, context: context, for: id)
    store.scheduleTrailingDrain(for: id, interval: .milliseconds(0)) { _, _, _ in
      probe.record("recursed")
    }

    await waitUntil {
      store.throttleState.pending(for: id) == nil
    }

    #expect(probe.events.isEmpty)
  }

  @Test("TestStore repeated cancellation stress keeps queue clean")
  func testStoreCancellationStress() async {
    let store = TestStore(
      reducer: UncooperativeCancellableFeature(),
      initialState: .init()
    )
    let iterations = isHeavyStressEnabled ? 1_000 : 120

    for _ in 0..<iterations {
      await store.send(.start)
      await store.cancelEffects(identifiedBy: "uncooperative")
    }

    await store.assertNoMoreActions()
  }

  @Test("TestStore diff renderer reports nested paths")
  func stateDiffRenderer() {
    struct NestedState: Equatable, Sendable {
      var phase = "loading"
      var items = [Item(title: "Draft"), Item(title: "Draft")]

      struct Item: Equatable, Sendable {
        var title: String
      }
    }

    let diff = renderStateDiff(
      expected: NestedState(phase: "loaded", items: [.init(title: "Draft"), .init(title: "Done")]),
      actual: NestedState(phase: "loading", items: [.init(title: "Draft"), .init(title: "Draft")])
    )

    #expect(diff?.contains("phase: expected \"loaded\", actual \"loading\"") == true)
    #expect(diff?.contains("items[1].title: expected \"Done\", actual \"Draft\"") == true)
  }

  @Test("TestStore diff renderer uses the default 12-line cap")
  func stateDiffRendererUsesDefaultCap() {
    let diff = renderStateDiff(
      expected: Array(0..<20),
      actual: Array(100..<120)
    )

    #expect(diff?.split(separator: "\n").count == 12)
  }

  @Test("TestStore diff renderer returns nil when lineLimit is non-positive")
  func stateDiffRendererNilForNonPositiveLineLimit() {
    let diff = renderStateDiff(
      expected: [1, 2, 3],
      actual: [4, 5, 6],
      lineLimit: 0
    )

    #expect(diff == nil)
  }

  @Test("TestStore diff renderer uses stable summary output for sets")
  func stateDiffRendererUsesStableSetSummary() {
    let diff = renderStateDiff(
      expected: Set(["beta", "alpha"]),
      actual: Set(["gamma", "alpha"])
    )

    #expect(diff == #"state: expected Set(["alpha", "beta"]), actual Set(["alpha", "gamma"])"#)
  }

  @Test("TestStore diff renderer treats reordered dictionaries as equal")
  func stateDiffRendererIgnoresDictionaryInsertionOrder() {
    let expected = ["alpha": 1, "beta": 2]
    let actual = Dictionary(uniqueKeysWithValues: [("beta", 2), ("alpha", 1)])

    let diff = renderStateDiff(expected: expected, actual: actual)

    #expect(diff == nil)
  }

  @Test("TestStore diff line limit resolves env and explicit overrides")
  func testStoreDiffLineLimitResolution() {
    #expect(
      resolveDiffLineLimit(
        explicit: nil,
        environment: [testStoreDiffLineLimitEnvironmentKey: "18"]
      ) == 18
    )
    #expect(
      resolveDiffLineLimit(
        explicit: 5,
        environment: [testStoreDiffLineLimitEnvironmentKey: "18"]
      ) == 5
    )
    #expect(
      resolveDiffLineLimit(
        explicit: 0,
        environment: [testStoreDiffLineLimitEnvironmentKey: "18"]
      ) == 0
    )
    #expect(
      resolveDiffLineLimit(
        explicit: nil,
        environment: [testStoreDiffLineLimitEnvironmentKey: "0"]
      ) == 0
    )
    #expect(
      resolveDiffLineLimit(
        explicit: nil,
        environment: [testStoreDiffLineLimitEnvironmentKey: "-3"]
      ) == defaultStateDiffLineLimit
    )
    #expect(
      resolveDiffLineLimit(
        explicit: nil,
        environment: [testStoreDiffLineLimitEnvironmentKey: "abc"]
      ) == defaultStateDiffLineLimit
    )
  }

  @Test("ScopedTestStore inherits the resolved parent diff line limit")
  func scopedTestStoreInheritsParentDiffLimit() {
    let store = TestStore(
      reducer: ScopedTestHarnessFeature(),
      initialState: .init(),
      diffLineLimit: 3
    )
    let child = store.scope(state: \.child, action: ScopedTestHarnessFeature.Action.childCasePath)

    #expect(store.resolvedDiffLineLimit == 3)
    #expect(child.resolvedDiffLineLimit == 3)
  }

  @Test("TestStore phase helper ignores same-phase actions and validates legal transitions")
  func testStorePhaseHelperSamePhase() async {
    let store = TestStore(reducer: ValidatedPhaseReducer(), initialState: .init())

    await store.send(.noop, tracking: \.phase, through: ValidatedPhaseReducer.graph)
    await store.send(.load, tracking: \.phase, through: ValidatedPhaseReducer.graph) {
      $0.phase = .loading
    }
    await store.send(.finish, tracking: \.phase, through: ValidatedPhaseReducer.graph) {
      $0.phase = .loaded
    }
  }

  @Test("PhaseMap applies basic and payload-aware transitions through the testing helper")
  func phaseMapBasicAndPayloadAwareTransitions() async {
    let map: PhaseMap<PhaseMapHarness.State, PhaseMapHarness.Action, PhaseMapHarness.State.Phase> =
      PhaseMapHarness.phaseMap
    let store = TestStore(reducer: PhaseMapHarness(), initialState: .init())

    await store.send(.load, through: map) {
      $0.phase = .loading
      $0.errorMessage = nil
    }

    await store.send(.loaded([1, 2, 3]), through: map) {
      $0.phase = .loaded
      $0.values = [1, 2, 3]
      $0.errorMessage = nil
    }
  }

  @Test("PhaseMap ignores unmatched actions and source phases")
  func phaseMapIgnoresUnmatchedTransitions() async {
    let map: PhaseMap<PhaseMapHarness.State, PhaseMapHarness.Action, PhaseMapHarness.State.Phase> =
      PhaseMapHarness.phaseMap
    let store = TestStore(reducer: PhaseMapHarness(), initialState: .init())

    await store.send(.noop, through: map)
    #expect(store.state.phase == .idle)

    await store.send(.loaded([42]), through: map) {
      $0.values = [42]
      $0.errorMessage = nil
    }
    #expect(store.state.phase == .idle)
  }

  @Test("PhaseMap guard uses post-reduce state for conditional targets")
  func phaseMapGuardUsesPostReduceState() async {
    let map: PhaseMap<PhaseMapHarness.State, PhaseMapHarness.Action, PhaseMapHarness.State.Phase> =
      PhaseMapHarness.phaseMap
    let store = TestStore(
      reducer: PhaseMapHarness(),
      initialState: .init(phase: .failed, values: [], errorMessage: "boom")
    )

    await store.send(.replaceAndDismiss([7]), through: map) {
      $0.phase = .loaded
      $0.values = [7]
      $0.errorMessage = nil
    }
  }

  @Test("PhaseMap treats nil or same-phase guard results as no-op transitions")
  func phaseMapGuardNoOps() async {
    let map: PhaseMap<PhaseMapHarness.State, PhaseMapHarness.Action, PhaseMapHarness.State.Phase> =
      PhaseMapHarness.phaseMap
    let store = TestStore(
      reducer: PhaseMapHarness(),
      initialState: .init(phase: .failed, values: [1], errorMessage: "boom")
    )

    await store.send(.maybeRecover(false), through: map)
    #expect(store.state.phase == .failed)

    await store.send(.replaceAndDismiss([]), through: map) {
      $0.phase = .idle
      $0.values = []
      $0.errorMessage = nil
    }
  }

  @Test("PhaseMap diagnostics exposes direct phase mutation events")
  func phaseMapDiagnosticsReportsDirectMutation() {
    enum Phase: Equatable, Hashable, Sendable {
      case idle
      case loaded
      case failed
    }
    struct State: Equatable, Sendable {
      var phase: Phase = .idle
    }
    enum Action: Equatable, Sendable {
      case load
    }

    let probe = InstrumentationProbe()
    let diagnostics = PhaseMapDiagnostics<Action, Phase> { violation in
      if case .directPhaseMutation(
        action: _,
        previousPhase: let previousPhase,
        postReducePhase: let postReducePhase
      ) = violation {
        probe.record("direct:\(previousPhase):\(postReducePhase)")
      }
    }

    diagnostics.report(
      .directPhaseMutation(action: .load, previousPhase: .idle, postReducePhase: .failed)
    )

    #expect(probe.events == ["direct:idle:failed"])
  }

  @Test("PhaseMap diagnostics can be attached without changing legal transitions")
  func phaseMapDiagnosticsPreservesLegalTransitionSemantics() {
    enum Phase: Equatable, Hashable, Sendable {
      case idle
      case loaded
    }
    struct State: Equatable, Sendable {
      var phase: Phase = .idle
    }
    enum Action: Equatable, Sendable {
      case load
    }

    let probe = InstrumentationProbe()
    let map: PhaseMap<State, Action, Phase> = PhaseMap(
      \State.phase,
      diagnostics: .init { _ in
        probe.record("violation")
      }
    ) {
      From(.idle) {
        On(.load, to: .loaded)
      }
    }
    let reducer = Reduce<State, Action> { _, action in
      switch action {
      case .load:
        return .none
      }
    }
    .phaseMap(map)

    var state = State()
    _ = reducer.reduce(into: &state, action: Action.load)

    #expect(state.phase == .loaded)
    #expect(probe.events.isEmpty)
  }

  @Test("PhaseMap diagnostics reports undeclared dynamic targets")
  func phaseMapDiagnosticsReportsUndeclaredTarget() {
    enum Phase: Equatable, Hashable, Sendable {
      case idle
      case loaded
      case failed
    }
    struct State: Equatable, Sendable {
      var phase: Phase = .idle
      var reducerWork = 0
    }
    enum Action: Equatable, Sendable {
      case load
    }

    let probe = InstrumentationProbe()
    let diagnostics = PhaseMapDiagnostics<Action, Phase> { violation in
      if case .undeclaredTarget(
        action: _,
        sourcePhase: let sourcePhase,
        target: let target,
        declaredTargets: let declaredTargets
      ) = violation {
        probe.record("undeclared:\(sourcePhase):\(target):\(declaredTargets.contains(.loaded))")
      }
    }

    diagnostics.report(
      .undeclaredTarget(
        action: .load,
        sourcePhase: .idle,
        target: .failed,
        declaredTargets: [.loaded]
      )
    )

    #expect(probe.events == ["undeclared:idle:failed:true"])
  }

  @Test("PhaseMap uses declared ordering when multiple transitions match")
  func phaseMapFirstMatchWins() async {
    let map:
      PhaseMap<
        PhaseMapOrderingHarness.State, PhaseMapOrderingHarness.Action,
        PhaseMapOrderingHarness.State.Phase
      > = PhaseMapOrderingHarness.phaseMap
    let store = TestStore(reducer: PhaseMapOrderingHarness(), initialState: .init())

    await store.send(.advance, through: map) {
      $0.phase = .first
    }
  }

  @Test("PhaseMap preserves ordering across separate rule blocks for the same source phase")
  func phaseMapPreservesOrderingAcrossSeparateRuleBlocks() async {
    struct Harness: Reducer {
      struct State: Equatable, Sendable, DefaultInitializable {
        enum Phase: Equatable, Hashable, Sendable {
          case idle
          case first
          case second
        }

        var phase: Phase = .idle
      }

      enum Action: Equatable, Sendable {
        case advance
      }

      static var phaseMap: PhaseMap<State, Action, State.Phase> {
        PhaseMap(\State.phase) {
          From(.idle) {
            On(.advance, to: .first)
          }
          From(.idle) {
            On(where: { $0 == .advance }, targets: [.second]) { _, _ in .second }
          }
        }
      }

      func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
        Reduce<State, Action> { _, _ in .none }
          .phaseMap(Self.phaseMap)
          .reduce(into: &state, action: action)
      }
    }

    let store = TestStore(reducer: Harness(), initialState: .init())

    await store.send(.advance, through: Harness.phaseMap) {
      $0.phase = .first
    }
    await store.assertNoMoreActions()
  }

  @Test("PhaseMap derivedGraph can be validated with existing graph helpers")
  func phaseMapDerivedGraphValidation() {
    let graph: PhaseTransitionGraph<PhaseMapHarness.State.Phase> = PhaseMapHarness.phaseGraph
    assertValidGraph(
      graph,
      allPhases: [.idle, .loading, .loaded, .failed],
      root: .idle
    )
    #expect(graph.successors(from: .failed) == [.idle, .loaded])
  }

  @Test("PhaseMap opt-in validation reports clean coverage when expected triggers are declared")
  func phaseMapValidationReportCoveredTriggers() {
    let report = PhaseMapHarness.phaseMap.validationReport(
      expectedTriggersByPhase: [
        .idle: [
          .action(.load)
        ],
        .loading: [
          .casePath(PhaseMapHarness.loadedCasePath, label: "loaded", sample: [1, 2, 3]),
          .casePath(PhaseMapHarness.failedCasePath, label: "failed", sample: "boom"),
        ],
        .failed: [
          .casePath(
            PhaseMapHarness.replaceAndDismissCasePath, label: "replaceAndDismiss", sample: [7]),
          .casePath(PhaseMapHarness.maybeRecoverCasePath, label: "maybeRecover", sample: true),
        ],
      ]
    )

    #expect(report.isEmpty)
    #expect(report.missingTriggers.isEmpty)
  }

  @Test("PhaseMap testing helper asserts clean coverage for expected triggers")
  func phaseMapTestingHelperAssertsCoverage() {
    let report = assertPhaseMapCovers(
      PhaseMapHarness.phaseMap,
      expectedTriggersByPhase: [
        .idle: [
          .action(.load)
        ],
        .loading: [
          .casePath(PhaseMapHarness.loadedCasePath, label: "loaded", sample: [1, 2, 3]),
          .casePath(PhaseMapHarness.failedCasePath, label: "failed", sample: "boom"),
        ],
        .failed: [
          .casePath(
            PhaseMapHarness.replaceAndDismissCasePath,
            label: "replaceAndDismiss",
            sample: [7]
          ),
          .casePath(PhaseMapHarness.maybeRecoverCasePath, label: "maybeRecover", sample: true),
        ],
      ]
    )

    #expect(report.isEmpty)
    #expect(report.missingTriggers.isEmpty)
  }

  @Test(
    "PhaseMap opt-in validation reports missing triggers while runtime semantics stay partial-by-default"
  )
  func phaseMapValidationReportMissingTriggers() async {
    let report = PhaseMapHarness.phaseMap.validationReport(
      expectedTriggersByPhase: [
        .idle: [
          .action(.noop, label: "noop")
        ],
        .failed: [
          .action(.load, label: "retry load")
        ],
      ]
    )

    #expect(report.isEmpty == false)
    #expect(
      Set(report.missingTriggers)
        == Set([
          .init(sourcePhase: .idle, trigger: "noop"),
          .init(sourcePhase: .failed, trigger: "retry load"),
        ])
    )

    let store = TestStore(reducer: PhaseMapHarness(), initialState: .init())
    await store.send(.noop, through: PhaseMapHarness.phaseMap)
    #expect(store.state.phase == .idle)
  }

  @Test("PhaseMap validation report combines repeated source-phase blocks via the source index")
  func phaseMapValidationReportUsesIndexedRulesForRepeatedSourcePhases() {
    enum Phase: Hashable, Sendable {
      case idle
      case loading
      case loaded
      case failed
    }

    struct State: Equatable, Sendable {
      var phase: Phase
    }

    enum Action: Equatable, Sendable {
      case load
      case loaded([Int])
      case failed(String)
    }

    let loadedCasePath = CasePath<Action, [Int]>(
      embed: Action.loaded,
      extract: { action in
        guard case .loaded(let payload) = action else { return nil }
        return payload
      }
    )

    let failedCasePath = CasePath<Action, String>(
      embed: Action.failed,
      extract: { action in
        guard case .failed(let payload) = action else { return nil }
        return payload
      }
    )

    let map = PhaseMap<State, Action, Phase>(\.phase) {
      From(.idle) {
        On(.load, to: .loading)
      }
      From(.loading) {
        On(loadedCasePath, to: .loaded)
      }
      From(.loading) {
        On(failedCasePath, to: .failed)
      }
    }

    let report = map.validationReport(
      expectedTriggersByPhase: [
        .loading: [
          .casePath(loadedCasePath, label: "loaded", sample: [1, 2, 3]),
          .casePath(failedCasePath, label: "failed", sample: "boom"),
        ]
      ]
    )

    // Trigger coverage still resolves through the source-phase index even when
    // the author splits `.loading` across multiple `From(...)` blocks.
    #expect(report.missingTriggers.isEmpty)
    // The split itself is now surfaced as a duplicate-From diagnostic so the
    // author can collapse it into a single block.
    #expect(report.duplicateSourcePhases == [.loading])
    #expect(report.isEmpty == false)
  }

  @Test("PhaseMap validation report surfaces duplicate From blocks in first-seen order")
  func phaseMapValidationReportSurfacesDuplicateFromBlocks() {
    enum Phase: Hashable, Sendable {
      case idle
      case loading
      case loaded
      case failed
    }

    struct State: Equatable, Sendable {
      var phase: Phase
    }

    enum Action: Equatable, Sendable {
      case load
      case retry
      case finish
      case fail
    }

    let map = PhaseMap<State, Action, Phase>(\.phase) {
      From(.idle) {
        On(.load, to: .loading)
      }
      From(.loading) {
        On(.finish, to: .loaded)
      }
      From(.idle) {
        On(.retry, to: .loading)
      }
      From(.loading) {
        On(.fail, to: .failed)
      }
    }

    let report = map.validationReport()
    #expect(report.missingTriggers.isEmpty)
    #expect(report.duplicateSourcePhases == [.idle, .loading])
    #expect(report.isEmpty == false)
  }

  @Test("PhaseMap validation report is clean when each source phase has a single From block")
  func phaseMapValidationReportCleanWhenNoDuplicateFromBlocks() {
    let report = PhaseMapHarness.phaseMap.validationReport()
    #expect(report.duplicateSourcePhases.isEmpty)
    #expect(report.isEmpty)
  }

  @Test("On(selfTransitionPolicy: .ignore) silently skips same-phase resolutions")
  func phaseMapSelfTransitionPolicyIgnoreSilent() {
    enum Phase: Hashable, Sendable {
      case running
      case stopped
    }
    struct State: Equatable, Sendable {
      var phase: Phase = .running
    }
    enum Action: Equatable, Sendable {
      case tick
    }

    let probe = InstrumentationProbe()
    let map = PhaseMap<State, Action, Phase>(
      \.phase,
      diagnostics: .init { _ in probe.record("violation") }
    ) {
      From(.running) {
        On(
          .tick,
          targets: [.running, .stopped],
          resolve: { _ in .running }
        )
      }
    }
    let reducer = Reduce<State, Action> { _, _ in .none }.phaseMap(map)

    var state = State()
    _ = reducer.reduce(into: &state, action: .tick)

    #expect(state.phase == .running)
    #expect(probe.events.isEmpty)
  }

  @Test("PhaseMap diagnostics exposes illegalSelfTransition events")
  func phaseMapDiagnosticsReportsIllegalSelfTransition() {
    enum Phase: Hashable, Sendable {
      case running
      case stopped
    }
    enum Action: Equatable, Sendable {
      case tick
    }

    let probe = InstrumentationProbe()
    let diagnostics = PhaseMapDiagnostics<Action, Phase> { violation in
      if case .illegalSelfTransition(action: _, phase: let phase) = violation {
        probe.record("self:\(phase)")
      }
    }

    diagnostics.report(.illegalSelfTransition(action: .tick, phase: .running))

    #expect(probe.events == ["self:running"])
  }

  @Test("On(selfTransitionPolicy: .allow) writes the resolved phase even when equal to the source")
  func phaseMapSelfTransitionPolicyAllowWritesPhase() {
    enum Phase: Hashable, Sendable {
      case running
      case stopped
    }
    struct State: Equatable, Sendable {
      var phase: Phase = .running
      var observerTicks = 0
    }
    enum Action: Equatable, Sendable {
      case tick
    }

    let probe = InstrumentationProbe()
    let map = PhaseMap<State, Action, Phase>(
      \.phase,
      diagnostics: .init { _ in probe.record("violation") }
    ) {
      From(.running) {
        On(
          .tick,
          targets: [.running, .stopped],
          selfTransitionPolicy: .allow,
          resolve: { _ in .running }
        )
      }
    }
    let reducer = Reduce<State, Action> { state, _ in
      state.observerTicks += 1
      return .none
    }
    .phaseMap(map)

    var state = State()
    _ = reducer.reduce(into: &state, action: .tick)

    #expect(state.phase == .running)
    #expect(state.observerTicks == 1)
    #expect(probe.events.isEmpty)
  }

  @Test("PhaseMap supports predicate-based fixed-target, nil-guard, and same-phase guard paths")
  func phaseMapPredicatePaths() async {
    let map:
      PhaseMap<
        PhaseMapPredicateHarness.State,
        PhaseMapPredicateHarness.Action,
        PhaseMapPredicateHarness.State.Phase
      > = PhaseMapPredicateHarness.phaseMap
    let store = TestStore(reducer: PhaseMapPredicateHarness(), initialState: .init())

    await store.send(.start, through: map) {
      $0.phase = .loading
    }

    await store.send(.configure(false), through: map) {
      $0.phase = .loading
      $0.shouldAdvance = false
    }

    await store.send(.refresh, through: map) {
      $0.phase = .loading
    }

    await store.send(.configure(true), through: map) {
      $0.phase = .loaded
      $0.shouldAdvance = true
    }
  }

  @Test("CasePath round-trips embedded values")
  func casePathRoundTrip() {
    let childAction = ScopedTestHarnessFeature.ChildAction.finished
    let rootAction = ScopedTestHarnessFeature.Action.childCasePath.embed(childAction)

    #expect(rootAction == .child(.finished))
    #expect(ScopedTestHarnessFeature.Action.childCasePath.extract(rootAction) == childAction)
    #expect(ScopedTestHarnessFeature.Action.childCasePath.extract(.child(.start)) == .start)
  }

  @Test("assertCasePathExtracts returns the matched case payload")
  func assertCasePathExtractsSuccess() throws {
    let rootAction = ScopedTestHarnessFeature.Action.child(.finished)
    let extracted = try #require(
      assertCasePathExtracts(
        rootAction,
        via: ScopedTestHarnessFeature.Action.childCasePath,
        caseName: "child"
      )
    )

    #expect(extracted == .finished)
  }

  @Test("assertCasePathExtracts formats mismatch context for diagnostics")
  func assertCasePathExtractsFailureFormatting() {
    enum ProbeRoot: Equatable, Sendable {
      case child(Int)
      case other(String)
    }

    let message = casePathExtractionFailureMessage(
      root: ProbeRoot.other("unexpected"),
      caseName: "child"
    )

    #expect(message.contains("expected case path did not match") == true)
    #expect(message.contains("Expected case: child") == true)
    #expect(message.contains("ProbeRoot") == true)
    #expect(message.contains("other") == true)
  }

  @Test("CollectionActionPath round-trips embedded values")
  func collectionActionPathRoundTrip() {
    let childAction = ScopedCollectionFeature.TodoAction.setDone(true)
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let rootAction = ScopedCollectionFeature.Action.todoActionPath.embed(id, childAction)

    #expect(rootAction == .todo(id: id, action: .setDone(true)))
    #expect(ScopedCollectionFeature.Action.todoActionPath.extract(rootAction)?.0 == id)
    #expect(ScopedCollectionFeature.Action.todoActionPath.extract(rootAction)?.1 == childAction)
    #expect(ScopedCollectionFeature.Action.todoActionPath.extract(.moveLastToFront) == nil)
  }

  @Test("ScopedTestStore forwards child actions through the parent TestStore")
  func scopedTestStoreSendAndReceive() async {
    let store = TestStore(
      reducer: ScopedTestHarnessFeature(),
      initialState: .init()
    )
    let child = store.scope(state: \.child, action: ScopedTestHarnessFeature.Action.childCasePath)

    await child.send(.start) {
      $0.log = ["start"]
    }
    await child.receive(.finished) {
      $0.log = ["start", "finished"]
    }
    await child.assertNoMoreActions()
  }

  @Test("ScopedTestStore collection helper targets a single element by id")
  func scopedTestStoreCollectionProjection() async {
    let store = TestStore(
      reducer: ScopedCollectionFeature(),
      initialState: .init()
    )
    let targetID = store.state.todos[1].id
    let todo = store.scope(
      collection: \.todos,
      id: targetID,
      action: ScopedCollectionFeature.Action.todoActionPath
    )

    #expect(todo.title == "Two")
    #expect(todo.isDone == false)

    await todo.send(.setDone(true)) {
      $0.isDone = true
    }

    #expect(store.state.todos[0].isDone == false)
    #expect(store.state.todos[1].isDone == true)
    #expect(store.state.todos[2].isDone == false)
  }

  @Test("ScopedTestStore assert helper verifies current child state")
  func scopedTestStoreAssertHelper() async {
    let store = TestStore(
      reducer: ScopedCollectionFeature(),
      initialState: .init()
    )
    let targetID = store.state.todos[1].id
    let todo = store.scope(
      collection: \.todos,
      id: targetID,
      action: ScopedCollectionFeature.Action.todoActionPath
    )

    await todo.send(.setDone(true))
    todo.assert {
      $0.isDone = true
    }
  }
}
