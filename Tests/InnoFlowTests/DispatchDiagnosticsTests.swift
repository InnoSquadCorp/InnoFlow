import Foundation
import InnoFlowCore
import InnoFlowTesting
import Testing
import os

@Suite("Dispatch diagnostics")
@MainActor
struct DispatchDiagnosticsTests {
  @Test("root and descendant lifecycle records share one dispatch identity")
  func descendantsShareDispatchIdentity() async {
    let diagnostics = StoreDiagnostics(capacity: 64)
    let store = Store(reducer: DiagnosticChainFeature(), diagnostics: diagnostics)

    let task = store.send(.start)
    await task.finish()

    let snapshot = diagnostics.snapshot()
    let identities = Set(snapshot.records.map(\.dispatchID))
    #expect(identities.count == 1)
    #expect(snapshot.activeDispatches.isEmpty)
    #expect(snapshot.droppedRecordCount == 0)
    #expect(snapshot.records.first?.kind == .submitted)
    #expect(snapshot.records.last?.kind == .terminated)
    #expect(snapshot.records.filter { $0.kind == .runStarted }.count == 2)
    #expect(snapshot.records.filter { $0.kind == .runFinished }.count == 2)
    #expect(snapshot.records.filter { $0.kind == .actionEmitted }.count == 2)
  }

  @Test("parallel root sends receive distinct identities")
  func rootsAreDistinct() async {
    let diagnostics = StoreDiagnostics(capacity: 32)
    let store = Store(reducer: ImmediateDiagnosticFeature(), diagnostics: diagnostics)

    let first = store.send(.record(1))
    let second = store.send(.record(2))
    await first.finish()
    await second.finish()

    let submitted = diagnostics.snapshot().records.filter { $0.kind == .submitted }
    #expect(submitted.count == 2)
    #expect(Set(submitted.map(\.dispatchID)).count == 2)
  }

  @Test("cancellation request remains visible until physical termination")
  func cancellationAndTerminationAreDistinct() async {
    let diagnostics = StoreDiagnostics(capacity: 32)
    let probe = CancellationAwareSleepProbe()
    let store = Store(
      reducer: DiagnosticCancellationFeature(probe: probe),
      diagnostics: diagnostics
    )

    let task = store.send(.start)
    #expect(await probe.started.wait())
    task.cancel()
    #expect(await probe.cancelled.wait())
    await task.finish()

    let records = diagnostics.snapshot().records
    let cancellationIndex = records.first { $0.kind == .cancellationRequested }?.index
    let terminationIndex = records.first { $0.kind == .terminated }?.index
    #expect(cancellationIndex != nil)
    #expect(terminationIndex != nil)
    if let cancellationIndex, let terminationIndex {
      #expect(cancellationIndex < terminationIndex)
    }
  }

  @Test("history is bounded and reports truncation")
  func boundedHistoryReportsDroppedRecords() async {
    let diagnostics = StoreDiagnostics(capacity: 3)
    let store = Store(reducer: ImmediateDiagnosticFeature(), diagnostics: diagnostics)

    for value in 0..<10 {
      await store.send(.record(value)).finish()
    }

    let snapshot = diagnostics.snapshot()
    #expect(snapshot.records.count == 3)
    #expect(snapshot.droppedRecordCount == 17)
    #expect(snapshot.activeDispatches.isEmpty)
  }

  @Test("active snapshots can be bounded independently of history")
  func activeSnapshotLimitIsApplied() async {
    let firstProbe = CancellationAwareSleepProbe()
    let secondProbe = CancellationAwareSleepProbe()
    let diagnostics = StoreDiagnostics(capacity: 0)
    let store = Store(
      reducer: MultiDiagnosticCancellationFeature(probes: [1: firstProbe, 2: secondProbe]),
      diagnostics: diagnostics
    )
    let first = store.send(.start(1))
    let second = store.send(.start(2))
    #expect(await firstProbe.started.wait())
    #expect(await secondProbe.started.wait())

    let snapshot = diagnostics.snapshot(activeLimit: 1)
    #expect(snapshot.records.isEmpty)
    #expect(snapshot.droppedRecordCount > 0)
    #expect(snapshot.activeDispatches.count == 1)

    first.cancel()
    second.cancel()
    await first.finish()
    await second.finish()
  }

