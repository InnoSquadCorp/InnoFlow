// MARK: - ReducerCancellationAcceptanceTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import InnoFlowCore
import Testing
import os

@testable import InnoFlowCoreTestSupport

// A reducer-returned cancellation must take effect in the MainActor turn of
// the reduction that returned it. These tests park an emission from the
// cancelled work on the MainActor queue (by keeping the main thread busy),
// then send the cancelling action synchronously. The parked emission must be
// dropped even though the root interpreter task has not run yet.
//
// If a loaded machine delays the emission past the hold, the tests still
// pass: a late emission is dropped under both the old and the new ordering.
// The hold can only miss the race, never fail spuriously.

private final class EmissionGate: Sendable {
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
  /// so the test observes the runtime's emission boundary, not cooperative
  /// task cancellation.
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

  /// Honors the `StoreClock.sleep` cancellation contract.
  func sleepUntilReleased(_ index: Int) async throws {
    while !state.withLock({ $0.released.contains(index) }) {
      try await Task.sleep(for: .milliseconds(1))
    }
  }
}

/// Keeps the main thread busy so work resumed by `release` queues its
/// MainActor hop behind the caller's next synchronous statement.
@MainActor
private func releaseAndHoldMainActor(_ release: () -> Void) {
  release()
  Thread.sleep(forTimeInterval: 0.3)
}

/// Polls until `condition` holds. The deadline is a failure backstop scaled
/// with `INNOFLOW_TEST_WAIT_SCALE`; missing it is reported where the wait was
/// written instead of surfacing as an unrelated expectation further down.
@MainActor
private func waitUntil(
  sourceLocation: SourceLocation = #_sourceLocation,
  _ condition: @MainActor () -> Bool
) async {
  let deadline = ContinuousClock.now.advanced(by: scaledTestDeadline(.seconds(10)))
  while !condition() {
    guard ContinuousClock.now < deadline else {
      Issue.record("The awaited condition was not reached in time", sourceLocation: sourceLocation)
      return
    }
    try? await Task.sleep(for: .milliseconds(2))
  }
}

@MainActor
private func settle() async {
  try? await Task.sleep(for: .milliseconds(300))
}

private let workID = EffectID<String>("reducer-cancellation-acceptance")

private struct CancellationFeature: Reducer {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: Sendable {
    case start
    case loaded
    case reset
    case resetThenContinue
    case continued
  }

  let gate: EmissionGate

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

    case .reset:
      state.log.append("reset")
      return .cancel(workID)

    case .resetThenContinue:
      state.log.append("reset")
      return .concatenate(.cancel(workID), .send(.continued))

    case .continued:
      state.log.append("continued")
      return .none
    }
  }
}

private struct ReplacementFeature: Reducer {
  struct State: Equatable, Sendable {
    var results: [Int] = []
  }

  enum Action: Sendable {
    case search(Int)
    case result(Int)
  }

  let gate: EmissionGate

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .search(let query):
      let gate = gate
      return EffectTask<Action>.run { send in
        gate.markStarted(query)
        await gate.waitUntilReleased(query)
        await send(.result(query))
      }
      .cancellable(workID, cancelInFlight: true)

    case .result(let query):
      state.results.append(query)
      return .none
    }
  }
}

private struct DebounceFeature: Reducer {
  struct State: Equatable, Sendable {
    var fired: [Int] = []
  }

  enum Action: Sendable {
    case edit(Int)
    case fired(Int)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .edit(let value):
      return EffectTask<Action>.send(.fired(value)).debounce(workID, for: .seconds(1))

    case .fired(let value):
      state.fired.append(value)
      return .none
    }
  }
}

private struct LaneFeature: Reducer {
  struct State: Equatable, Sendable {}

  enum Action: Sendable {
    case enqueue(Int)
    case cancel
  }

  let gate: EmissionGate

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .enqueue(let index):
      let gate = gate
      return .run(id: workID, policy: .serial(maxPending: 4)) { _, _ in
        gate.markStarted(index)
        await gate.waitUntilReleased(index)
      }

    case .cancel:
      return .cancel(workID)
    }
  }
}

private let otherID = EffectID<String>("reducer-cancellation-acceptance-other")

/// Effects that cancel an ID after an earlier sibling already used it.
private struct SiblingOrderFeature: Reducer {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: Sendable {
    case cancelAfterOwnedSend
    case cancelInsideOwnedConcatenation
    case mark
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .cancelAfterOwnedSend:
      return .concatenate(EffectTask<Action>.send(.mark).cancellable(workID), .cancel(workID))

