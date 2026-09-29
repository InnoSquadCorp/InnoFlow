import Foundation
import InnoFlowCore
import InnoFlowTesting
import Testing

@Suite("Effect run admission")
@MainActor
struct EffectRunSchedulerTests {
  @Test("serial policy preserves admission order and dispatch finish")
  func serialPreservesOrder() async {
    let probe = ScheduledRunProbe()
    let store = Store(
      reducer: SchedulingFeature(policy: .serial(maxPending: 2), probe: probe)
    )

    let first = store.send(.request(1))
    await probe.waitUntilStarted(count: 1)
    let second = store.send(.request(2))
    let third = store.send(.request(3))

    await probe.release(1)
    await probe.waitUntilStarted(count: 2)
    await probe.release(2)
    await probe.waitUntilStarted(count: 3)
    await probe.release(3)

    await first.finish()
    await second.finish()
    await third.finish()

    #expect(await probe.startedValues() == [1, 2, 3])
    #expect(store.state.completed == [1, 2, 3])
    #expect(
      store.state.admissions == [
        .init(request: 1, admission: .started),
        .init(request: 2, admission: .queued(position: 1)),
        .init(request: 3, admission: .queued(position: 2)),
        .init(request: 2, admission: .started),
        .init(request: 3, admission: .started),
      ]
    )
  }

  @Test("drop policy reports busy without executing the rejected operation")
  func dropWhileRunningRejectsBusyRequest() async {
    let probe = ScheduledRunProbe()
    let store = Store(
      reducer: SchedulingFeature(policy: .dropWhileRunning, probe: probe)
    )

    let first = store.send(.request(1))
    await probe.waitUntilStarted(count: 1)
    let rejected = store.send(.request(2))
    await rejected.finish()

    #expect(await probe.startedValues() == [1])
    #expect(store.state.admissions.contains(.init(request: 2, admission: .rejected(.busy))))

    await probe.release(1)
    await first.finish()
    #expect(store.state.completed == [1])
  }

  @Test("serial policy rejects beyond its bounded pending capacity")
  func serialRejectsQueueOverflow() async {
    let probe = ScheduledRunProbe()
    let store = Store(
      reducer: SchedulingFeature(policy: .serial(maxPending: 1), probe: probe)
    )

    let first = store.send(.request(1))
    await probe.waitUntilStarted(count: 1)
    let second = store.send(.request(2))
    let rejected = store.send(.request(3))
    await rejected.finish()

    #expect(
      store.state.admissions.contains(
        .init(request: 3, admission: .rejected(.queueFull(maxPending: 1)))
      )
    )

    await probe.release(1)
    await probe.waitUntilStarted(count: 2)
    await probe.release(2)
    await first.finish()
    await second.finish()
    #expect(await probe.startedValues() == [1, 2])
  }

  @Test("negative serial capacity is reported without trapping")
  func serialRejectsInvalidCapacity() async {
    let probe = ScheduledRunProbe()
    let store = Store(
      reducer: SchedulingFeature(policy: .serial(maxPending: -1), probe: probe)
    )

    let rejected = store.send(.request(1))
    await rejected.finish()

    #expect(
      store.state.admissions == [
        .init(request: 1, admission: .rejected(.invalidCapacity(-1)))
      ]
    )
    #expect(await probe.startedValues().isEmpty)
  }

  @Test("serial cancellation waits for physical termination before advancing")
  func serialCancellationDoesNotOverlapUncooperativeRun() async {
    let probe = ScheduledRunProbe()
    let store = Store(
      reducer: SchedulingFeature(
        policy: .serial(maxPending: 1),
        probe: probe,
        checksCancellationBeforeCompletion: false
      )
    )

    let first = store.send(.request(1))
    await probe.waitUntilStarted(count: 1)
    let second = store.send(.request(2))

    first.cancel()
    await probe.waitUntilCancelled(1)
    #expect(await probe.startedValues() == [1])

    await probe.release(1)
    await probe.waitUntilStarted(count: 2)
    await probe.release(2)
    await first.finish()
    await second.finish()

    #expect(await probe.startedValues() == [1, 2])
    #expect(store.state.completed == [2])
  }

  @Test("serial policy advances after a run reports failure")
  func serialAdvancesAfterReportedFailure() async {
    let probe = ScheduledRunProbe()
    let store = Store(
      reducer: SchedulingFeature(
        policy: .serial(maxPending: 1),
        probe: probe,
        failingValues: [1]
      )
    )

    let first = store.send(.request(1))
    await probe.waitUntilStarted(count: 1)
    let second = store.send(.request(2))

    await probe.release(1)
    await probe.waitUntilStarted(count: 2)
    await probe.release(2)
    await first.finish()
    await second.finish()

    #expect(await probe.startedValues() == [1, 2])
    #expect(store.state.completed == [2])
  }

  @Test("live lane rejects a conflicting policy")
  func conflictingPolicyIsRejected() async {
    let probe = ScheduledRunProbe()
    let store = Store(reducer: PerRequestSchedulingFeature(probe: probe))

    let first = store.send(.request(1, .serial(maxPending: 1)))
    await probe.waitUntilStarted(count: 1)
    let conflicting = store.send(.request(2, .dropWhileRunning))
    await conflicting.finish()

    #expect(
      store.state.admissions.contains(
        .init(request: 2, admission: .rejected(.conflictingPolicy))
      )
    )
    #expect(await probe.startedValues() == [1])

    await probe.release(1)
    await first.finish()
  }

  @Test("identical IDs in distinct Stores do not share admission state")
  func storesOwnIndependentLanes() async {
    let firstProbe = ScheduledRunProbe()
    let secondProbe = ScheduledRunProbe()
    let firstStore = Store(
      reducer: SchedulingFeature(policy: .dropWhileRunning, probe: firstProbe)
    )
    let secondStore = Store(
      reducer: SchedulingFeature(policy: .dropWhileRunning, probe: secondProbe)
    )

    let first = firstStore.send(.request(1))
    let second = secondStore.send(.request(2))
    await firstProbe.waitUntilStarted(count: 1)
    await secondProbe.waitUntilStarted(count: 1)

    #expect(await firstProbe.startedValues() == [1])
    #expect(await secondProbe.startedValues() == [2])

    await firstProbe.release(1)
    await secondProbe.release(2)
    await first.finish()
    await second.finish()
  }

  @Test("distinct typed ID values in one Store run independently")
  func oneStoreOwnsIndependentLanes() async {
    let probe = ScheduledRunProbe()
    let store = Store(reducer: PerLaneSchedulingFeature(probe: probe))

    let first = store.send(.request(value: 1, lane: 10))
    let second = store.send(.request(value: 2, lane: 20))
    await probe.waitUntilStarted(count: 2)

    #expect(Set(await probe.startedValues()) == [1, 2])

    await probe.release(1)
    await probe.release(2)
    await first.finish()
    await second.finish()
  }

  @Test("queued dispatch cancellation removes only that request")
  func queuedDispatchCancellationRemovesRequest() async {
    let probe = ScheduledRunProbe()
    let store = Store(
      reducer: SchedulingFeature(policy: .serial(maxPending: 2), probe: probe)
    )

    let first = store.send(.request(1))
    await probe.waitUntilStarted(count: 1)
    let cancelled = store.send(.request(2))
    cancelled.cancel()
    await cancelled.finish()

    await probe.release(1)
    await first.finish()

    #expect(cancelled.isCancelled)
    #expect(await probe.startedValues() == [1])
    #expect(store.state.completed == [1])
  }

  @Test("Store inherited cancellation removes a queued scheduled run immediately")
  func storeInheritedCancellationReturnsPendingCapacity() async {
    let probe = ScheduledRunProbe()
    let store = Store(reducer: InheritedCancellationFeature(probe: probe))

    let first = store.send(.request(1))
    await probe.waitUntilStarted(count: 1)
    let cancelled = store.send(.request(2))
    #expect(
      await waitUntil {
        store.state.admissions.contains(
          .init(request: 2, admission: .queued(position: 1))
        )
      }
    )

    await store.cancelEffects(identifiedBy: InheritedCancellationFeature.ownerID)
    #expect(await waitUntil { cancelled.isFinished })

    let third = store.send(.request(3))
    #expect(
      await waitUntil {
        store.state.admissions.contains(
          .init(request: 3, admission: .queued(position: 1))
        )
      }
    )

    await probe.release(1)
    await probe.waitUntilStarted(count: 2)
    await probe.release(3)
    await first.finish()
    await third.finish()

    #expect(await probe.startedValues() == [1, 3])
    #expect(store.state.completed == [1, 3])
  }

  @Test("TestStore inherited cancellation matches Store queue capacity")
  func testStoreInheritedCancellationReturnsPendingCapacity() async {
    let probe = ScheduledRunProbe()
    let store = TestStore(reducer: InheritedCancellationFeature(probe: probe))

    await store.send(.request(1))
    await store.receive(.admission(1, .started)) {
      $0.admissions.append(.init(request: 1, admission: .started))
    }
    await probe.waitUntilStarted(count: 1)

    await store.send(.request(2))
    await store.receive(.admission(2, .queued(position: 1))) {
      $0.admissions.append(.init(request: 2, admission: .queued(position: 1)))
    }
    await store.cancelEffects(identifiedBy: InheritedCancellationFeature.ownerID)

    await store.send(.request(3))
    await store.receive(.admission(3, .queued(position: 1))) {
      $0.admissions.append(.init(request: 3, admission: .queued(position: 1)))
    }

    await probe.release(1)
    await store.receive(.completed(1)) {
      $0.completed.append(1)
    }
    await store.receive(.admission(3, .started)) {
      $0.admissions.append(.init(request: 3, admission: .started))
    }
    await probe.waitUntilStarted(count: 2)
    await probe.release(3)
    await store.receive(.completed(3)) {
      $0.completed.append(3)
    }
    await store.finish()

    #expect(await probe.startedValues() == [1, 3])
  }

  @Test("Store release cancels a running scheduled lane without retaining the Store")
  func storeReleaseCancelsScheduledRun() async {
    let probe = ScheduledRunProbe()
    var store: Store<SchedulingFeature>? = Store(
      reducer: SchedulingFeature(policy: .serial(maxPending: 1), probe: probe)
    )
    weak let releasedStore = store

    let task = store?.send(.request(1)) ?? .completed
    await probe.waitUntilStarted(count: 1)
    store = nil

    #expect(releasedStore == nil)
    #expect(
      await waitUntilAsync {
        await probe.wasCancelled(1)
      }
    )
    await probe.release(1)
    await task.finish()
    #expect(task.isFinished)
  }

  @Test("latest starts without waiting for an uncooperative predecessor")
  func latestCanPhysicallyOverlap() async {
    let probe = ScheduledRunProbe()
    let store = Store(
      reducer: SchedulingFeature(policy: .latest, probe: probe)
    )

    let first = store.send(.request(1))
    await probe.waitUntilStarted(count: 1)
    let second = store.send(.request(2))
    await probe.waitUntilCancelled(1)
    await probe.waitUntilStarted(count: 2)

    #expect(await probe.startedValues() == [1, 2])

    await probe.release(1)
    await probe.release(2)
    await first.finish()
    await second.finish()
    #expect(store.state.completed == [2])
  }

  @Test("three same-dispatch latest runs cannot orphan an admission")
  func threeWayLatestFinishesWithoutStoreRelease() async {
    let probe = ScheduledRunProbe()
    let store = Store(reducer: ThreeWayLatestFeature(probe: probe))

    let task = store.send(.start)
    for value in 1...3 {
      await probe.release(value)
    }

    #expect(
      await waitUntilAsync {
        task.isFinished
      }
    )
    await task.finish()

    #expect(task.isFinished)
    #expect(store.effectBridge.runScheduler.activeRequestCount == 0)
    #expect(store.state.completed.count == 1)
  }

  @Test("TestStore three-way latest follows the same completion contract")
  func testStoreThreeWayLatestFinishes() async {
    let probe = ScheduledRunProbe()
    let store = TestStore(reducer: ThreeWayLatestFeature(probe: probe))
    store.exhaustivity = .off

    await store.send(.start)
    for value in 1...3 {
      await probe.release(value)
    }
    await store.finish()

    #expect(store.runScheduler.activeRequestCount == 0)
    #expect(store.state.completed.count == 1)
  }

  @Test("TestStore observes the same serial admission order")
  func testStoreUsesSharedAdmissionStateMachine() async {
    let probe = ScheduledRunProbe()
    let store = TestStore(
      reducer: SchedulingFeature(policy: .serial(maxPending: 1), probe: probe)
    )

    await store.send(.request(1))
    await store.receive(.admission(1, .started)) {
      $0.admissions.append(.init(request: 1, admission: .started))
    }
    await probe.waitUntilStarted(count: 1)

    await store.send(.request(2))
    await store.receive(.admission(2, .queued(position: 1))) {
      $0.admissions.append(.init(request: 2, admission: .queued(position: 1)))
    }

    await probe.release(1)
    await store.receive(.completed(1)) {
      $0.completed.append(1)
    }
    await store.receive(.admission(2, .started)) {
      $0.admissions.append(.init(request: 2, admission: .started))
    }
    await probe.waitUntilStarted(count: 2)
    await probe.release(2)
    await store.receive(.completed(2)) {
      $0.completed.append(2)
    }
    await store.finish()

    #expect(await probe.startedValues() == [1, 2])
  }

  @Test("same-lane descendant queues without deadlocking its parent run")
  func sameLaneDescendantDoesNotDeadlock() async {
    let probe = ScheduledRunProbe()
    let store = Store(reducer: ReentrantSchedulingFeature(probe: probe))

    let task = store.send(.start)
    await probe.waitUntilStarted(count: 1)
    await probe.release(1)
    await probe.waitUntilStarted(count: 2)
    await probe.release(2)
    await task.finish()

    #expect(await probe.startedValues() == [1, 2])
    #expect(store.state.completed == [1, 2])
    #expect(
      store.state.admissions == [
        .init(request: 1, admission: .started),
        .init(request: 2, admission: .queued(position: 1)),
        .init(request: 2, admission: .started),
      ]
    )
  }

  @Test("queued dispatch capture finishes with only its own typed output")
  func queuedCapturePreservesOutputOwnership() async {
    let probe = ScheduledRunProbe()
    let store = Store(reducer: ScheduledOutputFeature(probe: probe))

    let first = store.send(.request(1), capturingOutputs: .unbounded)
    await probe.waitUntilStarted(count: 1)
    let second = store.send(.request(2), capturingOutputs: .unbounded)

    await probe.release(1)
    await probe.waitUntilStarted(count: 2)
    await probe.release(2)
    await first.finish()
    await second.finish()

    var firstIterator = first.outputs.makeAsyncIterator()
    var secondIterator = second.outputs.makeAsyncIterator()
    #expect(await firstIterator.next() == .value(1))
    #expect(await firstIterator.next() == nil)
    #expect(await secondIterator.next() == .value(2))
    #expect(await secondIterator.next() == nil)
  }

  @Test("same-dispatch latest suppresses an uncooperative displaced run")
  func sameDispatchLatestSuppressesDisplacedRun() async {
    let probe = ScheduledRunProbe()
    let store = Store(reducer: SameDispatchLatestFeature())
    let lane: StaticEffectID = "same-dispatch-latest"
    let sequence = store.effectBridge.nextSequence()
    let context = store.effectBridge.makeEffectContext(
      sequence: sequence,
      cancellationIDs: [AnyEffectID(lane)]
    )
    let first = await store.scheduleRun(
      id: AnyEffectID(lane),
      policy: .latest,
      priority: nil,
      onAdmission: nil,
      operation: { send, _ in
        await probe.run(1)
        await send(.completed(1))
      },
      context: context
    )
    await probe.waitUntilStarted(count: 1)
    let second = await store.scheduleRun(
      id: AnyEffectID(lane),
      policy: .latest,
      priority: nil,
      onAdmission: nil,
      operation: { send, _ in
        await probe.run(2)
        await send(.completed(2))
      },
      context: context
    )

    await probe.waitUntilCancelled(1)
    await probe.waitUntilStarted(count: 2)
    await probe.release(2)
    await probe.release(1)
    _ = await first?.result
    _ = await second?.result

    #expect(store.state.completed == [2])
  }

  @Test("TestStore applies the same same-dispatch latest boundary")
  func testStoreSameDispatchLatestSuppressesDisplacedRun() async {
    let probe = ScheduledRunProbe()
    let store = TestStore(reducer: SameDispatchLatestFeature())
    let lane: StaticEffectID = "same-dispatch-latest"
    let sequence = store.nextSequence()
    let context = store.makeEffectContext(
      sequence: sequence,
      cancellationIDs: [AnyEffectID(lane)]
    )
    let first = await store.scheduleRun(
      id: AnyEffectID(lane),
      policy: .latest,
      priority: nil,
      onAdmission: nil,
      operation: { send, _ in
        await probe.run(1)
        await send(.completed(1))
      },
      context: context
    )
    await probe.waitUntilStarted(count: 1)
    let second = await store.scheduleRun(
      id: AnyEffectID(lane),
      policy: .latest,
      priority: nil,
      onAdmission: nil,
      operation: { send, _ in
        await probe.run(2)
        await send(.completed(2))
      },
      context: context
    )

    await probe.waitUntilCancelled(1)
    await probe.waitUntilStarted(count: 2)
    await probe.release(2)
    await probe.release(1)
    _ = await first?.result
    _ = await second?.result
    await store.receive(.completed(2)) {
      $0.completed = [2]
    }
    await store.receiveOutput(.value(2))
    await store.finish()

    #expect(store.state.completed == [2])
  }
}

