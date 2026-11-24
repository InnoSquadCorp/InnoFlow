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

  @Test("A receive takes a value once no pending composite task can precede it")
  func receiveStopsWaitingOnceNothingCanPrecedeTheValue() async {
    let store = TestStore(reducer: StaggeredMergeFeature(), initialState: .init())
    await store.send(.start)
    // The task of `a` delivers it two levels deeper and returns; the tasks
    // of the nested `merge`s are still pending and deliver `z` four levels
    // deeper still, behind `a`.
    await store.receive(.a) { $0.received = ["a"] }
    #expect(store.followedTasks.canDeliver(before: nil))

    await store.receive(.z) { $0.received = ["a", "z"] }
    await store.finish()
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
    // It did not wait for that task.
    #expect(store.followedTasks.canDeliver(before: nil))
    await store.receive(.c1) { $0.log = ["first", "second", "c1"] }
    await store.receive(.c2) { $0.log = ["first", "second", "c1", "c2"] }
    await store.finish()
  }

  @Test("A non-exhaustive finish drains behind an undeliverable head in Store order")
  func finishDrainsBehindAnUndeliverableHeadInOrder() async {
    let store = TestStore(reducer: AheadFeature(), initialState: .init())
    store.exhaustivity = .off
    let context = store.makeEffectContext(sequence: store.nextSequence(), cancellationIDs: [])
    let (tracker, activity, dispatch) = store.makeDispatch()
    let dispatchContext = store.nextEffectContext(
      for: .none, location: .init(), flowTaskTracker: tracker)
    // Delivered in this job: receiving `first` waits for the marker of its
    // level, which queues the next level's marker before the test resumes.
    store.deliverAction(.first, context: context)
    store.deliverAction(.second, context: dispatchContext)
    tracker.endActivity(activity)
    await store.receive(.first) { $0.log = ["first"] }
    // `first`'s `concatenate` task is pending at a place ahead of `late`: a
    // `Store` reduces `c1` and `c2` first.
    store.deliverAction(.late, context: context)
    var lateOrder: TestStoreOrder?
    store.queue.forEachBuffered { if $0.action == .late { lateOrder = $0.delivery.storeOrder } }
    #expect(lateOrder.map { store.followedTasks.canDeliver(before: $0) } == true)
    // `second` stays buffered, undeliverable, until a later job discards it.
    dispatch.cancel()

    await store.finish()
    #expect(store.state.log == ["first", "c1", "c2", "late"])
  }

  @Test("A non-exhaustive finish skips outputs behind an undeliverable head in Store order")
  func finishSkipsOutputsBehindAnUndeliverableHeadInOrder() async {
    let store = TestStore(reducer: OutputBehindFeature(), initialState: .init())
    store.exhaustivity = .off(showSkippedAssertions: true)
    var skipped: [String] = []
    store.warningReporter = { message, _ in
      let prefix = "TestStore skipped reducer output while finishing:\n"
      if message.hasPrefix(prefix) { skipped.append(String(message.dropFirst(prefix.count))) }
    }
    let context = store.makeEffectContext(sequence: store.nextSequence(), cancellationIDs: [])
    let (tracker, activity, dispatch) = store.makeDispatch()
    let dispatchContext = store.nextEffectContext(
      for: .none, location: .init(), flowTaskTracker: tracker)
    store.deliverAction(.first, context: context)
    store.deliverOutput("head", context: dispatchContext)
    await store.receive(.first) { $0.log = ["first"] }
    store.deliverOutput("late", context: context)
    var lateOrder: TestStoreOrder?
    store.outputQueue.forEachBuffered {
      if $0.action == "late" { lateOrder = $0.delivery.storeOrder }
    }
    #expect(lateOrder.map { store.followedTasks.canDeliver(before: $0) } == true)
    // An output holds no activity of its dispatch: cancel it while it runs,
    // which leaves `head` buffered, undeliverable.
    dispatch.cancel()
    tracker.endActivity(activity)

    await store.finish()
    #expect(skipped == ["o1", "o2", "late"])
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
    case first, second, late, c1, c2
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    state.log.append(action.rawValue)
    return action == .first ? .concatenate(.send(.c1), .send(.c2)) : .none
  }
}

/// `a` comes two interpreter levels deeper, `z` six.
private struct StaggeredMergeFeature: Reducer {
  struct State: Equatable, Sendable {
    var received: [String] = []
  }

  enum Action: String, Equatable, Sendable {
    case start, a, z
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    guard action == .start else {
      state.received.append(action.rawValue)
      return .none
    }
    return .merge(.send(.a), .merge(.merge(.send(.z), .run { _ in }), .run { _ in }))
  }
}

/// `first` publishes `o1` and `o2` from an unawaited `concatenate`.
private struct OutputBehindFeature: Reducer {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: String, Equatable, Sendable {
    case first
  }

  typealias Output = String

  func reduce(into state: inout State, action: Action) -> ReducerEffect<Action, String> {
    state.log.append(action.rawValue)
    return .concatenate(.output("o1"), .output("o2"))
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
