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

private let mergeLaneID = EffectID<String>("reducer-cancellation-acceptance-merge-lane")
private let mergeOwnerID = EffectID<String>("reducer-cancellation-acceptance-merge-owner")

/// The admissions lane requests receive, recorded when admission reports
/// them rather than when their admission action is reduced.
private final class AdmissionRecorder: Sendable {
  private let admissions = OSAllocatedUnfairLock(initialState: [Int: EffectAdmission]())

  func record(_ admission: EffectAdmission, for request: Int) {
    admissions.withLock { $0[request] = admission }
  }

  subscript(request: Int) -> EffectAdmission? {
    admissions.withLock { $0[request] }
  }
}

/// Lane requests in the branches of one `merge`, which the interpreter runs
/// in any order. Earlier work counts its cancellations, so a test reads what
/// the reduction turn accepted the moment `send` returns.
private struct MergeOrderFeature: Reducer {
  enum Shape: String, Sendable, CaseIterable {
    /// `merge(a, concatenate(b, .cancel(workID)))`: `a` and `b` are drop
    /// requests for one closed lane, and the interpreter reaches `a` late.
    case sameLaneThenCancel
    /// `merge(a in .cancellable(owner), concatenate(.cancel(owner), b))`:
    /// drop requests for one closed lane, `a` reached late.
    case siblingCancelsRequest
    /// `merge(latest, serial)` for one closed lane.
    case latestThenSerial
    /// `merge(serial, latest)` for one closed lane.
    case serialThenLatest
    /// `merge(latest, concatenate(hold, serial))`: the serial request lies
    /// behind asynchronous work in its branch.
    case latestThenHeldSerial
  }

  struct State: Equatable, Sendable {
    var loading = 0
  }

  enum Action: Sendable {
    /// Work the turn may release: under `workID`, or under the lane's ID.
    case startWork(underLane: Bool)
    case trigger(Shape)
    /// The common pattern: `merge(.send(.loading), latest request)`.
    case load
    /// `concatenate(.send(.loading), latest request)`.
    case loadConcatenated
    /// A request with another policy for the lane.
    case otherPolicy
    /// Request `4` opens the lane with `policy`, under the owner ID when
    /// asked.
    case occupy(EffectExecutionPolicy, underOwner: Bool)
    /// Request `5` queues behind request `4`, under the owner ID.
    case queueUnderOwner
    /// `merge(concatenate(request 6 with the policy, .cancel(workID)),
    /// .cancel(owner))`, or the same branches the other way round.
    case cancelHolder(EffectExecutionPolicy, ownerFirst: Bool)
    /// `merge(.send(.loading), latest request)`, the request under the owner
    /// ID.
    case loadUnderOwner
    case loading
    case pad
    case admission
  }

  /// Request `1` is the merge's first lane request (`a`, or the `latest`
  /// one), request `2` its second; `3` holds the serial request back.
  /// Requests `4` and `5` hold the lane that request `6` meets.
  let gate: EmissionGate
  let workCancellations: CancellationCounter
  let admissions: AdmissionRecorder

  func request(_ index: Int, _ policy: EffectExecutionPolicy) -> EffectTask<Action> {
    let gate = gate
    let admissions = admissions
    return .run(
      id: mergeLaneID, policy: policy,
      onAdmission: { admission in
        admissions.record(admission, for: index)
        return .admission
      },
      { _, _ in
        gate.markStarted(index)
        await gate.waitUntilReleased(index)
      }
    )
  }

