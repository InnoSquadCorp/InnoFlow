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
}