    case .cancelInsideOwnedConcatenation:
      return EffectTask<Action>.concatenate(.send(.mark), .cancel(workID)).cancellable(workID)

    case .mark:
      state.log.append("mark")
      return .none
    }
  }
}

/// A parked run, and a reset that reaches its cancel only after a sibling
/// the same effect has already cancelled.
private struct SkippedSiblingFeature: Reducer {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: Sendable {
    case start
    case loaded
    case resetAfterSkippedRun
  }

  let gate: EmissionGate

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

    case .resetAfterSkippedRun:
      state.log.append("reset")
      return .concatenate(
        .cancel(otherID),
        EffectTask<Action>.run { _ in }.cancellable(otherID),
        .cancel(workID)
      )
    }
  }
}

private struct LatestLaneFeature: Reducer {
  struct State: Equatable, Sendable {
    var results: [Int] = []
  }

  enum Action: Sendable {
    case search(Int)
    case result(Int)
  }

  let gate: EmissionGate

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .search(let query):
      let gate = gate
      return .run(id: workID, policy: .latest) { send, _ in
        gate.markStarted(query)
        await gate.waitUntilReleased(query)
        await send(.result(query))
      }

    case .result(let query):
      state.results.append(query)
      return .none
    }
  }
}

/// Starts work under an ID and, in a merged sibling reached without awaiting,
/// cancels that ID: the dispatch's own `.cancel` releases its own work.
private struct SelfCancelFeature: Reducer {
  struct State: Equatable, Sendable {
    var marks = 0
  }

  enum Action: Sendable {
    case go(Int)
    case mark
  }

  let gate: EmissionGate

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .go(let index):
      let gate = gate
      return .merge(
        EffectTask<Action>.run { _ in
          gate.markStarted(index)
          await gate.waitUntilReleased(index)
        }
        .cancellable(workID),
        .concatenate(.send(.mark), .send(.mark), .cancel(workID))
      )

    case .mark:
      state.marks += 1
      return .none
    }
  }
}

/// One lane ID used with different policies by different actions.
private struct MixedPolicyFeature: Reducer {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: Sendable {
    case serial(Int)
    case latest(Int)
    case dropWhileRunning(Int)
    case result(Int)
    case admission(String)
  }

  let gate: EmissionGate

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    let gate = gate
    switch action {
    case .serial(let index):
      return .run(id: workID, policy: .serial(maxPending: 4)) { send, _ in
        gate.markStarted(index)
        await gate.waitUntilReleased(index)
        await send(.result(index))
      }

    case .latest(let index):
      return .run(
        id: workID, policy: .latest,
        onAdmission: { .admission("latest-\(index):\(admissionLabel($0))") },
        { send, _ in
          gate.markStarted(index)
          await gate.waitUntilReleased(index)
          await send(.result(index))
        }
      )

    case .dropWhileRunning(let index):
      return .run(
        id: workID, policy: .dropWhileRunning,
        onAdmission: { .admission("drop-\(index):\(admissionLabel($0))") },
        { send, _ in
          gate.markStarted(index)
          await gate.waitUntilReleased(index)
          await send(.result(index))
        }
      )

    case .result(let index):
      state.log.append("result-\(index)")
      return .none

    case .admission(let label):
      state.log.append(label)
      return .none
    }
  }
}

private func admissionLabel(_ admission: EffectAdmission) -> String {
  switch admission {
  case .rejected: "rejected"
  default: "\(admission)"
  }
}

/// Work a dispatch declares under `workID` but has not registered yet when a
/// cancellation of that ID is accepted.
private struct DeclaredWorkFeature: Reducer {
  struct State: Equatable, Sendable {
    var marks = 0
    var log: [String] = []
  }

  enum Action: Sendable {
    /// The issuing effect's own `.cancel` is interpreted while its work under
    /// the ID still waits behind a held sibling.
    case ownCancelBeforeRegistration
    /// Control: the work is registered and parked before the own `.cancel`.
    case ownCancelAfterRegistration
    /// Control: the own `.cancel` follows work that has already finished.
    case ownCancelAfterOwnWork
    /// The work under the ID waits behind a held run.
    case declareBehindHold
    case cancelWork
    case mark
    case ran
  }