private struct SchedulingAdmission: Equatable, Sendable {
  let request: Int
  let admission: EffectAdmission
}

private actor ScheduledRunProbe {
  private var started: [Int] = []
  private var released: Set<Int> = []
  private var releaseWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
  private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var cancelled: Set<Int> = []
  private var cancellationWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

  func run(_ value: Int) async {
    started.append(value)
    let ready = startWaiters.filter { started.count >= $0.0 }
    startWaiters.removeAll { started.count >= $0.0 }
    for waiter in ready {
      waiter.1.resume()
    }

    await withTaskCancellationHandler {
      if released.remove(value) != nil { return }
      await withCheckedContinuation { continuation in
        releaseWaiters[value] = continuation
      }
    } onCancel: {
      Task { await self.markCancelled(value) }
    }
  }

  func release(_ value: Int) {
    if let waiter = releaseWaiters.removeValue(forKey: value) {
      waiter.resume()
    } else {
      released.insert(value)
    }
  }

  func waitUntilStarted(count: Int) async {
    guard started.count < count else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append((count, continuation))
    }
  }

  func startedValues() -> [Int] {
    started
  }

  func waitUntilCancelled(_ value: Int) async {
    guard cancelled.contains(value) == false else { return }
    await withCheckedContinuation { continuation in
      cancellationWaiters[value, default: []].append(continuation)
    }
  }

  func wasCancelled(_ value: Int) -> Bool {
    cancelled.contains(value)
  }

  private func markCancelled(_ value: Int) {
    cancelled.insert(value)
    let waiters = cancellationWaiters.removeValue(forKey: value) ?? []
    for waiter in waiters {
      waiter.resume()
    }
  }
}