  /// `effect` behind three nested merges, so the interpreter reaches it after
  /// the other branch of an enclosing merge.
  func late(_ effect: EffectTask<Action>) -> EffectTask<Action> {
    var padded = effect
    for _ in 0..<3 {
      padded = .merge(padded, .send(.pad))
    }
    return padded
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    let gate = gate
    let workCancellations = workCancellations
    switch action {
    case .startWork(let underLane):
      return EffectTask<Action>.run { _ in
        await withTaskCancellationHandler {
          gate.markStarted(20)
          await gate.waitUntilReleased(20)
        } onCancel: {
          workCancellations.increment()
        }
      }
      .cancellable(underLane ? mergeLaneID : workID)

    case .trigger(.sameLaneThenCancel):
      return .merge(
        late(request(1, .dropWhileRunning)),
        .concatenate(request(2, .dropWhileRunning), .cancel(workID)))

    case .trigger(.siblingCancelsRequest):
      return .merge(
        late(request(1, .dropWhileRunning).cancellable(mergeOwnerID)),
        .concatenate(.cancel(mergeOwnerID), request(2, .dropWhileRunning)))

    case .trigger(.latestThenSerial):
      return .merge(request(1, .latest), request(2, .serial(maxPending: 4)))

    case .trigger(.serialThenLatest):
      return .merge(request(2, .serial(maxPending: 4)), request(1, .latest))

    case .trigger(.latestThenHeldSerial):
      let hold = EffectTask<Action>.run { _ in
        gate.markStarted(3)
        await gate.waitUntilReleased(3)
      }
      return .merge(request(1, .latest), .concatenate(hold, request(2, .serial(maxPending: 4))))

    case .load:
      return .merge(.send(.loading), request(1, .latest))

    case .loadConcatenated:
      return .concatenate(.send(.loading), request(1, .latest))

    case .loadUnderOwner:
      return .merge(.send(.loading), request(1, .latest).cancellable(mergeOwnerID))

    case .otherPolicy:
      return request(2, .dropWhileRunning)

    case .occupy(let policy, let underOwner):
      let occupying = request(4, policy)
      return underOwner ? occupying.cancellable(mergeOwnerID) : occupying

    case .queueUnderOwner:
      return request(5, .serial(maxPending: 1)).cancellable(mergeOwnerID)

    case .cancelHolder(let policy, let ownerFirst):
      let requestThenCancel = EffectTask<Action>.concatenate(request(6, policy), .cancel(workID))
      return ownerFirst
        ? .merge(.cancel(mergeOwnerID), requestThenCancel)
        : .merge(requestThenCancel, .cancel(mergeOwnerID))

    case .loading:
      state.loading += 1
      return .none

    case .pad, .admission:
      return .none
    }
  }
}

/// Records what the reduction-turn pass accepts and decides, against lanes
/// a test sets up, without interpreting anything.
@MainActor
private final class TurnPassRecorder: ReductionTurnCancellationAcceptor {
  typealias Action = MergeOrderFeature.Action
  typealias Output = Never

  var lanes: [AnyEffectID: EffectRunLaneView] = [:]
  private(set) var accepted: [EffectCancellationRequest] = []
  private(set) var replacedLanes: [AnyEffectID] = []

  func acceptInReductionTurn(
    _ request: EffectCancellationRequest, context: EffectExecutionContext
  ) {
    accepted.append(request)
  }

  func runLane(for id: AnyEffectID) -> EffectRunLaneView? {
    lanes[id]
  }

  func acceptLatestReplacementInReductionTurn(id: AnyEffectID, context: EffectExecutionContext) {
    replacedLanes.append(id)
  }