  let gate: EmissionGate

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    let gate = gate
    let hold = EffectTask<Action>.run { _ in
      gate.markStarted(1)
      await gate.waitUntilReleased(1)
    }
    switch action {
    case .ownCancelBeforeRegistration:
      return .merge(
        .concatenate(
          hold,
          EffectTask<Action>.run { send in
            gate.markStarted(2)
            await send(.ran)
          }
          .cancellable(workID)
        ),
        .concatenate(.cancel(workID), .send(.mark))
      )

    case .ownCancelAfterRegistration:
      return .merge(
        EffectTask<Action>.run { send in
          gate.markStarted(2)
          await gate.waitUntilReleased(2)
          await send(.ran)
        }
        .cancellable(workID),
        .concatenate(hold, .cancel(workID), .send(.mark))
      )

    case .ownCancelAfterOwnWork:
      return .concatenate(EffectTask<Action>.send(.mark).cancellable(workID), .cancel(workID))

    case .declareBehindHold:
      return .concatenate(
        hold,
        EffectTask<Action>.run { send in
          gate.markStarted(2)
          await send(.ran)
        }
        .cancellable(workID)
      )

    case .cancelWork:
      return .cancel(workID)

    case .mark:
      state.marks += 1
      return .none

    case .ran:
      state.log.append("ran")
      return .none
    }
  }
}

private final class CancellationCounter: Sendable {
  private let count = OSAllocatedUnfairLock(initialState: 0)

  func increment() {
    count.withLock { $0 += 1 }
  }

  var value: Int {
    count.withLock { $0 }
  }
}

private let laneID = EffectID<String>("reducer-cancellation-acceptance-lane")
private let otherLaneID = EffectID<String>("reducer-cancellation-acceptance-other-lane")

/// A lane request followed, in the same concatenation, by a `.cancel` of
/// unrelated work. A request the lane does not admit awaits nothing.
private struct LaneThenCancelFeature: Reducer {
  enum Trigger: Sendable, CaseIterable {
    /// `dropWhileRunning` meets its own busy lane.
    case busyDropLane
    /// `latest` meets a `dropWhileRunning` lane.
    case conflictingPolicy
    /// `serial(maxPending: 0)` meets its running lane.
    case fullSerialQueue
    /// The same tree cancels the lane ID before it requests the lane.
    case laneCancelledByOwnTree
    /// Control: the lane admits the request, whose run is awaited.
    case admittedRequest
  }

  struct State: Equatable, Sendable {
    var admissions: [EffectAdmission] = []
  }

  enum Action: Sendable {
    case occupyDropLane
    case occupySerialLane
    case startWork
    case trigger(Trigger)
    case openLatestUnderOwner
    case dropRequestThenCancel
    case admission(EffectAdmission)
  }

  let gate: EmissionGate
  let workCancellations: CancellationCounter

  private func occupant(_ policy: EffectExecutionPolicy) -> EffectTask<Action> {
    let gate = gate
    return .run(id: laneID, policy: policy) { _, _ in
      gate.markStarted(10)
      await gate.waitUntilReleased(10)
    }
  }

  /// A lane request that never awaits anything once it is admitted.
  private func request(
    on id: EffectID<String> = laneID,
    _ policy: EffectExecutionPolicy,
    onAdmission: (@Sendable (EffectAdmission) -> Action)? = nil
  ) -> EffectTask<Action> {
    let gate = gate
    guard let onAdmission else {
      return .run(id: id, policy: policy) { _, _ in gate.markStarted(30) }
    }
    return .run(id: id, policy: policy, onAdmission: onAdmission) { _, _ in gate.markStarted(30) }
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    let gate = gate
    let workCancellations = workCancellations
    switch action {
    case .occupyDropLane:
      return occupant(.dropWhileRunning)

    case .occupySerialLane:
      return occupant(.serial(maxPending: 0))

    case .startWork:
      return EffectTask<Action>.run { _ in
        await withTaskCancellationHandler {
          gate.markStarted(20)
          await gate.waitUntilReleased(20)
        } onCancel: {
          workCancellations.increment()
        }
      }
      .cancellable(workID)

    case .trigger(let trigger):
      let laneRequest: EffectTask<Action>
      switch trigger {
      case .busyDropLane:
        laneRequest = request(.dropWhileRunning)
      case .conflictingPolicy:
        laneRequest = request(.latest)
      case .fullSerialQueue:
        laneRequest = request(.serial(maxPending: 0))
      case .laneCancelledByOwnTree:
        laneRequest = .concatenate(.cancel(laneID), request(.serial(maxPending: 4)))
      case .admittedRequest:
        laneRequest = .run(id: otherLaneID, policy: .dropWhileRunning) { _, _ in
          gate.markStarted(31)
          await gate.waitUntilReleased(31)
        }
      }
      return .concatenate(laneRequest, .cancel(workID))

    case .openLatestUnderOwner:
      return occupant(.latest).cancellable(otherID)

    case .dropRequestThenCancel:
      return .concatenate(
        request(.dropWhileRunning, onAdmission: { .admission($0) }),
        .cancel(workID)
      )

    case .admission(let admission):
      state.admissions.append(admission)
      return .none
    }
  }
}

