// MARK: - StoreInstrumentationTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import OSLog
import Testing
import os

@testable import InnoFlowCore
@testable import InnoFlowTesting

// MARK: - Store Instrumentation Tests

private final class DescriptionCounter: Sendable {
  private let lock = OSAllocatedUnfairLock<Int>(initialState: 0)

  var count: Int {
    lock.withLock { $0 }
  }

  func increment() {
    lock.withLock { $0 += 1 }
  }
}

private struct DescriptionCountingAction: Sendable, CustomStringConvertible {
  let counter: DescriptionCounter

  var description: String {
    counter.increment()
    return "sensitive-action"
  }
}

@Suite("Store Instrumentation Tests", .serialized)
@MainActor
struct StoreInstrumentationTests {
  @Test("Store processes async run effect")
  func storeAsyncEffect() async {
    let store = Store(reducer: AsyncFeature(), initialState: .init())

    store.send(.load)
    #expect(store.isLoading)

    await waitUntil(timeout: .seconds(60), pollInterval: .milliseconds(10)) {
      store.value == "Hello, InnoFlow" && store.isLoading == false
    }

    #expect(store.value == "Hello, InnoFlow")
    #expect(store.isLoading == false)
  }

  @Test("Store instrumentation records run lifecycle and emitted actions")
  func storeInstrumentationRunLifecycle() async {
    let probe = InstrumentationProbe()
    let store = Store(
      reducer: InstrumentationFeature(),
      initialState: .init(),
      instrumentation: .init(
        didStartRun: { event in
          probe.record("start:\(event.cancellationID?.description ?? "nil")")
        },
        didFinishRun: { event in
          probe.record("finish:\(event.cancellationID?.description ?? "nil")")
        },
        didEmitAction: { event in
          probe.record("emit:\(event.action)")
        }
      )
    )

    store.send(.startDelayed)
    await waitUntil(timeout: .seconds(60), pollInterval: .milliseconds(10)) {
      store.state.log == ["delayed"]
        && probe.events.contains("start:instrumented-delayed")
        && probe.events.contains("emit:received(\"delayed\")")
        && probe.events.contains("finish:instrumented-delayed")
    }

    #expect(store.state.log == ["delayed"])
    #expect(probe.events.contains("start:instrumented-delayed"))
    #expect(probe.events.contains("emit:received(\"delayed\")"))
    #expect(probe.events.contains("finish:instrumented-delayed"))
  }

  @Test("Store instrumentation records immediate emissions before reducer reentry")
  func storeInstrumentationImmediateEmissionPrecedesReducerReentry() {
    let probe = InstrumentationProbe()
    let store = Store(
      reducer: EmissionOrderingFeature(probe: probe),
      initialState: .init(),
      instrumentation: .init(
        didEmitAction: { event in
          if case .received(let value) = event.action {
            probe.record("emit:\(value)")
          }
        }
      )
    )

    store.send(.triggerImmediate)

    #expect(probe.events == ["emit:immediate", "reduce:immediate"])
  }

  @Test("Store instrumentation records run emissions before reducer reentry")
  func storeInstrumentationRunEmissionPrecedesReducerReentry() async {
    let probe = InstrumentationProbe()
    let store = Store(
      reducer: EmissionOrderingFeature(probe: probe),
      initialState: .init(),
      instrumentation: .init(
        didEmitAction: { event in
          if case .received(let value) = event.action {
            probe.record("emit:\(value)")
          }
        }
      )
    )

    store.send(.triggerRun)
    await waitUntil {
      probe.events.contains("reduce:run")
    }

    #expect(probe.events == ["emit:run", "reduce:run"])
  }