private struct SchedulingFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var admissions: [SchedulingAdmission] = []
    var completed: [Int] = []
    init() {}
  }

  enum Action: Equatable, Sendable {
    case request(Int)
    case admission(Int, EffectAdmission)
    case completed(Int)
  }

  let policy: EffectExecutionPolicy
  let probe: ScheduledRunProbe
  var checksCancellationBeforeCompletion = true
  var failingValues: Set<Int> = []
  private let lane: StaticEffectID = "scheduled-run"

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .request(let value):
      return .run(
        id: lane,
        policy: policy,
        onAdmission: { .admission(value, $0) },
        { send, context in
          await probe.run(value)
          if checksCancellationBeforeCompletion {
            guard await context.isCancellationRequested() == false else { return }
          }
          if failingValues.contains(value) {
            await context.reportError(ScheduledRunFailure(value: value))
            return
          }
          await send(.completed(value))
        }
      )

    case .admission(let request, let admission):
      state.admissions.append(.init(request: request, admission: admission))
      return .none

    case .completed(let value):
      state.completed.append(value)
      return .none
    }
  }
}

private struct ScheduledRunFailure: Error, Sendable {
  let value: Int
}

private struct PerRequestSchedulingFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var admissions: [SchedulingAdmission] = []
    init() {}
  }

  enum Action: Equatable, Sendable {
    case request(Int, EffectExecutionPolicy)
    case admission(Int, EffectAdmission)
  }

  let probe: ScheduledRunProbe
  private let lane: StaticEffectID = "mixed-policy"

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .request(let value, let policy):
      return .run(
        id: lane,
        policy: policy,
        onAdmission: { .admission(value, $0) },
        { _, _ in
          await probe.run(value)
        }
      )

    case .admission(let request, let admission):
      state.admissions.append(.init(request: request, admission: admission))
      return .none
    }
  }
}