  @Test("late dropped actions do not reactivate terminated dispatches")
  func lateDroppedActionsStayOutOfActiveState() async {
    let savedSend = DiagnosticSavedSend()
    let diagnostics = StoreDiagnostics(capacity: 3)
    let store = Store(
      reducer: LateDiagnosticSendFeature(savedSend: savedSend),
      diagnostics: diagnostics
    )

    for _ in 0..<8 {
      await store.send(.start).finish()
      await savedSend.emit()
      await savedSend.clear()
    }

    let snapshot = diagnostics.snapshot()
    #expect(store.state.receivedCount == 0)
    #expect(snapshot.activeDispatches.isEmpty)
    #expect(snapshot.records.count == 3)
    #expect(snapshot.records.contains { $0.kind == .actionDropped(.inactiveToken) })
  }

  @Test("timing recorder correlates a dispatch without storing action payloads")
  func timingRecorderCarriesDispatchIdentity() async {
    let recorder = EffectTimingRecorder()
    let store = Store(
      reducer: DiagnosticChainFeature(),
      instrumentation: recorder.instrumentation()
    )

    await store.send(.start).finish()
    let entries = await recorder.entries()
    let dispatchIDs = Set(entries.compactMap(\.dispatchID))
    #expect(dispatchIDs.count == 1)
    #expect(entries.allSatisfy { $0.actionLabel == nil || !$0.actionLabel!.contains("secret") })
  }

  @Test("the first latest request is not diagnosed as cancelled")
  func firstLatestRequestIsNotCancelled() async {
    let diagnostics = StoreDiagnostics(capacity: 32)
    let probe = DiagnosticUncooperativeProbe()
    let store = Store(
      reducer: DiagnosticScheduledFeature(policy: .latest, probe: probe),
      diagnostics: diagnostics
    )

    let handle = store.send(.start)
    #expect(await probe.started.wait())

    let snapshot = diagnostics.snapshot()
    #expect(snapshot.activeDispatches.count == 1)
    #expect(snapshot.activeDispatches.first?.isCancellationRequested == false)
    #expect(snapshot.records.filter { $0.kind == .cancellationRequested }.isEmpty)

    await probe.release()
    await handle.finish()
  }

  @Test("effect-ID cancellation diagnoses the affected dispatch, not the caller")
  func effectIDCancellationTargetsAffectedDispatch() async {
    let diagnostics = StoreDiagnostics(capacity: 32)
    let probe = DiagnosticUncooperativeProbe()
    let store = Store(
      reducer: DiagnosticScheduledFeature(policy: .dropWhileRunning, probe: probe),
      diagnostics: diagnostics
    )

    let handle = store.send(.start)
    #expect(await probe.started.wait())
    await store.cancelEffects(identifiedBy: "diagnostic-scheduled")
    #expect(await probe.cancelled.wait())

    let snapshot = diagnostics.snapshot()
    #expect(snapshot.activeDispatches.count == 1)
    #expect(snapshot.activeDispatches.first?.isCancellationRequested == true)
    let cancellationRecords = snapshot.records.filter { $0.kind == .cancellationRequested }
    #expect(cancellationRecords.count == 1)
    #expect(cancellationRecords.first?.sequence != nil)
    #expect(cancellationRecords.first?.hasEffectID == true)
    #expect(handle.isCancelled == false)

    await probe.release()
    await handle.finish()
  }

  @Test("cancelling a pending request immediately removes it from the diagnosed queue")
  func pendingCancellationUpdatesQueuedCountWhileSiblingLives() async {
    let diagnostics = StoreDiagnostics(capacity: 64)
    let firstProbe = DiagnosticUncooperativeProbe()
    let siblingProbe = DiagnosticUncooperativeProbe()
    let queuedProbe = DiagnosticUncooperativeProbe()
    let store = Store(
      reducer: DiagnosticPendingCancellationFeature(
        firstProbe: firstProbe,
        siblingProbe: siblingProbe,
        queuedProbe: queuedProbe
      ),
      diagnostics: diagnostics
    )

    let first = store.send(.startFirst)
    #expect(await firstProbe.started.wait())
    let combined = store.send(.startQueuedAndSibling)
    #expect(await siblingProbe.started.wait())

    let submitted = diagnostics.snapshot().records.filter { $0.kind == .submitted }
    #expect(submitted.count == 2)
    let combinedDispatchID = submitted[1].dispatchID
    #expect(
      diagnostics.snapshot().activeDispatches.first {
        $0.dispatchID == combinedDispatchID
      }?.queuedRunCount == 1
    )

