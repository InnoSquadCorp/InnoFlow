import Foundation
import InnoFlowCore
import Testing

private actor LaneSnapshotGate {
  private var entered = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    entered = true
    for waiter in entryWaiters { waiter.resume() }
    entryWaiters.removeAll()
    await withCheckedContinuation { waiters.append($0) }
  }
  func waitUntilEntered() async {
    guard !entered else { return }
    await withCheckedContinuation { entryWaiters.append($0) }
  }
  func open() {
    for waiter in waiters { waiter.resume() }
    waiters.removeAll()
  }
}

@MainActor
@Suite("Payload-free run lane snapshots")
struct RunLaneSnapshotConsistencyTests {
  @Test func snapshotContainsOnlyOpaqueIdentityAndAdmissionMetadata() async {
    let scheduler = EffectRunScheduler()
    let secretID = AnyEffectID(EffectID("private-customer-42"))
    let first = await scheduler.admit(
      id: secretID, policy: .serial(maxPending: 2), cancellationIDs: [], sequence: 1,
      dispatchID: nil, onCancellation: { _, _ in }, onStart: { _ in }, onPendingExit: { _ in }
    )
    let second = await scheduler.admit(
      id: secretID, policy: .serial(maxPending: 2), cancellationIDs: [], sequence: 2,
      dispatchID: nil, onCancellation: { _, _ in }, onStart: { _ in }, onPendingExit: { _ in }
    )
    guard case .accepted(let a) = first, case .accepted(let b) = second else {
      Issue.record("Expected serial reservations")
      scheduler.cancelAll()
      return
    }
    let before = scheduler.snapshots(limit: 32)
    #expect(before.count == 1)
    #expect(before.first?.policy == .serial(maxPending: 2))
    #expect(before.first?.isStartAdmitted == false)
    #expect(before.first?.pendingRequestCount == 1)
    #expect(!String(reflecting: before).contains("private-customer-42"))
    #expect(scheduler.snapshots(limit: 0).isEmpty)
    #expect(scheduler.snapshots(limit: -1).isEmpty)
    _ = await scheduler.attach(Task {}, to: a)
    #expect(scheduler.snapshots(limit: 1).first?.isStartAdmitted == true)
    await scheduler.finish(a.token)
    #expect(scheduler.snapshots(limit: 1).first?.id == before.first?.id)
    #expect(scheduler.snapshots(limit: 1).first?.pendingRequestCount == 0)
    #expect(scheduler.snapshots(limit: 1).first?.isStartAdmitted == false)
    await scheduler.finish(b.token)
    #expect(scheduler.snapshots(limit: 32).isEmpty)
  }

  @Test func latestReplacementKeepsLiveLaneIdentityAndRetiredFinishCannotRemoveIt() async {
    let scheduler = EffectRunScheduler()
    let id = AnyEffectID(EffectID("lane"))
    let first = await scheduler.admit(
      id: id, policy: .latest, cancellationIDs: [], sequence: 1, dispatchID: nil,
      onCancellation: { _, _ in }, onStart: { _ in }, onPendingExit: { _ in }
    )
    let originalID = scheduler.snapshots(limit: 1).first?.id
    let second = await scheduler.admit(
      id: id, policy: .latest, cancellationIDs: [], sequence: 2, dispatchID: nil,
      onCancellation: { _, _ in }, onStart: { _ in }, onPendingExit: { _ in }
    )
    guard case .accepted(let a) = first, case .accepted(let b) = second else {
      Issue.record("Expected latest reservations")
      scheduler.cancelAll()
      return
    }
    #expect(scheduler.snapshots(limit: 1).first?.id == originalID)
    await scheduler.finish(a.token)
    #expect(scheduler.snapshots(limit: 1).first?.id == originalID)
    await scheduler.finish(b.token)
    #expect(scheduler.snapshots(limit: 1).isEmpty)
    _ = await scheduler.admit(
      id: id, policy: .latest, cancellationIDs: [], sequence: 3, dispatchID: nil,
      onCancellation: { _, _ in }, onStart: { _ in }, onPendingExit: { _ in }
    )
    #expect(scheduler.snapshots(limit: 1).first?.id != originalID)
    scheduler.cancelAll()
  }

  @Test(arguments: [false, true])
  func storeSnapshotsReflectPhysicalSlotRetentionAndDoNotRetainStore(cancelDispatch: Bool) async {
    let gate = LaneSnapshotGate()
    let reducer = Reduce<Int, Bool, Never> { _, action in
      guard action else { return .none }
      return .run(id: EffectID("private-lane"), policy: .dropWhileRunning) { _, _ in
        await gate.wait()
      }
    }
    var store = Optional(Store(reducer: reducer, initialState: 0))
    let provider: @MainActor () -> [EffectRunLaneSnapshot] = { [weak store] in
      store?.runLaneSnapshots(limit: 32) ?? []
    }
    let task = store!.send(true)
    await gate.waitUntilEntered()
    #expect(provider().first?.isStartAdmitted == true)
    if cancelDispatch {
      task.cancel()
    } else {
      await store!.cancelEffects(identifiedBy: EffectID("private-lane"))
    }
    #expect(provider().first?.isCancellationRequested == true)
    #expect(!task.isFinished)
    await gate.open()
    await task.finish()
    #expect(provider().isEmpty)
    store = nil
    #expect(provider().isEmpty)
  }

  @Test func identicalIDsAcrossStoresHaveDifferentOpaqueLaneIDs() async {
    let gates = [LaneSnapshotGate(), LaneSnapshotGate()]
    func reducer(_ index: Int) -> some Reducer<Int, Bool, Never> {
      Reduce<Int, Bool, Never> { _, _ in
        .run(id: EffectID("same"), policy: .latest) { _, _ in await gates[index].wait() }
      }
    }
    let first = Store(reducer: reducer(0), initialState: 0)
    let second = Store(reducer: reducer(1), initialState: 0)
    let a = first.send(true)
    let b = second.send(true)
    await gates[0].waitUntilEntered()
    await gates[1].waitUntilEntered()
    #expect(first.runLaneSnapshots().first?.id != second.runLaneSnapshots().first?.id)
    #expect(first.runLaneSnapshots(limit: 0).isEmpty)
    #expect(second.runLaneSnapshots(limit: -3).isEmpty)
    await gates[0].open()
    await gates[1].open()
    await a.finish()
    await b.finish()
  }
}
