import Foundation
import InnoFlowCore
import InnoFlowTesting
import Testing

private actor AdmissionGate {
  private var started = false
  private var opened = false
  private var entries: [CheckedContinuation<Void, Never>] = []
  private var exits: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    started = true
    for entry in entries { entry.resume() }
    entries.removeAll()
    guard !opened else { return }
    await withCheckedContinuation { exits.append($0) }
  }
  func waitUntilEntered() async {
    guard !started else { return }
    await withCheckedContinuation { entries.append($0) }
  }
  func open() {
    opened = true
    for exit in exits { exit.resume() }
    exits.removeAll()
  }
}
private struct AdmissionState: Equatable, Sendable { var values: [Int] = [] }
private enum AdmissionAction: Equatable, Sendable {
  case old, newer
  case done(Int)
}
private func admissionReducer(old: AdmissionGate, newer: AdmissionGate)
  -> some Reducer<AdmissionState, AdmissionAction, Never>
{
  Reduce<AdmissionState, AdmissionAction, Never> { state, action in
    switch action {
    case .old:
      return .concatenate(
        .run { _ in await old.wait() },
        .run(id: EffectID("lane"), policy: .latest) { send, _ in await send(.done(1)) }
      )
    case .newer:
      return .run(id: EffectID("lane"), policy: .latest) { send, _ in
        await newer.wait()
        await send(.done(2))
      }
    case .done(let value):
      state.values.append(value)
      return .none
    }
  }
}

@MainActor
@Suite("Scheduler admission consistency")
struct SchedulerAdmissionConsistencyTests {
  @Test(arguments: [false, true], [false, true])
  func delayedOldLatestCannotDisplaceNewer(preCancel: Bool, useTestStore: Bool) async {
    let oldGate = AdmissionGate()
    let newGate = AdmissionGate()
    if useTestStore {
      let store = TestStore(
        reducer: admissionReducer(old: oldGate, newer: newGate), initialState: .init())
      let old = await store.send(.old)
      await oldGate.waitUntilEntered()
      if preCancel { await store.cancelEffects(identifiedBy: EffectID("lane")) }
      let newer = await store.send(.newer)
      await newGate.waitUntilEntered()
      await oldGate.open()
      await old.finish()
      await newGate.open()
      await store.receive(.done(2)) { $0.values = [2] }
      await newer.finish()
      await store.finish()
    } else {
      let store = Store(
        reducer: admissionReducer(old: oldGate, newer: newGate), initialState: .init())
      let old = store.send(.old)
      await oldGate.waitUntilEntered()
      if preCancel { await store.cancelEffects(identifiedBy: EffectID("lane")) }
      let newer = store.send(.newer)
      await newGate.waitUntilEntered()
      await oldGate.open()
      await old.finish()
      await newGate.open()
      await newer.finish()
      #expect(store.state.values == [2])
    }
  }

  @Test func cancelledRequestDoesNotReserveSerialCapacity() async {
    let scheduler = EffectRunScheduler()
    let tracker = FlowTaskTracker()
    let activity = tracker.beginActivity()
    tracker.cancel()
    let context = EffectExecutionContext.unmanaged(flowTaskTracker: tracker)
    var lifecycle: [EffectAdmission] = []
    let plan = await scheduler.admit(
      id: AnyEffectID(EffectID("lane")), policy: .serial(maxPending: 0),
      cancellationIDs: [], sequence: 1, dispatchID: tracker.dispatchID,
      onCancellation: { _, _ in }, onStart: { _ in }, onPendingExit: { _ in },
      context: context, onAdmissionLifecycle: { _, admission in lifecycle.append(admission) }
    )
    guard case .terminal(.cancelledBeforeStart) = plan else {
      Issue.record("Pre-cancelled admission must terminate before reserving a lane")
      tracker.endActivity(activity)
      scheduler.cancelAll()
      return
    }
    #expect(scheduler.activeRequestCount == 0)
    #expect(lifecycle == [.cancelledBeforeStart])
    tracker.endActivity(activity)
  }