    await store.cancelEffects(identifiedBy: "diagnostic-pending-owner")
    await firstProbe.release()
    await first.finish()

    let activeCombined = diagnostics.snapshot().activeDispatches.first {
      $0.dispatchID == combinedDispatchID
    }
    #expect(activeCombined?.queuedRunCount == 0)
    #expect(activeCombined?.activeRunCount == 1)
    #expect(queuedProbe.hasStarted == false)

    await siblingProbe.release()
    await combined.finish()
  }

  @Test("a sibling run cannot consume another scheduled request's queue token")
  func siblingStartPreservesExactQueuedRequestCount() async {
    let diagnostics = StoreDiagnostics(capacity: 64)
    let firstProbe = DiagnosticUncooperativeProbe()
    let siblingProbe = DiagnosticUncooperativeProbe()
    let queuedProbe = DiagnosticUncooperativeProbe()
    let store = Store(
      reducer: DiagnosticSiblingAdmissionFeature(
        firstProbe: firstProbe,
        siblingProbe: siblingProbe,
        queuedProbe: queuedProbe
      ),
      diagnostics: diagnostics
    )

    let first = store.send(.occupy)
    #expect(await firstProbe.started.wait())
    let combined = store.send(.startQueuedAndSibling)
    #expect(await siblingProbe.started.wait())

    let submitted = diagnostics.snapshot().records.filter { $0.kind == .submitted }
    #expect(submitted.count == 2)
    let combinedDispatchID = submitted[1].dispatchID
    let blockedSnapshot = diagnostics.snapshot().activeDispatches.first {
      $0.dispatchID == combinedDispatchID
    }
    #expect(blockedSnapshot?.queuedRunCount == 1)
    #expect(blockedSnapshot?.activeRunCount == 1)
    #expect(queuedProbe.hasStarted == false)

    await firstProbe.release()
    #expect(await queuedProbe.started.wait())
    await first.finish()

    let startedSnapshot = diagnostics.snapshot().activeDispatches.first {
      $0.dispatchID == combinedDispatchID
    }
    #expect(startedSnapshot?.queuedRunCount == 0)

    await queuedProbe.release()
    await siblingProbe.release()
    await combined.finish()
  }

  @Test("queued-token accounting remains finite and idempotent")
  func queuedTokenAccountingReturnsToBaselineAfterRepeatedLifecycle() {
    let diagnostics = StoreDiagnostics(capacity: 1)

    for index in 0..<1_000 {
      let dispatchID = DispatchID()
      let scheduledToken = UUID()
      diagnostics.recordSubmitted(dispatchID)
      diagnostics.recordAdmission(
        .queued(position: 1),
        dispatchID: dispatchID,
        sequence: UInt64(index),
        scheduledToken: scheduledToken
      )
      if index.isMultiple(of: 2) {
        diagnostics.recordAdmission(
          .started,
          dispatchID: dispatchID,
          sequence: UInt64(index),
          scheduledToken: scheduledToken
        )
      } else {
        diagnostics.recordQueuedRunRemoved(
          dispatchID: dispatchID,
          sequence: UInt64(index),
          scheduledToken: scheduledToken
        )
        diagnostics.recordQueuedRunRemoved(
          dispatchID: dispatchID,
          sequence: UInt64(index),
          scheduledToken: scheduledToken
        )
      }
      #expect(diagnostics.snapshot().activeDispatches.first?.queuedRunCount == 0)
      diagnostics.recordTerminated(dispatchID)
      diagnostics.recordQueuedRunRemoved(
        dispatchID: dispatchID,
        sequence: UInt64(index),
        scheduledToken: scheduledToken
      )
    }

    let snapshot = diagnostics.snapshot()
    #expect(snapshot.activeDispatches.isEmpty)
    #expect(snapshot.records.count == 1)
    #expect(snapshot.records.last?.kind == .terminated)
    #expect(snapshot.droppedRecordCount > 0)
  }
}

private struct DiagnosticChainFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var value = 0
    init() {}
  }

  enum Action: Equatable, Sendable {
    case start
    case child
    case finished
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start:
      return .run { send in await send(.child) }
    case .child:
      return .run { send in await send(.finished) }
    case .finished:
      state.value = 1
      return .none
    }
  }
}

