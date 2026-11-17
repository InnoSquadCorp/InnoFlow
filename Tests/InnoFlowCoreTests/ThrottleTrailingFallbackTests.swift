// MARK: - ThrottleTrailingFallbackTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import InnoFlowCore
import Testing
import os

@testable import InnoFlowCoreTestSupport

// A throttle window fires the newest trailing request that can still
// proceed. Cancelling the newest request's dispatch must give the window
// back to the request it replaced: a dispatch's cancellation affects only
// that dispatch, and the outcome must not depend on whether the cancelled
// dispatch's effect had already been interpreted.

private let windowID = EffectID<String>("throttle-trailing-fallback")
private let olderOwnerID = EffectID<String>("throttle-trailing-fallback-older")
private let newestOwnerID = EffectID<String>("throttle-trailing-fallback-newest")

private struct TrailingFeature: Reducer {
  struct State: Equatable, Sendable {
    var fired: [String] = []
  }

  enum Action: Sendable {
    case request(String)
    /// A request inside `.cancellable(owner)`: the owner ID covers only it.
    case requestOwned(String, by: EffectID<String>)
    case cancel(EffectID<String>)
    case fired(String)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .request(let tag):
      return EffectTask<Action>.send(.fired(tag))
        .throttle(windowID, for: .seconds(1), leading: true, trailing: true)

    case .requestOwned(let tag, let owner):
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

/// Parks trailing runs until a test releases them, ignoring cancellation.
private final class TrailingRunGate: Sendable {
  private struct State {
    var started: Set<String> = []
    var released: Set<String> = []
    var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  func hasStarted(_ tag: String) -> Bool {
    state.withLock { $0.started.contains(tag) }
  }

  func release(_ tag: String) {
    let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
      state.released.insert(tag)
      return state.waiters.removeValue(forKey: tag) ?? []
    }
    for waiter in waiters {
      waiter.resume()
    }
  }

  func run(_ tag: String) async {
    await withCheckedContinuation { continuation in
      let isReleased = state.withLock { state -> Bool in
        state.started.insert(tag)
        guard !state.released.contains(tag) else { return true }
        state.waiters[tag, default: []].append(continuation)
        return false
      }
      if isReleased {
        continuation.resume()
      }
    }
  }
}

/// Trailing-only requests whose trailing effect is a run that parks, some
/// awaited inside a concatenation.
private struct AwaitedTrailingFeature: Reducer {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: Sendable {
    /// `concatenate(throttled(tag), .send(.after(tag)))`, all inside
    /// `.cancellable(owner)`.
    case awaitedOwnedConcatenation(String, by: EffectID<String>)
    /// `concatenate(throttled(tag).cancellable(owner), .send(.after(tag)))`:
    /// the owner ID covers only the throttle request.
    case awaitedOwnedRequest(String, by: EffectID<String>)
    /// `throttled(tag).cancellable(owner)`, not awaited.
    case ownedRequest(String, by: EffectID<String>)
    case ran(String)
    case after(String)
  }

  let gate: TrailingRunGate

  private func throttled(_ tag: String) -> EffectTask<Action> {
    let gate = gate
    return EffectTask<Action>.run { send in
      await gate.run(tag)
      await send(.ran(tag))
    }
    .throttle(windowID, for: .seconds(1), leading: false, trailing: true)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .awaitedOwnedConcatenation(let tag, let owner):
      return EffectTask<Action>.concatenate(throttled(tag), .send(.after(tag))).cancellable(owner)

    case .awaitedOwnedRequest(let tag, let owner):
      return .concatenate(throttled(tag).cancellable(owner), .send(.after(tag)))

    case .ownedRequest(let tag, let owner):
      return throttled(tag).cancellable(owner)

    case .ran(let tag):
      state.log.append("ran-\(tag)")
      return .none

    case .after(let tag):
      state.log.append("after-\(tag)")
      return .none
    }
  }
}

/// A store clock whose time stands still and whose sleeps end on demand, so
/// every request after the first lands in the open window and the window
/// closes exactly when the test says so.
private final class WindowClock: Sendable {
  private struct State {
    var isClosed = false
    var sleepers = 0
  }

  private let state = OSAllocatedUnfairLock(initialState: State())
  private let origin = ContinuousClock.now

  var storeClock: StoreClock {
    StoreClock(
      now: { [origin] in origin },
      sleep: { [self] _ in
        state.withLock { $0.sleepers += 1 }
        while !state.withLock({ $0.isClosed }) {
          try await Task.sleep(for: .milliseconds(1))
        }
      }
    )
  }

  var hasSleeper: Bool { state.withLock { $0.sleepers > 0 } }

