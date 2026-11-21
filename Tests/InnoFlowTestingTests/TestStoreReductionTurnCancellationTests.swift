// MARK: - TestStoreReductionTurnCancellationTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import InnoFlowCore
import InnoFlowTesting
import Testing
import os

// `Store` accepts reducer-returned cancellation in the turn of the reduction
// that returned it. `TestStore` must give a test the same ordering: an action
// a production store drops must not be received by the test, even when the
// cancelling effect is a composite the test runtime interprets in a task.
//
// As in the `Store` tests, an emission is parked on the MainActor queue by
// keeping the main thread busy. If a loaded machine delays the emission past
// the hold, the tests still pass; the hold can miss the race, never fail
// spuriously.

private final class ParkGate: Sendable {
  private struct State {
    var started: Set<Int> = []
    var released: Set<Int> = []
    var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  func markStarted(_ index: Int) {
    state.withLock { _ = $0.started.insert(index) }
  }

  func hasStarted(_ index: Int) -> Bool {
    state.withLock { $0.started.contains(index) }
  }

  func release(_ index: Int) {
    let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
      state.released.insert(index)
      return state.waiters.removeValue(forKey: index) ?? []
    }
    for waiter in waiters {
      waiter.resume()
    }
  }

  /// Cancellation-insensitive on purpose: the operation must reach its `send`
  /// so the test observes the runtime's emission boundary.
  func waitUntilReleased(_ index: Int) async {
    await withCheckedContinuation { continuation in
      let isReleased = state.withLock { state -> Bool in
        guard !state.released.contains(index) else { return true }
        state.waiters[index, default: []].append(continuation)
        return false
      }
      if isReleased {
        continuation.resume()
      }
    }
  }
}

private let workID = EffectID<String>("teststore-reduction-turn-cancellation")
private let laneID = EffectID<String>("teststore-reduction-turn-cancellation-lane")
private let windowID = EffectID<String>("teststore-reduction-turn-cancellation-window")
private let olderOwnerID = EffectID<String>("teststore-reduction-turn-cancellation-older")
private let newestOwnerID = EffectID<String>("teststore-reduction-turn-cancellation-newest")

private final class CancellationCounter: Sendable {
  private let count = OSAllocatedUnfairLock(initialState: 0)

  func increment() {
    count.withLock { $0 += 1 }
  }

  var value: Int {
    count.withLock { $0 }
  }
}

/// A `.cancel` of parked work behind a lane request its busy lane rejects.
private struct RejectedLaneFeature: Reducer {
  struct State: Equatable, Sendable {}

  enum Action: Equatable, Sendable {
    case occupyLane
    case startWork
    case dropRequestThenCancelWork
  }

  let gate: ParkGate
  let workCancellations: CancellationCounter

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    let gate = gate
    switch action {
    case .occupyLane:
      return .run(id: laneID, policy: .dropWhileRunning) { _, _ in
        gate.markStarted(1)
        await gate.waitUntilReleased(1)
      }

    case .startWork:
      let workCancellations = workCancellations
      return EffectTask<Action>.run { _ in
        await withTaskCancellationHandler {
          gate.markStarted(2)
          await gate.waitUntilReleased(2)
        } onCancel: {
          workCancellations.increment()
        }
      }
      .cancellable(workID)

    case .dropRequestThenCancelWork:
      return .concatenate(
        .run(id: laneID, policy: .dropWhileRunning) { _, _ in gate.markStarted(3) },
        .cancel(workID)
      )
    }
  }
}

/// Lane requests in the branches of one `merge`, which the interpreter runs
/// in any order, beside parked work that counts its cancellations.
private struct MergedLaneFeature: Reducer {
  struct State: Equatable, Sendable {}

  enum Action: Equatable, Sendable {
    /// Parked work under `workID`, or under the lane's ID.
    case startWork(underLane: Bool)
    /// `merge(drop request, concatenate(drop request, .cancel(workID)))`.
    case sameLaneThenCancel
    /// `merge(latest request, serial request)` for one closed lane.
    case latestAndSerial(latestFirst: Bool)
  }