  @Test func olderSequenceCannotReplaceLiveLatestLane() async {
    let scheduler = EffectRunScheduler()
    let id = AnyEffectID(EffectID("lane"))
    var olderLifecycle: [EffectAdmission] = []
    let newest = await scheduler.admit(
      id: id, policy: .latest, cancellationIDs: [], sequence: 2, dispatchID: nil,
      onCancellation: { _, _ in }, onStart: { _ in }, onPendingExit: { _ in }
    )
    let older = await scheduler.admit(
      id: id, policy: .latest, cancellationIDs: [], sequence: 1, dispatchID: nil,
      onCancellation: { _, _ in }, onStart: { _ in }, onPendingExit: { _ in },
      onAdmissionLifecycle: { _, admission in olderLifecycle.append(admission) }
    )
    if case .accepted(let ticket) = newest {
      #expect(!ticket.cancellationState.isCancelled)
    } else {
      Issue.record("First latest request must be admitted")
    }
    if case .terminal(.superseded) = older {
    } else {
      Issue.record("Older sequence must be superseded")
    }
    #expect(olderLifecycle == [.superseded])
    #expect(scheduler.activeRequestCount == 1)
    scheduler.cancelAll()
  }

  @Test func serialPromotionWaitsForAttachmentAndPublishesStartedOnce() async {
    let scheduler = EffectRunScheduler()
    let id = AnyEffectID(EffectID("lane"))
    var secondLifecycle: [EffectAdmission] = []
    var starts = 0
    let first = await scheduler.admit(
      id: id, policy: .serial(maxPending: 1), cancellationIDs: [], sequence: 1, dispatchID: nil,
      onCancellation: { _, _ in }, onStart: { _ in }, onPendingExit: { _ in }
    )
    let second = await scheduler.admit(
      id: id, policy: .serial(maxPending: 1), cancellationIDs: [], sequence: 2, dispatchID: nil,
      onCancellation: { _, _ in }, onStart: { _ in starts += 1 }, onPendingExit: { _ in },
      onAdmissionLifecycle: { _, admission in secondLifecycle.append(admission) }
    )
    guard case .accepted(let firstTicket) = first, case .accepted(let secondTicket) = second else {
      Issue.record("Both serial reservations must be admitted")
      scheduler.cancelAll()
      return
    }
    await scheduler.finish(firstTicket.token)
    #expect(starts == 0)
    #expect(secondLifecycle == [.queued(position: 1)])
    let task = Task {}
    #expect(await scheduler.attach(task, to: secondTicket))
    #expect(starts == 1)
    #expect(secondLifecycle == [.queued(position: 1), .started])
    await scheduler.finish(secondTicket.token)
    await scheduler.finish(secondTicket.token)
    #expect(scheduler.activeRequestCount == 0)
  }

  @Test func latestSupersessionUsesDisplacedRequestsOwnCallbacks() async {
    let scheduler = EffectRunScheduler()
    let id = AnyEffectID(EffectID("lane"))
    var firstLifecycle: [EffectAdmission] = []
    var secondLifecycle: [EffectAdmission] = []
    var firstCauses: [EffectRunCancellationCause] = []
    var secondCauses: [EffectRunCancellationCause] = []
    _ = await scheduler.admit(
      id: id, policy: .latest, cancellationIDs: [], sequence: 1, dispatchID: nil,
      onCancellation: { _, _ in }, onStart: { _ in }, onPendingExit: { _ in },
      onAdmissionLifecycle: { _, value in firstLifecycle.append(value) },
      onCancellationEvent: { firstCauses.append($0) }
    )
    _ = await scheduler.admit(
      id: id, policy: .latest, cancellationIDs: [], sequence: 2, dispatchID: nil,
      onCancellation: { _, _ in }, onStart: { _ in }, onPendingExit: { _ in },
      onAdmissionLifecycle: { _, value in secondLifecycle.append(value) },
      onCancellationEvent: { secondCauses.append($0) }
    )
    #expect(firstLifecycle == [.superseded])
    #expect(firstCauses == [.superseded])
    #expect(secondLifecycle.isEmpty)
    #expect(secondCauses.isEmpty)
    scheduler.cancelAll()
    #expect(secondLifecycle == [.cancelledBeforeStart])
    #expect(secondCauses == [.explicit])
    scheduler.cancelAll()
    #expect(secondLifecycle.count == 1)
  }
}