  func closeWindow() { state.withLock { $0.isClosed = true } }
}

@MainActor
@Suite(
  "Throttle trailing falls back to the newest request that can still proceed",
  .timeLimit(.minutes(5)))
struct ThrottleTrailingFallbackTests {
  private func waitUntil(
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @MainActor () -> Bool
  ) async {
    let deadline = ContinuousClock.now.advanced(by: scaledTestDeadline(.seconds(10)))
    while !condition() {
      guard ContinuousClock.now < deadline else {
        Issue.record(
          "The awaited condition was not reached in time", sourceLocation: sourceLocation)
        return
      }
      try? await Task.sleep(for: .milliseconds(2))
    }
  }

  private func pendingSequence<R: Reducer>(_ store: Store<R>) -> UInt64? {
    store.effectBridge.throttleState.pending(for: AnyEffectID(windowID))?.context?.sequence
  }

  /// Sends `action`, whose request lands in the open window, and waits until
  /// the window holds it as its newest trailing request.
  private func sendIntoWindow(
    _ action: AwaitedTrailingFeature.Action, on store: Store<AwaitedTrailingFeature>
  ) async -> FlowTask {
    let previous = pendingSequence(store)
    let task = store.send(action)
    await waitUntil { pendingSequence(store) != previous }
    return task
  }

  /// Sends a request into the open window and waits until the window holds
  /// it as its newest trailing request.
  @discardableResult
  private func requestInWindow(
    _ tag: String, ownedBy owner: EffectID<String>? = nil, on store: Store<TrailingFeature>
  ) async -> FlowTask {
    let previous = pendingSequence(store)
    let task = store.send(owner.map { .requestOwned(tag, by: $0) } ?? .request(tag))
    await waitUntil { pendingSequence(store) != previous }
    return task
  }

  /// Opens a window with `first`, then makes `second` its trailing request.
  private func openWindow(_ store: Store<TrailingFeature>, clock: WindowClock) async {
    store.send(.request("first"))
    await waitUntil { clock.hasSleeper && store.state.fired == ["first"] }
    await requestInWindow("second", on: store)
  }

  @Test("Control: the newest in-window request fires when the window closes")
  func newestRequestFires() async {
    let clock = WindowClock()
    let store = Store(reducer: TrailingFeature(), initialState: .init(), clock: clock.storeClock)
    await openWindow(store, clock: clock)

    await requestInWindow("third", on: store)
    clock.closeWindow()
    await waitUntil { store.state.fired.count == 2 }

    #expect(store.state.fired == ["first", "third"])
  }

  @Test(
    "Cancelling the newest request's dispatch fires the request it replaced",
    arguments: [true, false])
  func cancelledNewestRequestFallsBack(afterItsEffectWasInterpreted: Bool) async {
    let clock = WindowClock()
    let store = Store(reducer: TrailingFeature(), initialState: .init(), clock: clock.storeClock)
    await openWindow(store, clock: clock)

    // The outcome must not depend on whether the cancelled dispatch's effect
    // had already replaced the pending request.
    let third =
      afterItsEffectWasInterpreted
      ? await requestInWindow("third", on: store)
      : store.send(.request("third"))
    third.cancel()
    clock.closeWindow()
    await waitUntil { store.state.fired.count == 2 }

    #expect(store.state.fired == ["first", "second"])
  }

  @Test("A window retains a bounded number of superseded trailing requests")
  func supersededRequestsAreBounded() async {
    let limit = ThrottleStateMap<TrailingFeature.Action, Never>.supersededPendingLimit
    let clock = WindowClock()
    let store = Store(reducer: TrailingFeature(), initialState: .init(), clock: clock.storeClock)
    await openWindow(store, clock: clock)

    // `limit` newer requests push `second` off the retained list.
    var newer: [FlowTask] = []
    for index in 0..<limit {
      newer.append(await requestInWindow("newer-\(index)", on: store))
    }
    for task in newer.dropFirst() {
      task.cancel()
    }
    clock.closeWindow()
    await waitUntil { store.state.fired.count == 2 }

    // The oldest request the window can still fall back to is `newer-0`.
    #expect(store.state.fired == ["first", "newer-0"])
  }

  @Test(
    "Cancelling an ID only the newest request carries fires the request it replaced",
    arguments: [false, true])
  func newestRequestCancelledByItsOwnIDFallsBack(throughReducer: Bool) async {
    let clock = WindowClock()
    let store = Store(reducer: TrailingFeature(), initialState: .init(), clock: clock.storeClock)
    store.send(.request("first"))
    await waitUntil { clock.hasSleeper && store.state.fired == ["first"] }
    await requestInWindow("second", ownedBy: olderOwnerID, on: store)
    await requestInWindow("third", ownedBy: newestOwnerID, on: store)

    if throughReducer {
      store.send(.cancel(newestOwnerID))
    } else {
      await store.cancelEffects(identifiedBy: newestOwnerID)
    }
    clock.closeWindow()
    await waitUntil { store.state.fired.count == 2 }

    #expect(store.state.fired == ["first", "second"])
  }