  /// Runs the pass over `effect`, then returns every admission it recorded
  /// for a request with `cancellationIDs` and `policy`, oldest first, and
  /// then those for a request with `otherCancellationIDs`.
  func pass(
    _ effect: EffectTask<Action>,
    recordedFor cancellationIDs: [AnyEffectID],
    and otherCancellationIDs: [AnyEffectID]? = nil,
    policy: EffectExecutionPolicy.Kind
  ) -> [ReductionTurnLaneAdmission] {
    let boundaries = EffectCancellationBoundaries()
    let context = boundaries.makeContext(
      sequence: boundaries.nextSequence(),
      potentialCancellationIDs: effect.potentialCancellationIDs)
    acceptSynchronousCancellations(in: effect, context: context)
    var recorded: [ReductionTurnLaneAdmission] = []
    for cancellationIDs in [cancellationIDs, otherCancellationIDs].compactMap({ $0 }) {
      while let admission = context.cancellationScope?.consumeTurnLaneAdmission(
        cancellationIDs: cancellationIDs, policy: policy)
      {
        recorded.append(admission)
      }
    }
    return recorded
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

  // MARK: Merge branches the interpreter runs in any order

  private func mergeOrderFeature() -> MergeOrderFeature {
    MergeOrderFeature(
      gate: EmissionGate(), workCancellations: CancellationCounter(),
      admissions: AdmissionRecorder())
  }

  private func effect(
    _ action: MergeOrderFeature.Action, of feature: MergeOrderFeature
  ) -> EffectTask<MergeOrderFeature.Action> {
    var state = MergeOrderFeature.State()
    return feature.reduce(into: &state, action: action)
  }

  @Test(
    "The reduction turn decides no lane request another merge branch can reorder",
    arguments: [false, true])
  func passDecidesNoOrderDependentLaneRequest(laneIsBusy: Bool) {
    let feature = mergeOrderFeature()
    let lane = AnyEffectID(mergeLaneID)
    let busyLane = EffectRunLaneView(policy: .dropWhileRunning, holderSequence: 0, pendingCount: 0)

    // Two requests for one lane: whichever the interpreter reaches first
    // decides the other's admission, so the turn decides neither, and
    // accepts nothing behind them.
    let sameLane = TurnPassRecorder()
    sameLane.lanes = laneIsBusy ? [lane: busyLane] : [:]
    let sameLaneEffect = effect(.trigger(.sameLaneThenCancel), of: feature)
    #expect(sameLane.pass(sameLaneEffect, recordedFor: [lane], policy: .dropWhileRunning).isEmpty)
    #expect(sameLane.accepted.isEmpty)

    // A request whose ID another branch cancels may be skipped or admitted.
    // Request `a` is under the owner ID, request `b` under the lane's alone.
    let ownerCancelled = TurnPassRecorder()
    ownerCancelled.lanes = laneIsBusy ? [lane: busyLane] : [:]
    let ownerEffect = effect(.trigger(.siblingCancelsRequest), of: feature)
    #expect(
      ownerCancelled.pass(
        ownerEffect, recordedFor: [lane], and: [AnyEffectID(mergeOwnerID), lane],
        policy: .dropWhileRunning
      ).isEmpty)
    #expect(ownerCancelled.accepted == [.all(AnyEffectID(mergeOwnerID))])
  }

  @Test(
    "The reduction turn decides no lane request whose lane another merge branch can change",
    arguments: [false, true])
  func passDecidesNoRequestWhoseLaneASiblingCanChange(ownerFirst: Bool) {
    let lane = AnyEffectID(mergeLaneID)
    let owner = AnyEffectID(mergeOwnerID)
    let cancelHolder = effect(
      .cancelHolder(.serial(maxPending: 1), ownerFirst: ownerFirst), of: mergeOrderFeature())

    // A full serial lane whose pending request is under the owner ID: the
    // other branch's cancel frees its slot, so the lane rejects the request
    // or queues it depending on which branch the interpreter runs first.
    // The recorder's lanes do not change when it accepts a cancellation.
    let fullSerialLane = TurnPassRecorder()
    fullSerialLane.lanes = [
      lane: EffectRunLaneView(
        policy: .serial(maxPending: 1), holderSequence: 0, pendingCount: 1,
        pendingCancellationIDs: [[owner]])
    ]
    #expect(
      fullSerialLane.pass(cancelHolder, recordedFor: [lane], policy: .serial(maxPending: 1))
        .isEmpty)
    #expect(fullSerialLane.accepted == [.all(owner)])