private struct ImmediateDiagnosticFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var values: [Int] = []
    init() {}
  }
  enum Action: Equatable, Sendable { case record(Int) }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    guard case .record(let value) = action else { return .none }
    state.values.append(value)
    return .none
  }
}

private struct DiagnosticCancellationFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {}
  enum Action: Equatable, Sendable { case start }
  let probe: CancellationAwareSleepProbe

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    .run { _ in try? await probe.sleep() }
  }
}

private struct MultiDiagnosticCancellationFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {}
  enum Action: Equatable, Sendable { case start(Int) }
  let probes: [Int: CancellationAwareSleepProbe]

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    guard case .start(let value) = action, let probe = probes[value] else { return .none }
    return .run { _ in try? await probe.sleep() }
  }
}

private struct DiagnosticScheduledFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {}

  enum Action: Equatable, Sendable {
    case start
  }

  let policy: EffectExecutionPolicy
  let probe: DiagnosticUncooperativeProbe

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    .run(id: "diagnostic-scheduled", policy: policy) { _, _ in
      await probe.run()
    }
  }
}

private struct DiagnosticPendingCancellationFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {}

  enum Action: Equatable, Sendable {
    case startFirst
    case startQueuedAndSibling
  }

  let firstProbe: DiagnosticUncooperativeProbe
  let siblingProbe: DiagnosticUncooperativeProbe
  let queuedProbe: DiagnosticUncooperativeProbe
  private let lane: StaticEffectID = "diagnostic-pending-lane"
  private let owner: StaticEffectID = "diagnostic-pending-owner"

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .startFirst:
      return .run(id: lane, policy: .serial(maxPending: 1)) { _, _ in
        await firstProbe.run()
      }

    case .startQueuedAndSibling:
      return .merge(
        .run(id: lane, policy: .serial(maxPending: 1)) { _, _ in
          await queuedProbe.run()
        }
        .cancellable(owner),
        .run { _ in await siblingProbe.run() }
      )
    }
  }
}

private struct DiagnosticSiblingAdmissionFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {}

  enum Action: Equatable, Sendable {
    case occupy
    case startQueuedAndSibling
    case admitted(EffectAdmission)
  }

  let firstProbe: DiagnosticUncooperativeProbe
  let siblingProbe: DiagnosticUncooperativeProbe
  let queuedProbe: DiagnosticUncooperativeProbe
  private let lane: StaticEffectID = "diagnostic-sibling-lane"

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .occupy:
      return .run(id: lane, policy: .serial(maxPending: 1)) { _, _ in
        await firstProbe.run()
      }

    case .startQueuedAndSibling:
      return .run(
        id: lane,
        policy: .serial(maxPending: 1),
        onAdmission: Action.admitted
      ) { _, _ in
        await queuedProbe.run()
      }

    case .admitted(.queued):
      return .run { _ in await siblingProbe.run() }

    case .admitted:
      return .none
    }
  }
}

private final class DiagnosticUncooperativeProbe: Sendable {
  let started = AsyncTestSignal()
  let cancelled = AsyncTestSignal()
  private let releaseGate = RunStartGate()
  private let startedState = OSAllocatedUnfairLock(initialState: false)

  var hasStarted: Bool { startedState.withLock { $0 } }

  func run() async {
    startedState.withLock { $0 = true }
    started.signal()
    await withTaskCancellationHandler {
      await releaseGate.wait()
    } onCancel: {
      cancelled.signal()
    }
  }

  func release() async {
    await releaseGate.open()
  }
}

private actor DiagnosticSavedSend {
  private var send: Send<LateDiagnosticSendFeature.Action>?

  func save(_ send: Send<LateDiagnosticSendFeature.Action>) {
    self.send = send
  }

  func emit() async {
    await send?(.late)
  }

  func clear() {
    send = nil
  }
}

private struct LateDiagnosticSendFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var receivedCount = 0
    init() {}
  }

  enum Action: Equatable, Sendable {
    case start
    case late
  }

  let savedSend: DiagnosticSavedSend

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start:
      return .run { send, _ in
        await savedSend.save(send)
      }
    case .late:
      state.receivedCount += 1
      return .none
    }
  }
}