  @Test(
    "@InnoFlow(phaseManaged: true) auto-applies static phaseMap inside the synthesized reducer"
  )
  func phaseManagedMacroAutoAppliesPhaseMap() {
    let feature = PhaseManagedFeature()
    var state = PhaseManagedFeature.State()

    #expect(state.phase == .idle)

    _ = feature.reduce(into: &state, action: .load)
    #expect(state.phase == .loading)
    #expect(state.errorMessage == nil)

    _ = feature.reduce(into: &state, action: ._loaded("ok"))
    #expect(state.phase == .loaded)
    #expect(state.output == "ok")

    _ = feature.reduce(into: &state, action: ._failed("boom"))
    // The phase map only declares loading -> failed, so a failed action
    // received in the loaded phase is a legal no-op. The body still
    // updates non-phase state.
    #expect(state.phase == .loaded)
    #expect(state.errorMessage == "boom")
  }

  @Test("StoreInstrumentation.signpost preserves runtime behavior")
  func storeInstrumentationSignpostFactory() async {
    let signposter = OSSignposter(subsystem: "InnoFlowTests", category: "StoreInstrumentation")
    let store = Store(
      reducer: AsyncFeature(),
      initialState: .init(),
      instrumentation: .signpost(signposter: signposter)
    )

    store.send(.load)

    let timeoutClock = ContinuousClock()
    let deadline = timeoutClock.now.advanced(by: .seconds(2))
    while timeoutClock.now < deadline {
      if store.value == "Hello, InnoFlow" {
        break
      }
      try? await Task.sleep(for: .milliseconds(20))
    }

    #expect(store.value == "Hello, InnoFlow")
    #expect(store.isLoading == false)
  }

  @Test("StoreInstrumentation.osLog preserves runtime behavior")
  func storeInstrumentationOSLogFactory() async {
    let logger = Logger(subsystem: "InnoFlowTests", category: "StoreInstrumentation")
    let store = Store(
      reducer: AsyncFeature(),
      initialState: .init(),
      instrumentation: .osLog(logger: logger)
    )

    store.send(.load)

    let timeoutClock = ContinuousClock()
    let deadline = timeoutClock.now.advanced(by: .seconds(2))
    while timeoutClock.now < deadline {
      if store.value == "Hello, InnoFlow" {
        break
      }
      try? await Task.sleep(for: .milliseconds(20))
    }

    #expect(store.value == "Hello, InnoFlow")
    #expect(store.isLoading == false)
  }

  @Test("StoreInstrumentation.sink captures unified lifecycle events in order")
  func storeInstrumentationSinkCapturesUnifiedEvents() async {
    let probe = InstrumentationProbe()
    let store = Store(
      reducer: AsyncFeature(),
      initialState: .init(),
      instrumentation: .sink { event in
        switch event {
        case .runStarted:
          probe.record("run-started")
        case .runFinished:
          probe.record("run-finished")
        case .runFailed:
          probe.record("run-failed")
        case .actionEmitted(let actionEvent):
          probe.record("emit:\(actionEvent.action)")
        case .actionDropped:
          probe.record("dropped")
        case .effectsCancelled:
          probe.record("cancelled")
        }
      }
    )

    store.send(.load)
    await waitUntil {
      probe.events.last == "run-finished"
    }

    #expect(probe.events.first == "run-started")
    #expect(probe.events.contains("emit:_loaded(\"Hello, InnoFlow\")"))
    #expect(probe.events.last == "run-finished")
  }

  @Test("StoreInstrumentation.combined fans out events to every sink")
  func storeInstrumentationCombinedFansOut() async {
    let firstProbe = InstrumentationProbe()
    let secondProbe = InstrumentationProbe()
    let store = Store(
      reducer: AsyncFeature(),
      initialState: .init(),
      instrumentation: .combined(
        .sink { event in
          if case .actionEmitted(let actionEvent) = event {
            firstProbe.record("emit:\(actionEvent.action)")
          }
        },
        .sink { event in
          if case .actionEmitted(let actionEvent) = event {
            secondProbe.record("emit:\(actionEvent.action)")
          }
        }
      )
    )

    store.send(.load)
    try? await Task.sleep(for: .milliseconds(80))

    #expect(firstProbe.events == ["emit:_loaded(\"Hello, InnoFlow\")"])
    #expect(secondProbe.events == ["emit:_loaded(\"Hello, InnoFlow\")"])
  }