    // A `latest` lane whose running request is under the owner ID: the
    // cancel closes the lane, so the request meets a conflicting lane or
    // none.
    let latestLane = TurnPassRecorder()
    latestLane.lanes = [
      lane: EffectRunLaneView(
        policy: .latest, holderSequence: 0, pendingCount: 0, ownerCancellationIDs: [owner])
    ]
    #expect(
      latestLane.pass(cancelHolder, recordedFor: [lane], policy: .serial(maxPending: 1)).isEmpty)
    #expect(latestLane.accepted == [.all(owner)])
  }

  @Test(
    "The reduction turn decides a lane request its lane answers alike without the cancelled holder",
    arguments: [false, true])
  func passDecidesRequestItsLaneAnswersAlike(ownerFirst: Bool) {
    let lane = AnyEffectID(mergeLaneID)
    let owner = AnyEffectID(mergeOwnerID)
    let feature = mergeOrderFeature()

    // A `latest` request replaces a `latest` lane whose running request is
    // under the owner ID, and opens the lane once the other branch's cancel
    // has closed it: it is admitted either way, so the turn accepts it.
    let latestLane = TurnPassRecorder()
    latestLane.lanes = [
      lane: EffectRunLaneView(
        policy: .latest, holderSequence: 0, pendingCount: 0, ownerCancellationIDs: [owner])
    ]
    let latestRequest = effect(.cancelHolder(.latest, ownerFirst: ownerFirst), of: feature)
    #expect(latestLane.pass(latestRequest, recordedFor: [lane], policy: .latest) == [.admitted])
    #expect(latestLane.replacedLanes == [lane])
    #expect(latestLane.accepted == [.all(owner)])

    // A drop request meets a serial lane as conflicting, with or without the
    // pending request under the owner ID: it is rejected either way, so the
    // cancel behind it is accepted in the turn.
    let serialLane = TurnPassRecorder()
    serialLane.lanes = [
      lane: EffectRunLaneView(
        policy: .serial(maxPending: 1), holderSequence: 0, pendingCount: 1,
        pendingCancellationIDs: [[owner]])
    ]
    let dropRequest = effect(.cancelHolder(.dropWhileRunning, ownerFirst: ownerFirst), of: feature)
    #expect(
      serialLane.pass(dropRequest, recordedFor: [lane], policy: .dropWhileRunning)
        == [.completed(.rejected(.conflictingPolicy))])
    #expect(Set(serialLane.accepted) == [.all(AnyEffectID(workID)), .all(owner)])
  }

  @Test(
    "The reduction turn accepts no latest request another merge branch can reject",
    arguments: [
      MergeOrderFeature.Shape.latestThenSerial, .serialThenLatest, .latestThenHeldSerial,
    ])
  fileprivate func passAcceptsNoOrderDependentLatestRequest(shape: MergeOrderFeature.Shape) {
    let lane = AnyEffectID(mergeLaneID)
    let recorder = TurnPassRecorder()
    let latest = recorder.pass(
      effect(.trigger(shape), of: mergeOrderFeature()), recordedFor: [lane], policy: .latest)

    #expect(latest.isEmpty)
    #expect(recorder.replacedLanes.isEmpty)
    #expect(recorder.accepted.isEmpty)
  }

  @Test("The reduction turn still decides a latest request merged with work on no lane")
  func passAcceptsLatestRequestMergedWithSend() {
    let lane = AnyEffectID(mergeLaneID)
    let recorder = TurnPassRecorder()
    let latest = recorder.pass(
      effect(.load, of: mergeOrderFeature()), recordedFor: [lane], policy: .latest)

    #expect(latest == [.admitted])
    #expect(recorder.replacedLanes == [lane])
  }

  @Test("The reduction turn still decides a request whose merge siblings touch other IDs")
  func passDecidesRequestWhoseSiblingsTouchOtherIDs() {
    typealias Action = MergeOrderFeature.Action
    let lane = AnyEffectID(mergeLaneID)
    let recorder = TurnPassRecorder()
    recorder.lanes = [
      lane: EffectRunLaneView(policy: .dropWhileRunning, holderSequence: 0, pendingCount: 0)
    ]
    let feature = mergeOrderFeature()
    let rejectedThenCancel = EffectTask<Action>.merge(
      .concatenate(feature.request(1, .dropWhileRunning), .cancel(workID)),
      .cancel(mergeOwnerID))

    let recorded = recorder.pass(rejectedThenCancel, recordedFor: [lane], policy: .dropWhileRunning)

    #expect(recorded == [.completed(.rejected(.busy))])
    #expect(recorder.accepted == [.all(AnyEffectID(workID)), .all(AnyEffectID(mergeOwnerID))])
  }

  @Test(
    "The reduction turn accepts nothing that another merge branch's cancel may skip",
    arguments: [false, true])
  func passAcceptsNothingASiblingCancelMaySkip(cancelFirst: Bool) {
    typealias Action = MergeOrderFeature.Action
    let recorder = TurnPassRecorder()
    // Work under the owner ID awaits or is skipped depending on whether the
    // interpreter reaches the other branch's cancel first, so the cancel of
    // `workID` behind or inside it is not reached in every order.
    let ownedWork: EffectTask<Action>
    if cancelFirst {
      ownedWork = .concatenate(
        EffectTask<Action>.run { _ in }.cancellable(mergeOwnerID), .cancel(workID))
    } else {
      ownedWork = EffectTask<Action>.concatenate(.send(.pad), .cancel(workID))
        .cancellable(mergeOwnerID)
    }
    let effect: EffectTask<Action> =
      cancelFirst
      ? .merge(.cancel(mergeOwnerID), ownedWork) : .merge(ownedWork, .cancel(mergeOwnerID))

    _ = recorder.pass(effect, recordedFor: [], policy: .latest)

    #expect(recorder.accepted == [.all(AnyEffectID(mergeOwnerID))])
  }

  @Test(
    "A lane request another merge branch can reorder is decided by its admission alone",
    arguments: MergeOrderFeature.Shape.allCases)
  fileprivate func orderDependentLaneRequestIsDecidedByAdmission(
    shape: MergeOrderFeature.Shape
  ) async {
    let gate = EmissionGate()
    let workCancellations = CancellationCounter()
    let admissions = AdmissionRecorder()
    let store = Store(
      reducer: MergeOrderFeature(
        gate: gate, workCancellations: workCancellations, admissions: admissions),
      initialState: .init())
    let workUnderLane = shape != .sameLaneThenCancel && shape != .siblingCancelsRequest

    let work = store.send(.startWork(underLane: workUnderLane))
    await waitUntil { gate.hasStarted(20) }

    let dispatch = store.send(.trigger(shape))
    // Nothing has suspended since `send` returned: the turn released nothing
    // that the order of the merge's branches decides.
    #expect(workCancellations.value == 0)

    // Every outcome below is one the interpreter reaches in some order of
    // the merge's branches.
    switch shape {
    case .sameLaneThenCancel:
      await waitUntil { admissions[1] != nil && admissions[2] != nil }
      // One request opened the lane and the other met it busy. The cancel
      // behind `b` runs once `b` completes: at once when the lane rejected
      // `b`, only after its run when it started.
      let secondStarted = admissions[2] == .started
      #expect([admissions[1], admissions[2]].filter { $0 == .started }.count == 1)
      #expect(workCancellations.value == (secondStarted ? 0 : 1))

    case .siblingCancelsRequest:
      await waitUntil { admissions[2] != nil }
      // `b` meets the lane `a` opened, or a closed lane when the own cancel
      // skipped `a` first.
      #expect(
        admissions[2] == .started
          || (admissions[1] == .started && admissions[2] == .rejected(.busy)))

    case .latestThenSerial, .serialThenLatest:
      await waitUntil { admissions[1] != nil && admissions[2] != nil }
      let latestStarted = admissions[1] == .started
      #expect(admissions[latestStarted ? 2 : 1] == .rejected(.conflictingPolicy))
      #expect(latestStarted || admissions[2] == .started)
      // Only an admitted latest request releases earlier work under its ID.
      #expect(workCancellations.value == (latestStarted ? 1 : 0))

    case .latestThenHeldSerial:
      await waitUntil { admissions[1] != nil }
      #expect(admissions[1] == .started)
      #expect(workCancellations.value == 1)
      gate.release(3)
      await waitUntil { admissions[2] != nil }
      #expect(admissions[2] == .rejected(.conflictingPolicy))
    }

    for index in [1, 2, 3, 20] { gate.release(index) }
    await dispatch.finish()
    await work.finish()
  }

  @Test("A latest request merged with a send is still accepted in its reduction turn")
  func latestRequestMergedWithSendIsAcceptedInTheTurn() async {
    let gate = EmissionGate()
    let workCancellations = CancellationCounter()
    let admissions = AdmissionRecorder()
    let store = Store(
      reducer: MergeOrderFeature(
        gate: gate, workCancellations: workCancellations, admissions: admissions),
      initialState: .init())

    let work = store.send(.startWork(underLane: true))
    await waitUntil { gate.hasStarted(20) }

    let dispatch = store.send(.load)
    // The earlier work under the lane's ID was released in the turn.
    #expect(workCancellations.value == 1)

    await waitUntil { admissions[1] != nil }
    #expect(admissions[1] == .started)
    gate.release(1)
    gate.release(20)
    await dispatch.finish()
    await work.finish()
    #expect(store.state.loading == 1)
  }

  @Test(
    "A latest request accepted for a closed lane holds the lane until it is admitted",
    arguments: [false, true])
  func latestRequestAcceptedForClosedLaneHoldsItsLane(concatenated: Bool) async {
    let gate = EmissionGate()
    let workCancellations = CancellationCounter()
    let admissions = AdmissionRecorder()
    let store = Store(
      reducer: MergeOrderFeature(
        gate: gate, workCancellations: workCancellations, admissions: admissions),
      initialState: .init())

    let work = store.send(.startWork(underLane: true))
    await waitUntil { gate.hasStarted(20) }

    // One MainActor turn: the `latest` request is accepted while no lane is
    // open, and a request with another policy follows before either effect
    // is interpreted. The root walk of that request reaches admission before
    // the composite that contains the `latest` request.
    let latest = store.send(concatenated ? .loadConcatenated : .load)
    #expect(workCancellations.value == 1)
    let other = store.send(.otherPolicy)

    #expect(await waitUntil { admissions[1] != nil && admissions[2] != nil })
    // The request that released the earlier work replaces it.
    #expect(admissions[1] == .started)
    #expect(admissions[2] == .rejected(.conflictingPolicy))

    // Request 2 runs only when the lane was not held; its gate is released
    // too, so such a run fails instead of waiting for it.
    for index in [1, 2, 20] { gate.release(index) }
    await latest.finish()
    await other.finish()
    await work.finish()
    #expect(gate.hasStarted(2) == false)
  }

  @Test("A lane held for a latest request whose dispatch is cancelled is closed")
  func laneHeldForCancelledLatestRequestIsClosed() async {
    let gate = EmissionGate()
    let admissions = AdmissionRecorder()
    let store = Store(
      reducer: MergeOrderFeature(
        gate: gate, workCancellations: CancellationCounter(), admissions: admissions),
      initialState: .init())

    // One MainActor turn: the accepted request's dispatch is cancelled before
    // its effect is interpreted, so the lane it held is closed again. Without
    // a held lane the request with another policy opens the lane as well:
    // this test guards the release of a held lane, not the hold.
    let latest = store.send(.load)
    latest.cancel()
    let other = store.send(.otherPolicy)

    #expect(await waitUntil { admissions[2] != nil })
    #expect(admissions[2] == .started)
    #expect(admissions[1] == nil)

    gate.release(2)
    await latest.finish()
    await other.finish()
    // The closed lane kept nothing of the cancelled request alive.
    #expect(await waitUntil { store.effectBridge.cancellationScopeMetrics.liveScopes == 0 })
  }

  @Test(
    "A latest request is accepted in its turn whichever merge branch cancels its lane's owner",
    arguments: [false, true])
  func latestRequestAcceptedWhicheverBranchCancelsItsLaneOwner(ownerFirst: Bool) async {
    let gate = EmissionGate()
    let admissions = AdmissionRecorder()
    let store = Store(
      reducer: MergeOrderFeature(
        gate: gate, workCancellations: CancellationCounter(), admissions: admissions),
      initialState: .init())

    // The running request of the `latest` lane is under the owner ID.
    let running = store.send(.occupy(.latest, underOwner: true))
    #expect(await waitUntil { gate.hasStarted(4) })

    // One MainActor turn: the `latest` request meets the lane while another
    // branch cancels the request that owns it. The lane admits the request
    // either way, so the turn accepts it and holds the lane for it, and the
    // request with another policy that follows meets a conflicting lane.
    let dispatch = store.send(.cancelHolder(.latest, ownerFirst: ownerFirst))
    let other = store.send(.otherPolicy)

    #expect(await waitUntil { admissions[6] != nil && admissions[2] != nil })
    #expect(admissions[6] == .started)
    #expect(admissions[2] == .rejected(.conflictingPolicy))

    for index in [2, 4, 6] { gate.release(index) }
    await dispatch.finish()
    await other.finish()
    await running.finish()
  }

  @Test(
    "A lane request meets the same lane whichever merge branch cancels the request it is held for",
    arguments: [false, true])
  func laneRequestIgnoresBranchOrderOfHeldRequestCancel(ownerFirst: Bool) async {
    let gate = EmissionGate()
    let workCancellations = CancellationCounter()
    let admissions = AdmissionRecorder()
    let store = Store(
      reducer: MergeOrderFeature(
        gate: gate, workCancellations: workCancellations, admissions: admissions),
      initialState: .init())

    let work = store.send(.startWork(underLane: false))
    #expect(await waitUntil { gate.hasStarted(20) })

    // One MainActor turn: the first dispatch's `latest` request, under the
    // owner ID, is accepted for the closed lane, which is held for it. The
    // second dispatch's drop request meets that held lane while another
    // branch cancels the owner ID, which closes it.
    let held = store.send(.loadUnderOwner)
    let dispatch = store.send(.cancelHolder(.dropWhileRunning, ownerFirst: ownerFirst))
    // The lane rejects the drop request while it is held and admits it once
    // it is closed, so the turn accepted nothing behind the request: the
    // cancel behind it waits for its run, in either order of the branches.
    #expect(workCancellations.value == 0)

    #expect(await waitUntil { admissions[6] != nil })
    #expect(admissions[6] == .started)
    #expect(workCancellations.value == 0)
    gate.release(6)
    await dispatch.finish()
    #expect(workCancellations.value == 1)

    for index in [1, 20] { gate.release(index) }
    await held.finish()
    await work.finish()
    // The held request was cancelled before its admission.
    #expect(gate.hasStarted(1) == false)
  }

  @Test(
    "A lane request meets the same lane whichever merge branch cancels a request holding it",
    arguments: [false, true], [false, true])
  func laneRequestIgnoresBranchOrderOfHolderCancel(latestLane: Bool, ownerFirst: Bool) async {
    let gate = EmissionGate()
    let workCancellations = CancellationCounter()
    let admissions = AdmissionRecorder()
    let store = Store(
      reducer: MergeOrderFeature(
        gate: gate, workCancellations: workCancellations, admissions: admissions),
      initialState: .init())

    // The request under the owner ID holds the lane: the running request of
    // a `latest` lane, or the pending request that fills a serial lane.
    let running = store.send(
      .occupy(latestLane ? .latest : .serial(maxPending: 1), underOwner: latestLane))
    #expect(await waitUntil { gate.hasStarted(4) })
    let pending = latestLane ? nil : store.send(.queueUnderOwner)
    if !latestLane {
      #expect(await waitUntil { admissions[5] == .queued(position: 1) })
    }
    let work = store.send(.startWork(underLane: false))
    #expect(await waitUntil { gate.hasStarted(20) })

    let dispatch = store.send(.cancelHolder(.serial(maxPending: 1), ownerFirst: ownerFirst))
    // Nothing has suspended since `send` returned. The turn cancelled the
    // owner ID, which changes the lane: before that cancel the lane rejects
    // the serial request, after it the lane admits it. In either order of
    // the branches the turn accepted nothing behind the request: the request
    // is admitted, and the cancel behind it waits for its run.
    #expect(workCancellations.value == 0)
    if latestLane {
      #expect(store.runLaneSnapshots().isEmpty)
    } else {
      #expect(store.runLaneSnapshots().first?.pendingRequestCount == 0)
    }

    #expect(await waitUntil { admissions[6] != nil })
    #expect(admissions[6] == (latestLane ? .started : .queued(position: 1)))
    #expect(workCancellations.value == 0)

    // The cancel behind the request runs once the request's run completes.
    gate.release(4)
    #expect(await waitUntil { gate.hasStarted(6) })
    gate.release(6)
    await dispatch.finish()
    #expect(workCancellations.value == 1)

    for index in [5, 20] { gate.release(index) }
    await running.finish()
    await pending?.finish()
    await work.finish()
  }

  // MARK: Throttle requests cancelled during their clock read

  @Test(
    "A throttle request cancelled during its clock read records the cancellation",
    arguments: [false, true])
  func throttleCancelledDuringClockReadRecordsCancellation(throughOwnerID: Bool) async {
    let gate = EmissionGate()
    let clock = ParkedClockRead(gate: gate)
    let diagnostics = StoreDiagnostics(capacity: 64)
    let store = Store(
      reducer: ClockReadThrottleFeature(), initialState: .init(), clock: clock.storeClock,
      diagnostics: diagnostics)

    clock.parkNextRead()
    let dispatch = store.send(.request(owned: throughOwnerID))
    // The root interpreter is suspended in the throttle's clock read: the
    // request is declared, but registered nowhere yet.
    await waitUntil { gate.hasStarted(ParkedClockRead.index) }
    await store.cancelEffects(identifiedBy: throughOwnerID ? throttleOwnerID : throttleWindowID)
    gate.release(ParkedClockRead.index)
    await dispatch.finish()

    #expect(store.state.fired == 0)
    #expect(cancellationRecorded(for: 0, in: diagnostics))
  }

  @Test("Control: a throttle request nothing cancels during its clock read records nothing")
  func throttleNotCancelledDuringClockReadRecordsNothing() async {
    let gate = EmissionGate()
    let clock = ParkedClockRead(gate: gate)
    let diagnostics = StoreDiagnostics(capacity: 64)
    let store = Store(
      reducer: ClockReadThrottleFeature(), initialState: .init(), clock: clock.storeClock,
      diagnostics: diagnostics)

    clock.parkNextRead()
    let dispatch = store.send(.request(owned: true))
    await waitUntil { gate.hasStarted(ParkedClockRead.index) }
    gate.release(ParkedClockRead.index)
    await dispatch.finish()

    #expect(store.state.fired == 1)
    #expect(cancellationRecorded(for: 0, in: diagnostics) == false)
  }
}