  let gate: ParkGate
  let workCancellations: CancellationCounter

  private func request(_ index: Int, _ policy: EffectExecutionPolicy) -> EffectTask<Action> {
    let gate = gate
    return .run(id: laneID, policy: policy) { _, _ in
      gate.markStarted(index)
      await gate.waitUntilReleased(index)
    }
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .startWork(let underLane):
      let gate = gate
      let workCancellations = workCancellations
      return EffectTask<Action>.run { _ in
        await withTaskCancellationHandler {
          gate.markStarted(2)
          await gate.waitUntilReleased(2)
        } onCancel: {
          workCancellations.increment()
        }
      }
      .cancellable(underLane ? laneID : workID)

    case .sameLaneThenCancel:
      return .merge(
        request(4, .dropWhileRunning),
        .concatenate(request(5, .dropWhileRunning), .cancel(workID)))

    case .latestAndSerial(let latestFirst):
      let latest = request(4, .latest)
      let serial = request(5, .serial(maxPending: 4))
      return latestFirst ? .merge(latest, serial) : .merge(serial, latest)
    }
  }
}

/// Throttled requests, each inside `.cancellable` of an owner ID that covers
/// only it.
private struct OwnedThrottleFeature: Reducer {
  struct State: Equatable, Sendable {
    var fired: [String] = []
  }

  enum Action: Equatable, Sendable {
    case request(String, ownedBy: EffectID<String>)
    case cancel(EffectID<String>)
    case fired(String)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .request(let tag, let owner):
      return EffectTask<Action>.send(.fired(tag))
        .throttle(windowID, for: .seconds(1), leading: true, trailing: true)
        .cancellable(owner)

    case .cancel(let owner):
      return .cancel(owner)

    case .fired(let tag):
      state.fired.append(tag)
      return .none
    }
  }
}

private struct ParkedWorkFeature: Reducer {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: Equatable, Sendable {
    case start
    case loaded
    case resetThenContinue
    case continued
    case search(Int)
    case searchAfterNotice(Int)
    case searching(Int)
    case serial(Int)
    case result(Int)
  }

  let gate: ParkGate

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start:
      let gate = gate
      return EffectTask<Action>.run { send in
        gate.markStarted(0)
        await gate.waitUntilReleased(0)
        await send(.loaded)
      }
      .cancellable(workID)

    case .loaded:
      state.log.append("loaded")
      return .none

    case .resetThenContinue:
      state.log.append("reset")
      return .concatenate(.cancel(workID), .send(.continued))

    case .continued:
      state.log.append("continued")
      return .none

    case .search(let query):
      let gate = gate
      return .run(id: workID, policy: .latest) { send, _ in
        gate.markStarted(query)
        await gate.waitUntilReleased(query)
        await send(.result(query))
      }

    case .searchAfterNotice(let query):
      // The lane request comes after a synchronous sibling, so the lane does
      // not admit it in the reduction turn: only the turn's own acceptance
      // keeps the replaced run from being received.
      let gate = gate
      return .concatenate(
        .send(.searching(query)),
        .run(id: workID, policy: .latest) { send, _ in
          gate.markStarted(query)
          await gate.waitUntilReleased(query)
          await send(.result(query))
        }
      )

    case .searching(let query):
      state.log.append("searching-\(query)")
      return .none

    case .serial(let index):
      let gate = gate
      return .run(id: workID, policy: .serial(maxPending: 4)) { send, _ in
        gate.markStarted(index)
        await gate.waitUntilReleased(index)
        await send(.result(index))
      }

    case .result(let query):
      state.log.append("result-\(query)")
      return .none
    }
  }
}

@MainActor
@Suite(
  "TestStore accepts reducer-returned cancellation in the reduction turn", .serialized,
  .timeLimit(.minutes(5)))
