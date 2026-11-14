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
}