  @Test("StoreInstrumentation.osLog redaction does not evaluate action descriptions")
  func osLogRedactionDoesNotEvaluateActionDescription() {
    let counter = DescriptionCounter()
    let logger = Logger(subsystem: "InnoFlowTests", category: "storeInstrumentation")
    let instrumentation = StoreInstrumentation<DescriptionCountingAction>.osLog(logger: logger)
    let action = DescriptionCountingAction(counter: counter)

    instrumentation.didEmitAction(
      .init(action: action, cancellationID: Optional<AnyEffectID>.none, sequence: 1)
    )
    instrumentation.didDropAction(
      .init(
        action: action,
        reason: .cancellationBoundary,
        cancellationID: Optional<AnyEffectID>.none,
        sequence: 2
      )
    )

    #expect(counter.count == 0)
  }

  @Test("StoreInstrumentation.signpost redaction does not evaluate action descriptions")
  func signpostRedactionDoesNotEvaluateActionDescription() {
    let counter = DescriptionCounter()
    let signposter = OSSignposter(subsystem: "InnoFlowTests", category: "storeInstrumentation")
    let instrumentation = StoreInstrumentation<DescriptionCountingAction>.signpost(
      signposter: signposter
    )
    let action = DescriptionCountingAction(counter: counter)

    instrumentation.didEmitAction(
      .init(action: action, cancellationID: Optional<AnyEffectID>.none, sequence: 1)
    )
    instrumentation.didDropAction(
      .init(
        action: action,
        reason: .cancellationBoundary,
        cancellationID: Optional<AnyEffectID>.none,
        sequence: 2
      )
    )

    #expect(counter.count == 0)
  }

  @Test("StoreInstrumentation.signpost supports redacted and explicit error payload paths")
  func signpostErrorPayloadOptionEvaluates() {
    let signposter = OSSignposter(subsystem: "InnoFlowTests", category: "storeInstrumentation")
    let redacted = StoreInstrumentation<DescriptionCountingAction>.signpost(signposter: signposter)
    let explicit = StoreInstrumentation<DescriptionCountingAction>.signpost(
      signposter: signposter,
      includeErrorPayload: true
    )
    let redactedToken = UUID()
    let explicitToken = UUID()

    redacted.didStartRun(
      .init(token: redactedToken, cancellationID: Optional<AnyEffectID>.none, sequence: 1)
    )
    redacted.didFailRun(
      .init(
        token: redactedToken,
        cancellationID: Optional<AnyEffectID>.none,
        sequence: 1,
        errorDescription: "sensitive-error",
        errorTypeName: "TestError"
      )
    )
    explicit.didStartRun(
      .init(token: explicitToken, cancellationID: Optional<AnyEffectID>.none, sequence: 2)
    )
    explicit.didFailRun(
      .init(
        token: explicitToken,
        cancellationID: Optional<AnyEffectID>.none,
        sequence: 2,
        errorDescription: "sensitive-error",
        errorTypeName: "TestError"
      )
    )
  }

  @Test("StoreInstrumentation.osLog includeActions evaluates action descriptions")
  func osLogIncludeActionsEvaluatesActionDescription() {
    let counter = DescriptionCounter()
    let logger = Logger(subsystem: "InnoFlowTests", category: "storeInstrumentation")
    let instrumentation = StoreInstrumentation<DescriptionCountingAction>.osLog(
      logger: logger,
      includeActions: true
    )
    let action = DescriptionCountingAction(counter: counter)

    instrumentation.didDropAction(
      .init(
        action: action,
        reason: .cancellationBoundary,
        cancellationID: Optional<AnyEffectID>.none,
        sequence: 1
      )
    )

    #expect(counter.count == 1)
  }