struct TestStoreReductionTurnCancellationTests {
  private func waitUntil(_ condition: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while !condition(), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(2))
    }
  }

  /// Keeps the main thread busy so work resumed by `release` queues its
  /// MainActor hop behind the caller's next statement.
  private func releaseAndHoldMainActor(_ release: () -> Void) {
    release()
    Thread.sleep(forTimeInterval: 0.3)
  }

  @Test("A cancel leading a concatenation drops the emission a Store would drop")
  func leadingCancelInConcatenationDropsParkedEmission() async {
    let gate = ParkGate()
    let store = TestStore(reducer: ParkedWorkFeature(gate: gate), initialState: .init())

    await store.send(.start)
    await waitUntil { gate.hasStarted(0) }
    releaseAndHoldMainActor { gate.release(0) }
    await store.send(.resetThenContinue) {
      $0.log = ["reset"]
    }
    // Exhaustive: receiving `.loaded` here, or leaving it unreceived, fails.
    await store.receive(.continued) {
      $0.log = ["reset", "continued"]
    }
    await store.finish()
  }

  @Test("A latest lane request drops the emission of the run it replaces")
  func latestLaneReplacementDropsParkedEmission() async {
    let gate = ParkGate()
    let store = TestStore(reducer: ParkedWorkFeature(gate: gate), initialState: .init())

    await store.send(.search(1))
    await waitUntil { gate.hasStarted(1) }
    releaseAndHoldMainActor { gate.release(1) }
    await store.send(.search(2))
    await waitUntil { gate.hasStarted(2) }
    gate.release(2)
    await store.receive(.result(2)) {
      $0.log = ["result-2"]
    }
    await store.finish()
  }

  @Test("A latest request behind a synchronous sibling drops the emission of the run it replaces")
  func latestLaneRequestAfterSiblingDropsParkedEmission() async {
    let gate = ParkGate()
    let store = TestStore(reducer: ParkedWorkFeature(gate: gate), initialState: .init())

    await store.send(.searchAfterNotice(1))
    await store.receive(.searching(1)) {
      $0.log = ["searching-1"]
    }
    await waitUntil { gate.hasStarted(1) }
    releaseAndHoldMainActor { gate.release(1) }
    // Exhaustive: receiving `.result(1)` anywhere below fails the test.
    await store.send(.searchAfterNotice(2))
    await store.receive(.searching(2)) {
      $0.log = ["searching-1", "searching-2"]
    }
    await waitUntil { gate.hasStarted(2) }
    gate.release(2)
    await store.receive(.result(2)) {
      $0.log = ["searching-1", "searching-2", "result-2"]
    }
    await store.finish()
  }

  @Test("A latest request a serial lane rejects leaves that lane's work to be received")
  func latestRequestRejectedBySerialLaneLeavesItRunning() async {
    let gate = ParkGate()
    let store = TestStore(reducer: ParkedWorkFeature(gate: gate), initialState: .init())

    await store.send(.serial(1))
    await waitUntil { gate.hasStarted(1) }
    await store.send(.serial(2))
    // The serial lane rejects the `latest` request, which replaces nothing.
    await store.send(.search(9))
    gate.release(1)
    await store.receive(.result(1)) {
      $0.log = ["result-1"]
    }
    await waitUntil { gate.hasStarted(2) }
    gate.release(2)
    await store.receive(.result(2)) {
      $0.log = ["result-1", "result-2"]
    }
    #expect(gate.hasStarted(9) == false)
    await store.finish()
  }

  @Test("A cancel behind a lane request its busy lane rejects is accepted in the reduction turn")
  func cancelBehindRejectedLaneRequestIsAcceptedInTheTurn() async {
    let gate = ParkGate()
    let workCancellations = CancellationCounter()
    let store = TestStore(
      reducer: RejectedLaneFeature(gate: gate, workCancellations: workCancellations),
      initialState: .init())

    await store.send(.occupyLane)
    await waitUntil { gate.hasStarted(1) }
    await store.send(.startWork)
    await waitUntil { gate.hasStarted(2) }

    await store.send(.dropRequestThenCancelWork)
    // The concatenation runs in a task after `send` returns; only the
    // reduction turn's acceptance has cancelled the work by now.
    #expect(workCancellations.value == 1)

    gate.release(1)
    gate.release(2)
    await store.finish()
    #expect(gate.hasStarted(3) == false)
  }

  @Test(
    "Cancelling an ID only the newest throttle request carries fires the request it replaced",
    arguments: [false, true])
  func throttleFallbackAfterNewestOwnerCancellation(throughReducer: Bool) async throws {
    let clock = ManualTestClock()
    let store = TestStore(reducer: OwnedThrottleFeature(), initialState: .init(), clock: clock)

    await store.send(.request("first", ownedBy: olderOwnerID))
    await store.receive(.fired("first")) {
      $0.fired = ["first"]
    }
    try await clock.waitForSleepers(atLeast: 1)
    await store.send(.request("second", ownedBy: olderOwnerID))
    await store.send(.request("third", ownedBy: newestOwnerID))

    if throughReducer {
      await store.send(.cancel(newestOwnerID))
    } else {
      await store.cancelEffects(identifiedBy: newestOwnerID)
    }
    await clock.advance(by: .seconds(1))
    await store.receive(.fired("second")) {
      $0.fired = ["first", "second"]
    }
    await store.finish()
  }

  @Test("A throttle request its own ID cancellation removes releases its test dispatch at once")
  func removedThrottleRequestReleasesItsDispatch() async throws {
    let clock = ManualTestClock()
    let store = TestStore(reducer: OwnedThrottleFeature(), initialState: .init(), clock: clock)

    await store.send(.request("first", ownedBy: olderOwnerID))
    await store.receive(.fired("first")) {
      $0.fired = ["first"]
    }
    try await clock.waitForSleepers(atLeast: 1)
    let second = await store.send(.request("second", ownedBy: olderOwnerID))
    let third = await store.send(.request("third", ownedBy: newestOwnerID))
    let window = AnyEffectID(windowID)
    await waitUntil {
      store.throttleState.pending(for: window)?.scope?.inheritedCancellationIDs
        == [AnyEffectID(newestOwnerID)]
    }

    // The window falls back to `second`; `third`'s dispatch has nothing
    // left to wait for.
    await store.cancelEffects(identifiedBy: newestOwnerID)
    await third.finish()
    #expect(third.isFinished)
    #expect(second.isFinished == false)

    await clock.advance(by: .seconds(1))
    await store.receive(.fired("second")) {
      $0.fired = ["first", "second"]
    }
    await store.finish()
  }

  @Test(
    "TestStore accepts nothing behind a lane request another merge branch can reorder",
    arguments: [
      MergedLaneFeature.Action.sameLaneThenCancel, .latestAndSerial(latestFirst: true),
      .latestAndSerial(latestFirst: false),
    ])
  fileprivate func nothingAcceptedBehindOrderDependentLaneRequest(
    trigger: MergedLaneFeature.Action
  ) async {
    let gate = ParkGate()
    let workCancellations = CancellationCounter()
    let store = TestStore(
      reducer: MergedLaneFeature(gate: gate, workCancellations: workCancellations),
      initialState: .init())
    store.exhaustivity = .off

    await store.send(.startWork(underLane: trigger != .sameLaneThenCancel))
    await waitUntil { gate.hasStarted(2) }
    // Only started work counts a cancellation.
    #expect(gate.hasStarted(2))

    await store.send(trigger)
    // The merge's branches run in tasks after `send` returns: only the
    // reduction turn has run, and it accepted nothing the order of those
    // branches decides.
    #expect(workCancellations.value == 0)

    for index in [2, 4, 5] { gate.release(index) }
    await store.finish()
  }
}
