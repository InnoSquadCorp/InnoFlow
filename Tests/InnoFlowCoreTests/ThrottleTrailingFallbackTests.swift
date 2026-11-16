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

private struct TrailingFeature: Reducer {
  struct State: Equatable, Sendable {
    var fired: [String] = []
  }

  enum Action: Sendable {
    case request(String)
    case fired(String)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .request(let tag):
      return EffectTask<Action>.send(.fired(tag))
        .throttle(windowID, for: .seconds(1), leading: true, trailing: true)

    case .fired(let tag):
      state.fired.append(tag)
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

  private func pendingSequence(_ store: Store<TrailingFeature>) -> UInt64? {
    store.effectBridge.throttleState.pending(for: AnyEffectID(windowID))?.context?.sequence
  }

  /// Sends a request into the open window and waits until the window holds
  /// it as its newest trailing request.
  @discardableResult
  private func requestInWindow(
    _ tag: String, on store: Store<TrailingFeature>
  ) async -> FlowTask {
    let previous = pendingSequence(store)
    let task = store.send(.request(tag))
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
}