@MainActor
@Suite(
  "Reducer-returned cancellation is accepted in the reduction turn", .serialized,
  .timeLimit(.minutes(5)))
struct ReducerCancellationAcceptanceTests {
  // Only `concatenate` orders its children. `merge` runs them concurrently,
  // so which of a merged send and cancel comes first is not specified.
  @Test(
    "A cancel does not pre-empt an earlier concatenated sibling of the effect that returned it",
    arguments: [
      SiblingOrderFeature.Action.cancelAfterOwnedSend,
      .cancelInsideOwnedConcatenation,
    ])
  fileprivate func cancelKeepsEarlierSiblingOfItsOwnEffect(
    action: SiblingOrderFeature.Action
  ) async {
    let store = Store(reducer: SiblingOrderFeature(), initialState: .init())

    await store.send(action).finish()

    #expect(store.state.log == ["mark"])
  }

  @Test("A cancel that follows a sibling its own effect cancelled is still accepted in the turn")
  func cancelAfterSkippedSiblingDropsQueuedEmission() async {
    let gate = EmissionGate()
    let store = Store(reducer: SkippedSiblingFeature(gate: gate), initialState: .init())

    store.send(.start)
    await waitUntil { gate.hasStarted(0) }
    releaseAndHoldMainActor { gate.release(0) }
    store.send(.resetAfterSkippedRun)
    await settle()

    #expect(store.state.log == ["reset"])
  }

  @Test("A latest lane request drops the emission of the run it replaces")
  func latestLaneReplacementDropsPredecessorEmission() async {
    let gate = EmissionGate()
    let store = Store(reducer: LatestLaneFeature(gate: gate), initialState: .init())

    store.send(.search(1))
    await waitUntil { gate.hasStarted(1) }
    releaseAndHoldMainActor { gate.release(1) }
    store.send(.search(2))
    await waitUntil { gate.hasStarted(2) }
    await settle()
    #expect(store.state.results == [])

    gate.release(2)
    await waitUntil { store.state.results == [2] }
    #expect(store.state.results == [2])
  }

  @Test(
    "A request a lane with another policy rejects leaves that lane's work running",
    arguments: ["latest", "dropWhileRunning"])
  func requestRejectedByLaneWithAnotherPolicyLeavesItRunning(policy: String) async {
    let gate = EmissionGate()
    let store = Store(reducer: MixedPolicyFeature(gate: gate), initialState: .init())

    store.send(.serial(1))
    await waitUntil { gate.hasStarted(1) }
    store.send(.serial(2))
    store.send(policy == "latest" ? .latest(9) : .dropWhileRunning(9))
    let rejection = policy == "latest" ? "latest-9:rejected" : "drop-9:rejected"
    await waitUntil { store.state.log == [rejection] }

    gate.release(1)
    await waitUntil { gate.hasStarted(2) }
    gate.release(2)
    await waitUntil { store.state.log.count == 3 }
    #expect(store.state.log == [rejection, "result-1", "result-2"])
    #expect(gate.hasStarted(9) == false)
  }