private let throttleWindowID = EffectID<String>("reducer-cancellation-acceptance-throttle")
private let throttleOwnerID = EffectID<String>("reducer-cancellation-acceptance-throttle-owner")

/// A store clock whose next `now` read, once armed, waits on `gate` at
/// ``index``.
private final class ParkedClockRead: Sendable {
  static let index = 77

  private let gate: EmissionGate
  private let isArmed = OSAllocatedUnfairLock(initialState: false)

  init(gate: EmissionGate) {
    self.gate = gate
  }

  func parkNextRead() {
    isArmed.withLock { $0 = true }
  }

  var storeClock: StoreClock {
    StoreClock(
      now: { [self] in
        let parks = isArmed.withLock { isArmed -> Bool in
          defer { isArmed = false }
          return isArmed
        }
        if parks {
          gate.markStarted(Self.index)
          await gate.waitUntilReleased(Self.index)
        }
        return ContinuousClock.now
      },
      sleep: { duration in try await Task.sleep(for: duration) }
    )
  }
}

/// A leading throttle request, optionally inside `.cancellable(owner)`.
private struct ClockReadThrottleFeature: Reducer {
  struct State: Equatable, Sendable {
    var fired = 0
  }

  enum Action: Sendable {
    case request(owned: Bool)
    case fired
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .request(let owned):
      let throttled = EffectTask<Action>.send(.fired)
        .throttle(throttleWindowID, for: .milliseconds(30), leading: true, trailing: false)
      return owned ? throttled.cancellable(throttleOwnerID) : throttled

    case .fired:
      state.fired += 1
      return .none
    }
  }
}