  @Test("Cancelling an ID only a replaced request carries still fires the newest request")
  func replacedRequestCancelledByItsOwnIDKeepsNewest() async {
    let clock = WindowClock()
    let store = Store(reducer: TrailingFeature(), initialState: .init(), clock: clock.storeClock)
    store.send(.request("first"))
    await waitUntil { clock.hasSleeper && store.state.fired == ["first"] }
    await requestInWindow("second", ownedBy: olderOwnerID, on: store)
    await requestInWindow("third", ownedBy: newestOwnerID, on: store)

    await store.cancelEffects(identifiedBy: olderOwnerID)
    clock.closeWindow()
    await waitUntil { store.state.fired.count == 2 }

    #expect(store.state.fired == ["first", "third"])
  }

  @Test("Cancelling the window's ID resets the window and fires nothing")
  func windowIDCancellationResetsTheWindow() async {
    let clock = WindowClock()
    let store = Store(reducer: TrailingFeature(), initialState: .init(), clock: clock.storeClock)
    store.send(.request("first"))
    await waitUntil { clock.hasSleeper && store.state.fired == ["first"] }
    await requestInWindow("second", ownedBy: olderOwnerID, on: store)
    await requestInWindow("third", ownedBy: newestOwnerID, on: store)

    await store.cancelEffects(identifiedBy: windowID)
    #expect(store.effectBridge.throttleState.trailingTask(for: AnyEffectID(windowID)) == nil)
    clock.closeWindow()
    // A request after the reset opens a new window and runs as its leading request.
    store.send(.request("fourth"))
    await waitUntil { store.state.fired.count == 2 }

    #expect(store.state.fired == ["first", "fourth"])
  }

  // MARK: Dispatches of removed requests

  // A cancellation that removes a request from a window it hands over must
  // not leave that request's dispatch waiting for the window: the window's
  // timer now serves other dispatches' requests.

  @Test("A request its own ID cancellation removes from a window releases its dispatch at once")
  func removedNewestRequestReleasesItsDispatch() async {
    let clock = WindowClock()
    let store = Store(reducer: TrailingFeature(), initialState: .init(), clock: clock.storeClock)
    store.send(.request("first"))
    await waitUntil { clock.hasSleeper && store.state.fired == ["first"] }
    let second = await requestInWindow("second", ownedBy: olderOwnerID, on: store)
    let third = await requestInWindow("third", ownedBy: newestOwnerID, on: store)

    await store.cancelEffects(identifiedBy: newestOwnerID)
    await waitUntil { third.isFinished }
    #expect(third.isFinished)
    #expect(second.isFinished == false)

    clock.closeWindow()
    await waitUntil { store.state.fired.count == 2 }
    #expect(store.state.fired == ["first", "second"])
    await second.finish()
  }

  @Test("A removed request's dispatch does not wait for the awaited run of its successor")
  func removedRequestDoesNotWaitForSuccessorRun() async {
    let clock = WindowClock()
    let gate = TrailingRunGate()
    let store = Store(
      reducer: AwaitedTrailingFeature(gate: gate), initialState: .init(),
      clock: clock.storeClock)
    // The awaited trailing-only opener: the window's first trailing request.
    let second = store.send(.awaitedOwnedConcatenation("second", by: olderOwnerID))
    await waitUntil { clock.hasSleeper && pendingSequence(store) != nil }
    let third = await sendIntoWindow(.ownedRequest("third", by: newestOwnerID), on: store)

    await store.cancelEffects(identifiedBy: newestOwnerID)
    await waitUntil { third.isFinished }
    #expect(third.isFinished)

    clock.closeWindow()
    // The window falls back to `second`, whose run is awaited by its own
    // concatenation and is still parked.
    await waitUntil { gate.hasStarted("second") }
    #expect(third.isFinished)
    #expect(second.isFinished == false)

    gate.release("second")
    await second.finish()
    #expect(store.state.log == ["ran-second", "after-second"])
  }

  @Test("An awaited request its own ID cancellation removes stops waiting for the window")
  func removedAwaitedRequestStopsWaitingForTheWindow() async {
    let clock = WindowClock()
    let gate = TrailingRunGate()
    let store = Store(
      reducer: AwaitedTrailingFeature(gate: gate), initialState: .init(),
      clock: clock.storeClock)
    let first = store.send(.ownedRequest("first", by: olderOwnerID))
    await waitUntil { clock.hasSleeper && pendingSequence(store) != nil }
    let third = await sendIntoWindow(.awaitedOwnedRequest("third", by: newestOwnerID), on: store)

    await store.cancelEffects(identifiedBy: newestOwnerID)
    // The concatenation goes on past the removed request: its ID covers only
    // that request.
    await waitUntil { store.state.log == ["after-third"] && third.isFinished }
    #expect(store.state.log == ["after-third"])
    #expect(third.isFinished)
    #expect(first.isFinished == false)

    clock.closeWindow()
    await waitUntil { gate.hasStarted("first") }
    gate.release("first")
    await first.finish()
    #expect(store.state.log == ["after-third", "ran-first"])
  }
}