  @Test("A latest replacement cancelled before interpretation still releases its predecessor")
  func latestReplacementCancelledBeforeInterpretationReleasesPredecessor() async {
    let gate = EmissionGate()
    let diagnostics = StoreDiagnostics(capacity: 64)
    let store = Store(
      reducer: LatestLaneFeature(gate: gate), initialState: .init(), diagnostics: diagnostics)

    let first = store.send(.search(1))
    await waitUntil { gate.hasStarted(1) }
    // Returned and cancelled in one MainActor turn: the replacement's effect is
    // never interpreted, but the reducer did return a `latest` request.
    store.send(.search(2)).cancel()
    gate.release(1)
    await first.finish()
    await settle()

    #expect(store.state.results == [])
    #expect(gate.hasStarted(2) == false)
    let records = diagnostics.snapshot().records
    let firstDispatch = records.first { $0.kind == .submitted }?.dispatchID
    #expect(firstDispatch != nil)
    #expect(
      records.contains { $0.dispatchID == firstDispatch && $0.kind == .cancellationRequested })
    #expect(
      records.contains { $0.dispatchID == firstDispatch && $0.kind == .admission(.superseded) })
  }

  // A `latest` request accepted in its reduction turn displaces the lane at
  // once. Lane identity (docs/RUN_LANE_SNAPSHOTS.md) is stable through the
  // replacement while the lane is live; a closed lane reopens as a new one.
  @Test("A latest replacement accepted in its reduction turn keeps the lane's identity")
  func latestReplacementKeepsLaneIdentity() async {
    let gate = EmissionGate()
    let store = Store(reducer: LatestLaneFeature(gate: gate), initialState: .init())

    let first = store.send(.search(1))
    await waitUntil { gate.hasStarted(1) }
    let lane = store.runLaneSnapshots().first?.id
    #expect(lane != nil)

    let second = store.send(.search(2))
    await waitUntil { gate.hasStarted(2) }
    let snapshots = store.runLaneSnapshots()
    #expect(snapshots.count == 1)
    #expect(snapshots.first?.id == lane)

    gate.release(1)
    gate.release(2)
    await first.finish()
    await second.finish()
    #expect(store.state.results == [2])
  }

  @Test("A replacement superseded before admission hands the lane's identity to the newer one")
  func supersededReplacementHandsLaneIdentityOn() async {
    let gate = EmissionGate()
    let store = Store(reducer: LatestLaneFeature(gate: gate), initialState: .init())

    let first = store.send(.search(1))
    await waitUntil { gate.hasStarted(1) }
    let lane = store.runLaneSnapshots().first?.id
    #expect(lane != nil)

    // One MainActor turn: the second replacement is superseded by the third
    // before the lane could admit it.
    let second = store.send(.search(2))
    let third = store.send(.search(3))
    await waitUntil { gate.hasStarted(3) }
    let snapshots = store.runLaneSnapshots()
    #expect(snapshots.count == 1)
    #expect(snapshots.first?.id == lane)
    #expect(gate.hasStarted(2) == false)

    gate.release(1)
    gate.release(3)
    await first.finish()
    await second.finish()
    await third.finish()
    #expect(store.state.results == [3])
  }

  @Test("A lane whose replacement was cancelled before admission reopens as a new lane")
  func laneReopenedAfterCancelledReplacementIsNew() async {
    let gate = EmissionGate()
    let store = Store(reducer: LatestLaneFeature(gate: gate), initialState: .init())

    let first = store.send(.search(1))
    await waitUntil { gate.hasStarted(1) }
    let closedLane = store.runLaneSnapshots().first?.id
    #expect(closedLane != nil)

    // The replacement displaces the lane in its reduction turn, but its
    // dispatch is cancelled before the lane admits it: the lane is closed.
    store.send(.search(2)).cancel()
    gate.release(1)
    await first.finish()
    #expect(store.runLaneSnapshots().isEmpty)

    let third = store.send(.search(3))
    await waitUntil { gate.hasStarted(3) }
    let reopenedLane = store.runLaneSnapshots().first?.id
    #expect(reopenedLane != nil)
    #expect(reopenedLane != closedLane)

    gate.release(3)
    await third.finish()
    #expect(store.state.results == [3])
  }

  @Test("A dispatch whose own cancel releases its own work records the cancellation")
  func ownCancelOfOwnWorkRecordsCancellation() async {
    // `merge` children are unordered, so cover several interleavings; every
    // one of them must record the request for the dispatch that issued it.
    for index in 0..<6 {
      let gate = EmissionGate()
      let diagnostics = StoreDiagnostics(capacity: 64)
      let store = Store(
        reducer: SelfCancelFeature(gate: gate), initialState: .init(),
        diagnostics: diagnostics)

      let dispatch = store.send(.go(index))
      await settle()
      gate.release(index)
      await dispatch.finish()

      let records = diagnostics.snapshot().records
      let dispatchID = records.first { $0.kind == .submitted }?.dispatchID
      #expect(dispatchID != nil)
      #expect(
        records.contains { $0.dispatchID == dispatchID && $0.kind == .cancellationRequested },
        "iteration \(index)")
      #expect(store.state.marks == 2)
    }
  }

  @Test("A dispatch replaced before its effect was interpreted records the cancellation")
  func dispatchReplacedInTheSameTurnRecordsCancellation() async {
    let gate = EmissionGate()
    let diagnostics = StoreDiagnostics(capacity: 64)
    let store = Store(
      reducer: ReplacementFeature(gate: gate), initialState: .init(), diagnostics: diagnostics)

    // Both sends happen in one MainActor turn: the first effect has not been
    // interpreted, so none of its work is registered when the second send
    // replaces it.
    let replaced = store.send(.search(1))
    store.send(.search(2))
    await waitUntil { gate.hasStarted(2) }
    // The replaced run must never start. Its gate ignores cancellation, so
    // open it before waiting: a run that did start then finishes and fails
    // the expectation below instead of keeping `finish()` waiting forever.
    gate.release(1)
    await replaced.finish()

    let records = diagnostics.snapshot().records
    let replacedDispatch = records.first { $0.kind == .submitted }?.dispatchID
    #expect(replacedDispatch != nil)
    #expect(
      records.contains { $0.dispatchID == replacedDispatch && $0.kind == .cancellationRequested })
    #expect(gate.hasStarted(1) == false)

    gate.release(2)
    await waitUntil { store.state.results == [2] }
    #expect(store.state.results == [2])
  }

  @Test("Control: the store-level cancel API drops an emission already queued for MainActor")
  func storeLevelCancelDropsQueuedEmission() async {
    let gate = EmissionGate()
    let store = Store(reducer: CancellationFeature(gate: gate), initialState: .init())

    store.send(.start)
    await waitUntil { gate.hasStarted(0) }
    releaseAndHoldMainActor { gate.release(0) }
    await store.cancelEffects(identifiedBy: workID)
    await settle()

    #expect(store.state.log == [])
  }

  @Test("A reducer-returned cancel drops an emission already queued for MainActor")
  func reducerReturnedCancelDropsQueuedEmission() async {
    let gate = EmissionGate()
    let store = Store(reducer: CancellationFeature(gate: gate), initialState: .init())

    store.send(.start)
    await waitUntil { gate.hasStarted(0) }
    releaseAndHoldMainActor { gate.release(0) }
    store.send(.reset)
    await settle()

    #expect(store.state.log == ["reset"])
  }

  @Test("A cancel leading a concatenation is accepted before its later siblings are delivered")
  func leadingCancelInConcatenationDropsQueuedEmission() async {
    let gate = EmissionGate()
    let store = Store(reducer: CancellationFeature(gate: gate), initialState: .init())

    store.send(.start)
    await waitUntil { gate.hasStarted(0) }
    releaseAndHoldMainActor { gate.release(0) }
    await store.send(.resetThenContinue).finish()
    await settle()

    #expect(store.state.log == ["reset", "continued"])
  }

  @Test("cancelInFlight replacement drops the predecessor's queued emission")
  func cancelInFlightReplacementDropsPredecessorEmission() async {
    let gate = EmissionGate()
    let store = Store(reducer: ReplacementFeature(gate: gate), initialState: .init())

    store.send(.search(1))
    await waitUntil { gate.hasStarted(1) }
    releaseAndHoldMainActor { gate.release(1) }
    store.send(.search(2))
    await waitUntil { gate.hasStarted(2) }
    await settle()
    #expect(store.state.results == [])

    gate.release(2)
    await waitUntil { store.state.results == [2] }
    #expect(store.state.results == [2])
  }

  @Test("A newer debounce request supersedes a predecessor whose timer already expired")
  func debounceReplacementSupersedesExpiredPredecessorTimer() async {
    let gate = EmissionGate()
    let sleepCount = OSAllocatedUnfairLock(initialState: 0)
    let clock = StoreClock(
      now: { ContinuousClock().now },
      sleep: { _ in
        let index = sleepCount.withLock { count -> Int in
          count += 1
          return count
        }
        gate.markStarted(index)
        try await gate.sleepUntilReleased(index)
      }
    )
    let store = Store(reducer: DebounceFeature(), initialState: .init(), clock: clock)

    store.send(.edit(1))
    await waitUntil { gate.hasStarted(1) }
    // The first timer expires, but its MainActor continuation is still queued
    // when the second edit is reduced.
    releaseAndHoldMainActor { gate.release(1) }
    store.send(.edit(2))
    await waitUntil { gate.hasStarted(2) }
    await settle()
    #expect(store.state.fired == [])

    gate.release(2)
    await waitUntil { store.state.fired == [2] }
    #expect(store.state.fired == [2])
  }

  @Test(
    "A reducer-returned cancel returns pending lane capacity before send returns",
    arguments: [false, true]
  )
  func reducerReturnedCancelReleasesPendingLaneRequestsSynchronously(diagnosticsEnabled: Bool)
    async
  {
    let gate = EmissionGate()
    let store = Store(
      reducer: LaneFeature(gate: gate),
      initialState: .init(),
      diagnostics: diagnosticsEnabled ? StoreDiagnostics(capacity: 32) : nil
    )
    let scheduler = store.effectBridge.runScheduler

    store.send(.enqueue(0))
    await waitUntil { gate.hasStarted(0) }
    store.send(.enqueue(1))
    store.send(.enqueue(2))
    await waitUntil { scheduler.activeRequestCount == 3 }
    #expect(scheduler.activeRequestCount == 3)

    store.send(.cancel)
    // The running operation keeps its physical slot until it returns; both
    // pending requests are released in the turn that reduced `.cancel`.
    #expect(scheduler.activeRequestCount == 1)

    gate.release(0)
    await waitUntil { scheduler.activeRequestCount == 0 }
    #expect(scheduler.activeRequestCount == 0)
  }

  @Test(
    "The store-level cancel API releases pending lane capacity before its first suspension",
    arguments: [false, true]
  )
  func storeLevelCancelReleasesPendingLaneRequestsBeforeSuspending(diagnosticsEnabled: Bool)
    async
  {
    let gate = EmissionGate()
    let store = Store(
      reducer: LaneFeature(gate: gate),
      initialState: .init(),
      diagnostics: diagnosticsEnabled ? StoreDiagnostics(capacity: 32) : nil
    )
    let scheduler = store.effectBridge.runScheduler

    store.send(.enqueue(0))
    await waitUntil { gate.hasStarted(0) }
    store.send(.enqueue(1))
    await waitUntil { scheduler.activeRequestCount == 2 }

    // An unstructured MainActor task runs until its first suspension before
    // this test body resumes, so the count observed here is the one that
    // exists when cancellation first suspends.
    let cancellation = Task { @MainActor in
      await store.cancelEffects(identifiedBy: workID)
    }
    let observer = Task { @MainActor in
      scheduler.activeRequestCount
    }
    #expect(await observer.value == 1)

    gate.release(0)
    await cancellation.value
    await waitUntil { scheduler.activeRequestCount == 0 }
    #expect(scheduler.activeRequestCount == 0)
  }

  // MARK: Work cancelled before it registered

  private func cancellationRecorded(
    for dispatchIndex: Int, in diagnostics: StoreDiagnostics
  ) -> Bool {
    let records = diagnostics.snapshot().records
    let dispatches = records.filter { $0.kind == .submitted }.map(\.dispatchID)
    guard dispatches.indices.contains(dispatchIndex) else { return false }
    return records.contains {
      $0.dispatchID == dispatches[dispatchIndex] && $0.kind == .cancellationRequested
    }
  }

  @Test(
    "An own cancel records the cancellation whether or not its work registered first",
    arguments: [true, false])
  func ownCancelRecordsCancellationInEitherOrder(cancelFirst: Bool) async {
    let gate = EmissionGate()
    let diagnostics = StoreDiagnostics(capacity: 64)
    let store = Store(
      reducer: DeclaredWorkFeature(gate: gate), initialState: .init(), diagnostics: diagnostics)

    if cancelFirst {
      // The work waits behind the held sibling, so the cancel is interpreted
      // before anything is registered under the ID.
      let dispatch = store.send(.ownCancelBeforeRegistration)
      await waitUntil { store.state.marks == 1 && gate.hasStarted(1) }
      gate.release(1)
      await dispatch.finish()
      #expect(gate.hasStarted(2) == false)
    } else {
      let dispatch = store.send(.ownCancelAfterRegistration)
      await waitUntil { gate.hasStarted(1) && gate.hasStarted(2) }
      gate.release(1)
      await waitUntil { store.state.marks == 1 }
      gate.release(2)
      await dispatch.finish()
    }

    #expect(store.state.log.isEmpty)
    #expect(cancellationRecorded(for: 0, in: diagnostics))
  }

  @Test(
    "A partly interpreted dispatch records the cancellation of work it had not reached",
    arguments: ["reducer", "store"])
  func partlyInterpretedDispatchRecordsSkippedWork(cancelledBy source: String) async {
    let gate = EmissionGate()
    let diagnostics = StoreDiagnostics(capacity: 64)
    let store = Store(
      reducer: DeclaredWorkFeature(gate: gate), initialState: .init(), diagnostics: diagnostics)

    let dispatch = store.send(.declareBehindHold)
    // The root interpreter has started: the held run is registered, the work
    // under the ID behind it is not.
    await waitUntil { gate.hasStarted(1) }
    if source == "reducer" {
      store.send(.cancelWork)
    } else {
      await store.cancelEffects(identifiedBy: workID)
    }
    gate.release(1)
    await dispatch.finish()

    #expect(gate.hasStarted(2) == false)
    #expect(store.state.log.isEmpty)
    #expect(cancellationRecorded(for: 0, in: diagnostics))
  }

  @Test("Control: an own cancel after its own work completed records nothing")
  func ownCancelAfterCompletedWorkRecordsNothing() async {
    let diagnostics = StoreDiagnostics(capacity: 64)
    let store = Store(
      reducer: DeclaredWorkFeature(gate: EmissionGate()), initialState: .init(),
      diagnostics: diagnostics)

    await store.send(.ownCancelAfterOwnWork).finish()

    #expect(store.state.marks == 1)
    #expect(diagnostics.snapshot().records.contains { $0.kind == .cancellationRequested } == false)
  }

  // MARK: Lane requests the reduction turn passes

  @Test(
    "A cancel behind a lane request the lane does not admit is accepted in the reduction turn",
    arguments: LaneThenCancelFeature.Trigger.allCases)
  fileprivate func cancelBehindRejectedLaneRequest(trigger: LaneThenCancelFeature.Trigger) async {
    let gate = EmissionGate()
    let workCancellations = CancellationCounter()
    let store = Store(
      reducer: LaneThenCancelFeature(gate: gate, workCancellations: workCancellations),
      initialState: .init())

    switch trigger {
    case .busyDropLane, .conflictingPolicy, .admittedRequest:
      store.send(.occupyDropLane)
      await waitUntil { gate.hasStarted(10) }
    case .fullSerialQueue:
      store.send(.occupySerialLane)
      await waitUntil { gate.hasStarted(10) }
    case .laneCancelledByOwnTree:
      break
    }
    let work = store.send(.startWork)
    await waitUntil { gate.hasStarted(20) }

    let triggered = store.send(.trigger(trigger))
    // Nothing has suspended since `send` returned: a cancellation accepted in
    // the reduction turn has already run the work's cancellation handler.
    let cancelledInTurn = workCancellations.value

    for index in [10, 20, 31] { gate.release(index) }
    await work.finish()
    await triggered.finish()
    if trigger == .admittedRequest {
      #expect(cancelledInTurn == 0, "an admitted request's run is awaited")
    } else {
      #expect(cancelledInTurn == 1)
      #expect(gate.hasStarted(30) == false)
    }
  }

  @Test("A lane request the reduction turn passes keeps the admission of that turn")
  func laneRequestKeepsTheAdmissionOfItsTurn() async {
    let gate = EmissionGate()
    let store = Store(
      reducer: LaneThenCancelFeature(gate: gate, workCancellations: CancellationCounter()),
      initialState: .init())

    let running = store.send(.openLatestUnderOwner)
    await waitUntil { gate.hasStarted(10) }

    // One MainActor turn: the drop request meets the open `latest` lane in
    // its reduction turn, then that lane closes before the interpreter runs.
    let dispatch = store.send(.dropRequestThenCancel)
    await store.cancelEffects(identifiedBy: otherID)
    #expect(store.runLaneSnapshots().isEmpty)

    await dispatch.finish()
    #expect(store.state.admissions == [.rejected(.conflictingPolicy)])
    #expect(gate.hasStarted(30) == false)

    gate.release(10)
    await running.finish()
  }
}