private struct PerLaneSchedulingFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
  }

  enum Action: Equatable, Sendable {
    case request(value: Int, lane: Int)
  }

  let probe: ScheduledRunProbe

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .request(let value, let lane):
      return .run(
        id: EffectID(lane),
        policy: .dropWhileRunning
      ) { _, _ in
        await probe.run(value)
      }
    }
  }
}

private struct ReentrantSchedulingFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var admissions: [SchedulingAdmission] = []
    var completed: [Int] = []
    init() {}
  }

  enum Action: Equatable, Sendable {
    case start
    case startDescendant
    case admission(Int, EffectAdmission)
    case completed(Int)
  }

  let probe: ScheduledRunProbe
  private let lane: StaticEffectID = "reentrant"

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start:
      return .run(
        id: lane,
        policy: .serial(maxPending: 1),
        onAdmission: { .admission(1, $0) },
        { send, _ in
          await probe.run(1)
          await send(.startDescendant)
          await send(.completed(1))
        }
      )

    case .startDescendant:
      return .run(
        id: lane,
        policy: .serial(maxPending: 1),
        onAdmission: { .admission(2, $0) },
        { send, _ in
          await probe.run(2)
          await send(.completed(2))
        }
      )

    case .admission(let request, let admission):
      state.admissions.append(.init(request: request, admission: admission))
      return .none

    case .completed(let value):
      state.completed.append(value)
      return .none
    }
  }
}