  @Test("Store instrumentation records cancellation and trailing throttle drop events")
  func storeInstrumentationCancellationAndDrop() async {
    let probe = InstrumentationProbe()
    let store = Store(
      reducer: InstrumentationFeature(),
      initialState: .init(),
      instrumentation: .init(
        didEmitAction: { event in
          probe.record("emit:\(event.action)")
        },
        didDropAction: { event in
          probe.record("drop:\(String(describing: event.action)):\(event.reason)")
        },
        didCancelEffects: { event in
          probe.record("cancel:\(event.id?.description ?? "all")")
        }
      )
    )

    store.send(.startDelayed)
    try? await Task.sleep(for: .milliseconds(10))
    await store.cancelEffects(identifiedBy: "instrumented-delayed")
    try? await Task.sleep(for: .milliseconds(80))

    store.send(.trailingThrottle(1))
    for _ in 0..<10 {
      await Task.yield()
    }
    await store.cancelEffects(identifiedBy: "instrumented-throttle")
    try? await Task.sleep(for: .milliseconds(20))

    #expect(store.state.log.isEmpty)
    #expect(probe.events.contains("cancel:instrumented-delayed"))
    #expect(probe.events.contains("cancel:instrumented-throttle"))
    #expect(
      probe.events.contains(where: {
        $0.contains(
          "drop:Optional(InnoFlowTests.InstrumentationFeature.Action.received(\"delayed\")):cancellationBoundary"
        )
          || $0.contains(
            "drop:Optional(InnoFlowTests.InstrumentationFeature.Action.received(\"delayed\")):inactiveToken"
          )
      })
    )
    #expect(
      probe.events.contains(where: {
        $0.contains("drop:nil:throttledOrDebouncedCancellation")
      })
    )
  }

  @Test("Store instrumentation records storeReleased drops from late uncooperative emissions")
  func storeInstrumentationStoreReleasedDrop() async {
    let probe = InstrumentationProbe()
    let gate = LateSendGate()
    var store: Store<StoreReleaseDropFeature>? = Store(
      reducer: StoreReleaseDropFeature(gate: gate),
      initialState: .init(),
      instrumentation: .init(
        didDropAction: { event in
          probe.record("drop:\(String(describing: event.action)):\(event.reason)")
        },
        didCancelEffects: { event in
          probe.record("cancel:\(event.id?.description ?? "all"):\(event.sequence)")
        }
      )
    )

    store?.send(.start)

    for _ in 0..<30 {
      if await gate.isWaiting {
        break
      }
      await Task.yield()
    }

    store = nil
    await gate.open()

    for _ in 0..<60 {
      if probe.events.contains(where: { $0.contains("storeReleased") }) {
        break
      }
      try? await Task.sleep(for: .milliseconds(20))
    }

    #expect(
      probe.events.contains(where: {
        $0.contains(
          "drop:Optional(InnoFlowTests.StoreReleaseDropFeature.Action._completed(\"late-value\")):storeReleased"
        )
      })
    )
    #expect(
      probe.events.contains(where: {
        $0.hasPrefix("cancel:all:")
      })
    )
  }

  @Test("Scoped observer registry tracks refresh passes without changing semantics")
  func scopedObserverRegistryRefreshCount() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    _ = store.scope(state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)

    #expect(store.scopedObserverRefreshCount == 0)

    store.send(.setUnrelated(1))
    #expect(store.scopedObserverRefreshCount == 1)

    store.send(.child(.setStep(3)))
    #expect(store.scopedObserverRefreshCount == 2)
    #expect(store.child.step == 3)
  }

  @Test("EffectRuntime metrics snapshot tracks registration, cancellation, and finish counts")
  func effectRuntimeMetricsSnapshot() async {
    let clock = ManualTestClock()
    let store = Store(
      reducer: RuntimeMetricsFeature(),
      initialState: .init(),
      clock: .manual(clock)
    )

    store.send(.start)
    await drainAsyncWork()

    let afterStart = await store.effectRuntimeMetrics
    #expect(afterStart.preparedRuns == 1)
    #expect(afterStart.attachedRuns == 1)
    #expect(afterStart.finishedRuns == 0)
    #expect(afterStart.cancellations == 0)

    await store.cancelEffects(identifiedBy: "runtime-metrics")
    await drainAsyncWork()

    let afterCancel = await store.effectRuntimeMetrics
    #expect(afterCancel.cancellations == 1)

    await clock.advance(by: .milliseconds(100))
    await drainAsyncWork()

    let afterCancelledFinish = await store.effectRuntimeMetrics
    #expect(afterCancelledFinish.preparedRuns == 1)
    #expect(afterCancelledFinish.attachedRuns == 1)
    #expect(afterCancelledFinish.finishedRuns == 1)
    #expect(store.completed == 0)

    store.send(.start)
    // The second run's Task must reach its `context.sleep(for:)` call and
    // register a sleeper on the ManualTestClock BEFORE we call advance(by:).
    // If advance runs first, it finds no sleeper to wake and the Task stays
    // suspended forever. `drainAsyncWork`'s fixed 128-yield budget is enough
    // on fast hardware but not on saturated CI — poll `sleeperCount` on a
    // wall-clock interval instead.
    for _ in 0..<500 {
      if await clock.sleeperCount >= 1 { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    await clock.advance(by: .milliseconds(100))
    for _ in 0..<250 {
      let metrics = await store.effectRuntimeMetrics
      if metrics.finishedRuns == 2,
        metrics.emissionDecisions >= 1,
        store.completed == 1
      {
        break
      }
      try? await Task.sleep(for: .milliseconds(20))
    }

    // After advance, the effect's sleep resumes on the cooperative executor.
    // Poll the observable completion marker so the check adapts to executor
    // jitter on saturated CI.
    await waitUntil(timeout: .seconds(5)) {
      store.completed == 1
    }

    let afterSuccessfulFinish = await store.effectRuntimeMetrics
    #expect(afterSuccessfulFinish.preparedRuns == 2)
    #expect(afterSuccessfulFinish.attachedRuns == 2)
    #expect(afterSuccessfulFinish.finishedRuns == 2)
    #expect(afterSuccessfulFinish.emissionDecisions >= 1)
    #expect(store.completed == 1)
  }

  @Test(
    "Projection observer stats track selective refresh for key-path, dependency, and closure selections"
  )
  func projectionObserverStatsTrackSelectiveRefresh() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    _ = store.select(\.child)
    _ = store.select(dependingOn: \.child.title) { $0.uppercased() }
    _ = store.select { $0.child.title }

    let initial = store.projectionObserverStats
    #expect(initial.registeredObservers == 3)

    store.send(.setUnrelated(1))
    let afterUnrelated = store.projectionObserverStats
    #expect(afterUnrelated.refreshPassCount == initial.refreshPassCount + 1)
    #expect(afterUnrelated.evaluatedObservers == initial.evaluatedObservers + 1)
    #expect(afterUnrelated.refreshedObservers == initial.refreshedObservers)

    store.send(.child(.setStep(7)))
    let afterChildMutation = store.projectionObserverStats
    #expect(afterChildMutation.refreshPassCount == afterUnrelated.refreshPassCount + 1)
    #expect(afterChildMutation.evaluatedObservers == afterUnrelated.evaluatedObservers + 2)
    #expect(afterChildMutation.refreshedObservers == afterUnrelated.refreshedObservers + 1)

    store.send(.child(.setTitle("Ready")))
    let afterTitleMutation = store.projectionObserverStats
    #expect(afterTitleMutation.refreshPassCount == afterChildMutation.refreshPassCount + 1)
    #expect(afterTitleMutation.evaluatedObservers == afterChildMutation.evaluatedObservers + 3)
    #expect(afterTitleMutation.refreshedObservers == afterChildMutation.refreshedObservers + 3)
  }

  @Test(
    "Projection observer stats dedupe multi-field selections when multiple dependencies change in one action"
  )
  func projectionObserverStatsDedupeMultiFieldSelections() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    _ = store.select(dependingOnAll: \.child.step, \.child.title) { step, title in
      "\(title)-\(step)"
    }

    let initial = store.projectionObserverStats
    #expect(initial.registeredObservers == 1)

    store.send(.child(.setSnapshot(step: 3, title: "Updated", note: "Ready")))

    let afterSnapshotMutation = store.projectionObserverStats
    #expect(afterSnapshotMutation.refreshPassCount == initial.refreshPassCount + 1)
    #expect(afterSnapshotMutation.evaluatedObservers == initial.evaluatedObservers + 1)
    #expect(afterSnapshotMutation.refreshedObservers == initial.refreshedObservers + 1)
  }

  @Test(
    "Projection observer stats dedupe six-field selections and fallback selectors still always refresh"
  )
  func projectionObserverStatsDedupeSixFieldSelections() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    _ = store.select(
      dependingOnAll:
        \.child.step,
      \.child.title,
      \.child.note,
      \.child.priority,
      \.child.isEnabled,
      \.child.version

    ) { step, title, note, priority, isEnabled, version in
      "\(title)-\(step)-\(note)-\(priority)-\(isEnabled)-\(version)"
    }
    _ = store.select {
      "\($0.child.title)-\($0.child.step)-\($0.child.note)-\($0.child.priority)-\($0.child.isEnabled)-\($0.child.version)"
    }

    let initial = store.projectionObserverStats
    #expect(initial.registeredObservers == 2)

    store.send(.setUnrelated(1))

    let afterUnrelated = store.projectionObserverStats
    #expect(afterUnrelated.refreshPassCount == initial.refreshPassCount + 1)
    #expect(afterUnrelated.evaluatedObservers == initial.evaluatedObservers + 1)
    #expect(afterUnrelated.refreshedObservers == initial.refreshedObservers)

    store.send(
      .child(
        .setSelectionProbe(
          step: 3,
          title: "Updated",
          note: "Synced",
          priority: 4,
          isEnabled: false,
          version: 2
        )
      )
    )

    let afterProbeMutation = store.projectionObserverStats
    #expect(afterProbeMutation.refreshPassCount == afterUnrelated.refreshPassCount + 1)
    #expect(afterProbeMutation.evaluatedObservers == afterUnrelated.evaluatedObservers + 2)
    #expect(afterProbeMutation.refreshedObservers == afterUnrelated.refreshedObservers + 2)
  }

  @Test("Scoped projection stats track dependency-annotated and fallback selections")
  func scopedProjectionObserverStatsSelectiveRefresh() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)
    _ = scoped.select(\.step)
    _ = scoped.select(dependingOn: \.title) { $0.uppercased() }
    _ = scoped.select { $0.title }

    let initial = scoped.projectionObserverStats
    #expect(initial.registeredObservers == 3)

    store.send(.setUnrelated(1))
    let afterUnrelated = scoped.projectionObserverStats
    #expect(afterUnrelated.refreshPassCount == initial.refreshPassCount)
    #expect(afterUnrelated.evaluatedObservers == initial.evaluatedObservers)

    store.send(.child(.setStep(4)))
    let afterChildMutation = scoped.projectionObserverStats
    #expect(afterChildMutation.refreshPassCount == initial.refreshPassCount + 1)
    #expect(afterChildMutation.evaluatedObservers == initial.evaluatedObservers + 2)
    #expect(afterChildMutation.refreshedObservers == initial.refreshedObservers + 1)

    store.send(.child(.setTitle("Ready")))
    let afterTitleMutation = scoped.projectionObserverStats
    #expect(afterTitleMutation.refreshPassCount == afterChildMutation.refreshPassCount + 1)
    #expect(afterTitleMutation.evaluatedObservers == afterChildMutation.evaluatedObservers + 2)
    #expect(afterTitleMutation.refreshedObservers == afterChildMutation.refreshedObservers + 2)
  }

  @Test(
    "Projection observer registry compacts untouched dependency buckets on periodic maintenance")
  func projectionObserverRegistryPeriodicCompaction() {
    let registry = ProjectionObserverRegistry<ProjectionObserverSnapshot>(
      compactionDeadObserverThreshold: 99,
      periodicCompactionInterval: 2
    )

    do {
      let doomed = ProjectionObserverTestProbe()
      registry.register(
        doomed,
        registration: .dependency(
          .keyPath(\ProjectionObserverSnapshot.tracked),
          hasChanged: { previous, next in
            previous.tracked != next.tracked
          }
        )
      )
    }

    registry.refresh(
      from: .init(tracked: 0, other: 0),
      to: .init(tracked: 0, other: 1)
    )
    let afterFirstPass = registry.statsSnapshot
    #expect(afterFirstPass.registeredObservers == 1)
    #expect(afterFirstPass.compactionPassCount == 0)

    registry.refresh(
      from: .init(tracked: 0, other: 1),
      to: .init(tracked: 0, other: 2)
    )
    let afterSecondPass = registry.statsSnapshot
    #expect(afterSecondPass.registeredObservers == 0)
    #expect(afterSecondPass.compactionPassCount == 1)
    #expect(afterSecondPass.prunedObservers == 1)
  }

  @Test("Projection observer registry compacts untouched dependency buckets after stale threshold")
  func projectionObserverRegistryThresholdCompaction() {
    let registry = ProjectionObserverRegistry<ProjectionObserverSnapshot>(
      compactionDeadObserverThreshold: 1,
      periodicCompactionInterval: 100
    )

    do {
      let doomedAlways = ProjectionObserverTestProbe()
      registry.register(doomedAlways)

      let doomedDependency = ProjectionObserverTestProbe()
      registry.register(
        doomedDependency,
        registration: .dependency(
          .keyPath(\ProjectionObserverSnapshot.tracked),
          hasChanged: { previous, next in
            previous.tracked != next.tracked
          }
        )
      )
    }

    registry.refresh(
      from: .init(tracked: 0, other: 0),
      to: .init(tracked: 0, other: 1)
    )

    let stats = registry.statsSnapshot
    #expect(stats.registeredObservers == 0)
    #expect(stats.compactionPassCount == 1)
    #expect(stats.prunedObservers == 2)
  }

  @Test("Optional performance benchmarks print baselines when enabled")
  func optionalPerformanceBenchmarks() async {
    guard isPerformanceBenchmarkEnabled else { return }

    struct NoopRunBenchmarkFeature: Reducer {
      struct State: Equatable, Sendable, DefaultInitializable {}
      enum Action: Equatable, Sendable { case start }

      func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
        switch action {
        case .start:
          return .run { _, _ in }
        }
      }
    }

    let runStore = Store(reducer: NoopRunBenchmarkFeature(), initialState: .init())
    let runClock = ContinuousClock()
    let runStart = runClock.now
    for _ in 0..<10_000 {
      runStore.send(.start)
    }
    for _ in 0..<20 {
      await drainAsyncWork()
    }
    let runDuration = runClock.now - runStart
    let runMetrics = await runStore.effectRuntimeMetrics
    print("InnoFlow benchmark: 10_000 no-op runs in \(runDuration), metrics=\(runMetrics)")

    let projectionStore = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    _ = projectionStore.select(\.child)
    let projectionClock = ContinuousClock()
    let projectionStart = projectionClock.now
    for index in 0..<1_000 {
      projectionStore.send(.setUnrelated(index))
    }
    let projectionDuration = projectionClock.now - projectionStart
    print(
      "InnoFlow benchmark: 1_000 projection refresh passes in \(projectionDuration), stats=\(projectionStore.projectionObserverStats)"
    )
  }
}