extension SchedulerAdmissionConsistencyTests {
  @Test func pendingCancellationReleasesCapacityAndPublishesTerminalOnce() async {
    let scheduler = EffectRunScheduler()
    let id = AnyEffectID(EffectID("lane"))
    var events: [EffectAdmission] = []
    var causes: [EffectRunCancellationCause] = []
    let first = await scheduler.admit(
      id: id, policy: .serial(maxPending: 1), cancellationIDs: [], sequence: 1, dispatchID: nil,
      onCancellation: { _, _ in }, onStart: { _ in }, onPendingExit: { _ in }
    )
    let second = await scheduler.admit(
      id: id, policy: .serial(maxPending: 1), cancellationIDs: [], sequence: 2, dispatchID: nil,
      onCancellation: { _, _ in }, onStart: { _ in }, onPendingExit: { _ in },
      onAdmissionLifecycle: { _, value in events.append(value) },
      onCancellationEvent: { causes.append($0) }
    )
    guard case .accepted(let firstTicket) = first, case .accepted(let secondTicket) = second else {
      Issue.record("Both reservations must be admitted")
      scheduler.cancelAll()
      return
    }
    scheduler.cancel(token: secondTicket.token)
    scheduler.cancel(token: secondTicket.token)
    #expect(events == [.queued(position: 1), .cancelledBeforeStart])
    #expect(causes == [.explicit])
    #expect(scheduler.activeRequestCount == 1)
    let third = await scheduler.admit(
      id: id, policy: .serial(maxPending: 1), cancellationIDs: [], sequence: 3, dispatchID: nil,
      onCancellation: { _, _ in }, onStart: { _ in }, onPendingExit: { _ in }
    )
    guard case .accepted(let thirdTicket) = third else {
      Issue.record("Cancelled pending reservation must return capacity immediately")
      scheduler.cancelAll()
      return
    }
    #expect(thirdTicket.admission == .queued(position: 1))
    await scheduler.finish(firstTicket.token)
    await scheduler.finish(secondTicket.token)
    #expect(await scheduler.attach(Task {}, to: thirdTicket))
    await scheduler.finish(thirdTicket.token)
    #expect(scheduler.activeRequestCount == 0)
  }
}

extension SchedulerAdmissionConsistencyTests {
  @Test func cancellationBeforeAttachmentDoesNotAnnounceStart() async {
    let scheduler = EffectRunScheduler()
    var admissions: [EffectAdmission] = []
    let plan = await scheduler.admit(
      id: AnyEffectID(EffectID("lane")), policy: .dropWhileRunning,
      cancellationIDs: [], sequence: 1, dispatchID: nil,
      onCancellation: { _, _ in }, onStart: { _ in Issue.record("Cancelled reservation started") },
      onPendingExit: { _ in }, onAdmissionLifecycle: { _, value in admissions.append(value) }
    )
    guard case .accepted(let ticket) = plan else {
      Issue.record("Admission failed")
      return
    }
    let gate = AdmissionGate()
    let task = Task { await gate.wait() }
    await gate.waitUntilEntered()
    task.cancel()
    #expect(await scheduler.attach(task, to: ticket) == false)
    #expect(admissions == [.cancelledBeforeStart])
    #expect(ticket.cancellationState.isCancelled)
    await gate.open()
    await task.value
    await scheduler.finish(ticket.token)
    #expect(scheduler.activeRequestCount == 0)
  }
}