private struct ScheduledOutputFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
  }

  enum Action: Equatable, Sendable {
    case request(Int)
    case completed(Int)
  }

  enum Output: Equatable, Sendable {
    case value(Int)
  }

  let probe: ScheduledRunProbe
  private let lane: StaticEffectID = "captured-output"

  func reduce(
    into state: inout State,
    action: Action
  ) -> ReducerEffect<Action, Output> {
    switch action {
    case .request(let value):
      return .run(id: lane, policy: .serial(maxPending: 1)) { send, _ in
        await probe.run(value)
        await send(.completed(value))
      }

    case .completed(let value):
      return .output(.value(value))
    }
  }
}

private struct SameDispatchLatestFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var completed: [Int] = []
    init() {}
  }

  enum Action: Equatable, Sendable {
    case start
    case completed(Int)
  }

  enum Output: Equatable, Sendable {
    case value(Int)
  }

  func reduce(
    into state: inout State,
    action: Action
  ) -> ReducerEffect<Action, Output> {
    switch action {
    case .start:
      return .none

    case .completed(let value):
      state.completed.append(value)
      return .output(.value(value))
    }
  }

}

private struct ThreeWayLatestFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var completed: [Int] = []
    init() {}
  }

  enum Action: Equatable, Sendable {
    case start
    case completed(Int)
  }

  let probe: ScheduledRunProbe
  private let lane: StaticEffectID = "three-way-latest"

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start:
      return .merge(
        (1...3).map { value in
          .run(id: lane, policy: .latest) { send, context in
            await probe.run(value)
            guard await context.isCancellationRequested() == false else { return }
            await send(.completed(value))
          }
        }
      )

    case .completed(let value):
      state.completed.append(value)
      return .none
    }
  }
}

private struct InheritedCancellationFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var admissions: [SchedulingAdmission] = []
    var completed: [Int] = []
    init() {}
  }

  enum Action: Equatable, Sendable {
    case request(Int)
    case admission(Int, EffectAdmission)
    case completed(Int)
  }

  static let ownerID: StaticEffectID = "inherited-owner"
  let probe: ScheduledRunProbe
  private let lane: StaticEffectID = "inherited-lane"

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .request(let value):
      let effect = EffectTask<Action>.run(
        id: lane,
        policy: .serial(maxPending: 1),
        onAdmission: { .admission(value, $0) },
        { send, _ in
          await probe.run(value)
          await send(.completed(value))
        }
      )
      return value == 2 ? effect.cancellable(Self.ownerID) : effect

    case .admission(let request, let admission):
      state.admissions.append(.init(request: request, admission: admission))
      return .none

    case .completed(let value):
      state.completed.append(value)
      return .none
    }
  }
}
