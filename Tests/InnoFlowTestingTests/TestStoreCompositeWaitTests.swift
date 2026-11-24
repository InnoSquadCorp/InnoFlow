import Foundation
import Testing

@testable import InnoFlowCore
@testable import InnoFlowTesting

// MARK: - TestStoreCompositeWaitTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

/// A call that takes a buffered value first waits for the composite tasks the
/// test store follows that can still deliver ahead of it. The wait counts
/// against the call's timeout and ends when the calling task is cancelled;
/// the tasks keep running, and what they deliver stays buffered.
@Suite("TestStore waits for followed composite tasks", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct TestStoreCompositeWaitTests {
  @Test("A receive cancelled while it waits for a composite task takes nothing")
  func cancelledReceiveTakesNothing() async {
    let store = TestStore(reducer: NestedMergeFeature(), initialState: .init())
    await store.send(.start)
    let receiving = Task { @MainActor in
      await store.receive(.a) { $0.received = ["a"] }
    }
    #expect(await cancel(receiving, whileWaitingIn: store))
    await receiving.value
    #expect(store.state.received.isEmpty)

    await store.receive(.a) { $0.received = ["a"] }
    await store.finish()
  }

  @Test("A receiveOutput cancelled while it waits for a composite task takes nothing")
  func cancelledReceiveOutputTakesNothing() async {
    let store = TestStore(reducer: NestedMergeFeature(), initialState: .init())
    await store.send(.startOutput)
    let receiving = Task { @MainActor in
      await store.receiveOutput("o")
    }
    #expect(await cancel(receiving, whileWaitingIn: store))
    await receiving.value

    await store.receiveOutput("o")
    await store.finish()
  }

  @Test("A finish cancelled while it waits for a composite task reports cancellation")
  func cancelledFinishReportsCancellation() async {
    let store = TestStore(reducer: NestedMergeFeature(), initialState: .init())
    await store.send(.start)
    let finishing = Task { @MainActor () -> Bool in
      if case .cancelled = await store.finishResult() { return true }
      return false
    }
    #expect(await cancel(finishing, whileWaitingIn: store))
    #expect(await finishing.value)
  }

  @Test("Waiting for a composite task counts against a receive's timeout")
  func compositeWaitCountsAgainstTheTimeout() async {
    let store = TestStore(reducer: NestedMergeFeature(), initialState: .init())
    await store.send(.start)
    // A MainActor job of 100 ms, queued ahead of the jobs that take the
    // composite tasks to `a`: it arrives after the 20 ms timeout.
    Task { @MainActor in
      let end = ContinuousClock.now.advanced(by: .milliseconds(100))
      while ContinuousClock.now < end {}
    }
    let result = await store.receiveResult(timeout: .milliseconds(20)) { action in
      action == .a ? .matched(()) : .mismatched
    }
    #expect(result.isTimedOut)

    await store.receive(.a) { $0.received = ["a"] }
    await store.finish()
  }

  @Test("A zero timeout receives nothing a pending composite task has not delivered")
  func zeroTimeoutDoesNotWaitForCompositeTasks() async {
    let store = TestStore(reducer: NestedMergeFeature(), initialState: .init())
    await store.send(.start)
    let result = await store.receiveResult(timeout: .zero) { action in
      action == .a ? .matched(()) : .mismatched
    }
    #expect(result.isTimedOut)

    await store.receive(.a) { $0.received = ["a"] }
    await store.finish()
  }

  @Test("A zero timeout receives a value buffered ahead of a pending composite task")
  func zeroTimeoutReceivesAValueAheadOfACompositeTask() async {
    let store = TestStore(reducer: AheadFeature(), initialState: .init())
    let context = store.makeEffectContext(sequence: store.nextSequence(), cancellationIDs: [])
    // One MainActor job delivers both, as a run's emissions would: a `Store`
    // reduces `second` before the task in which `first`'s `concatenate`
    // walks its children runs.
    await Task { @MainActor in
      store.deliverAction(.first, context: context)
      store.deliverAction(.second, context: context)
    }.value
    await store.receive(.first) { $0.log = ["first"] }
    #expect(store.followedTasks.canDeliver(before: nil))

    await store.receive(.second, timeout: .zero) { $0.log = ["first", "second"] }
    await store.receive(.c1) { $0.log = ["first", "second", "c1"] }
    await store.receive(.c2) { $0.log = ["first", "second", "c1", "c2"] }
    await store.finish()
  }

  @Test("A zero-timeout receiveOutput reduces no action ahead of a mismatched output")
  func zeroTimeoutReceiveOutputReducesNothing() async {
    let store = TestStore(reducer: OutputAheadFeature(), initialState: .init())
    store.exhaustivity = .off
    let context = store.makeEffectContext(sequence: store.nextSequence(), cancellationIDs: [])
    // A `Store` reduces `update`, and publishes `expected`, before `wrong`.
    store.deliverAction(.update, context: context)
    store.deliverOutput("wrong", context: context)

    await withKnownIssue("The head output does not match") {
      await store.receiveOutput("expected", timeout: .zero)
    }
    #expect(store.state.log.isEmpty)

    await store.receiveOutput("expected")
    #expect(store.state.log == ["update"])
    await store.receiveOutput("wrong")
    await store.finish()
  }

  /// Cancels `task` from a MainActor job queued right behind it, which runs
  /// once the task waits, and reports whether a composite task the store
  /// follows was pending then.
  private func cancel<Value: Sendable>(
    _ task: Task<Value, Never>, whileWaitingIn store: TestStore<NestedMergeFeature>
  ) async -> Bool {
    await Task { @MainActor in
      let isPending = store.followedTasks.canDeliver(before: nil)
      task.cancel()
      return isPending
    }.value
  }
}

/// Three nested `merge`s: `a`, or the output `o`, comes six interpreter
/// levels deeper, so the composite tasks the test store follows stay pending
/// for several MainActor jobs.
private struct NestedMergeFeature: Reducer {
  struct State: Equatable, Sendable {
    var received: [String] = []
  }

  enum Action: Equatable, Sendable {
    case start
    case startOutput
    case a
  }

  typealias Output = String

  func reduce(into state: inout State, action: Action) -> ReducerEffect<Action, String> {
    switch action {
    case .start:
      return .merge(.merge(.merge(.send(.a), .run { _ in }), .run { _ in }), .run { _ in })
    case .startOutput:
      return .merge(.merge(.merge(.output("o"), .run { _ in }), .run { _ in }), .run { _ in })
    case .a:
      state.received.append("a")
      return .none
    }
  }
}

private struct AheadFeature: Reducer {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: String, Equatable, Sendable {
    case first, second, c1, c2
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    state.log.append(action.rawValue)
    return action == .first ? .concatenate(.send(.c1), .send(.c2)) : .none
  }
}

private struct OutputAheadFeature: Reducer {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: Equatable, Sendable {
    case update
  }

  typealias Output = String

  func reduce(into state: inout State, action: Action) -> ReducerEffect<Action, String> {
    state.log.append("update")
    return .output("expected")
  }
}

extension TestStoreReceiveResult {
  fileprivate var isTimedOut: Bool {
    if case .timedOut = self { return true }
    return false
  }
}
