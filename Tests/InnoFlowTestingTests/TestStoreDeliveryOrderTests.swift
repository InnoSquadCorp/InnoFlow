// MARK: - TestStoreDeliveryOrderTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import InnoFlowCore
import InnoFlowTesting
import Testing

@testable import InnoFlowCoreTestSupport

// A `Store` reduces an effect action the moment an effect delivers it, and a
// run's `send` returns only after that reduction. A `TestStore` buffers the
// action until the test receives it. These tests compare what a `Store`
// reduces with what a `TestStore` lets a test receive, exhaustively and
// non-exhaustively, for orders a `Store` fixes: the continuation of the
// delivering effect cannot cancel what it already delivered, and a received
// action's synchronous follow-ups precede its run's next emission.

private let markID = EffectID<String>("delivery-order-mark")
private let otherID = EffectID<String>("delivery-order-other")

private enum OwnShape: String, CaseIterable, Sendable, CustomTestStringConvertible {
  /// `.concatenate(.send(.mark).cancellable(id), .cancel(id))`, the MIGRATION example.
  case sendThenCancel
  /// `.concatenate(.send(.mark), .cancel(id)).cancellable(id)`.
  case cancellableConcat
  /// `.concatenate(.run { send(.mark) }.cancellable(id), .cancel(id))`.
  case runThenCancel

  var testDescription: String { rawValue }
}

private struct OwnCancellationFeature: Reducer {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: Equatable, Sendable {
    case start(OwnShape)
    /// A timer and a piece of work under one ID; the work cancels the timer.
    case timerAndWork
    /// Delivers `.mark` under `markID`, then cancels another ID.
    case markThenCancelOther
    /// A run under `markID` delivers `.mark`; nothing of its own cancels it.
    case runUnderMark
    case mark
    case workDone
    case tick
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start(.sendThenCancel):
      return .concatenate(EffectTask<Action>.send(.mark).cancellable(markID), .cancel(markID))
    case .start(.cancellableConcat):
      return EffectTask<Action>.concatenate(.send(.mark), .cancel(markID)).cancellable(markID)
    case .start(.runThenCancel):
      return .concatenate(
        EffectTask<Action>.run { send in await send(.mark) }.cancellable(markID),
        .cancel(markID)
      )
    case .timerAndWork:
      return .merge(
        EffectTask<Action>.run { send, context in
          // Only cancellation ends the wait: the clock is never advanced.
          try? await context.sleep(for: .seconds(60))
          await send(.tick)
        }
        .cancellable(markID),
        .concatenate(
          EffectTask<Action>.run { send in await send(.workDone) }.cancellable(markID),
          .cancel(markID)
        )
      )
    case .markThenCancelOther:
      return .concatenate(EffectTask<Action>.send(.mark).cancellable(markID), .cancel(otherID))
    case .runUnderMark:
      return EffectTask<Action>.run { send in await send(.mark) }.cancellable(markID)
    case .mark:
      state.log.append("mark")
      return .none
    case .workDone:
      state.log.append("workDone")
      return .none
    case .tick:
      state.log.append("tick")
      return .none
    }
  }
}

private struct FollowUpFeature: Reducer {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: Equatable, Sendable {
    case start(secondCancelsFollowUp: Bool)
    case first
    case firstFollowUp
    case second(cancelsFollowUp: Bool)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start(let cancels):
      return .run { send in
        await send(.first)
        await send(.second(cancelsFollowUp: cancels))
      }
    case .first:
      state.log.append("first")
      return EffectTask<Action>.send(.firstFollowUp).cancellable(markID)
    case .firstFollowUp:
      state.log.append("firstFollowUp")
      return .none
    case .second(let cancels):
      state.log.append("second")
      return .cancel(cancels ? markID : otherID)
    }
  }
}

private struct BehindFeature: Reducer {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: Equatable, Sendable {
    case start(markCancels: Bool)
    case mark(cancels: Bool)
    case late
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start(let cancels):
      // `.late` is delivered after `.mark`, then this effect's own cancel
      // settles both.
      return .concatenate(
        .send(.mark(cancels: cancels)),
        EffectTask<Action>.send(.late).cancellable(markID),
        .cancel(markID)
      )
    case .mark(let cancels):
      state.log.append("mark")
      return cancels ? .cancel(markID) : .none
    case .late:
      state.log.append("late")
      return .none
    }
  }
}

private struct OutputFeature: Reducer {
  struct State: Equatable, Sendable {}

  enum Action: Equatable, Sendable {
    case start
  }

  enum Output: Equatable, Sendable {
    case done
  }

  func reduce(into state: inout State, action: Action) -> ReducerEffect<Action, Output> {
    .concatenate(Self.output(.done).cancellable(markID), .cancel(markID))
  }
}

private struct ScopedParentFeature: Reducer {
  struct ChildState: Equatable, Sendable {
    var log: [String] = []
  }

  struct State: Equatable, Sendable {
    var child = ChildState()
  }

  enum ChildAction: Equatable, Sendable {
    case start
    case mark
  }

  enum Action: Equatable, Sendable {
    case child(ChildAction)

    static let childPath = CasePath<Self, ChildAction>(
      embed: Self.child,
      extract: { action in
        guard case .child(let childAction) = action else { return nil }
        return childAction
      }
    )
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .child(.start):
      return .concatenate(
        EffectTask<Action>.send(.child(.mark)).cancellable(markID), .cancel(markID))
    case .child(.mark):
      state.child.log.append("mark")
      return .none
    }
  }
}

/// What a `Store` reduces for `action`, after its effect tree is idle.
@MainActor
private func storeLog<R: Reducer>(
  _ reducer: R, _ action: R.Action, state: R.State, log: KeyPath<R.State, [String]>
) async -> [String] {
  let store = Store(reducer: reducer, initialState: state, clock: .manual(ManualTestClock()))
  await store.send(action).finish()
  return store.state[keyPath: log]
}

/// Waits for `condition`, re-evaluating it whenever the test store reports
/// progress, without consuming anything.
@MainActor
private func waitFor<R: Reducer>(
  _ store: TestStore<R>,
  _ condition: @MainActor () -> Bool,
  sourceLocation: SourceLocation = #_sourceLocation
) async where R.State: Equatable {
  let deadline = ContinuousClock.now.advanced(by: scaledTestDeadline(.seconds(10)))
  while true {
    let revision = store.finishActivity.snapshot.revision
    if condition() { return }
    guard await store.finishActivity.waitForChange(after: revision, until: deadline) else {
      Issue.record(
        "The test store made no progress before the deadline", sourceLocation: sourceLocation)
      return
    }
  }
}

@MainActor
private func waitUntilIdle<R: Reducer>(_ store: TestStore<R>) async where R.State: Equatable {
  await waitFor(store) { store.finishActivity.snapshot.activeCount == 0 }
}

@Suite("TestStore delivery order matches Store", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct TestStoreDeliveryOrderTests {
  @Test(
    "An effect's own later cancel keeps an action it already delivered",
    arguments: OwnShape.allCases, [true, false])
  fileprivate func ownCancelKeepsEarlierDelivery(shape: OwnShape, exhaustive: Bool) async {
    let expected = await storeLog(
      OwnCancellationFeature(), .start(shape), state: .init(), log: \.log)
    #expect(expected == ["mark"])

    let store = TestStore(reducer: OwnCancellationFeature(), initialState: .init())
    store.exhaustivity = exhaustive ? .on : .off
    await store.send(.start(shape))
    // The effect has applied its own cancel when its tree is idle.
    await waitUntilIdle(store)
    if exhaustive {
      await store.receive(.mark) { $0.log = ["mark"] }
    }
    await store.finish()
    #expect(store.state.log == expected)
  }

  @Test("A receive that waits while the effect cancels itself still gets the action")
  func waitingReceiveGetsActionBeforeOwnCancel() async {
    let store = TestStore(reducer: OwnCancellationFeature(), initialState: .init())
    await store.send(.start(.sendThenCancel))
    // No wait: the receive is usually pending when the effect delivers and
    // then cancels; either order must give the test the action.
    await store.receive(.mark) { $0.log = ["mark"] }
    await store.finish()
  }

  @Test(
    "Work that cancels a timer under its own ID keeps its delivered action",
    arguments: [true, false])
  func workCancellingTimerKeepsItsAction(exhaustive: Bool) async {
    let expected = await storeLog(
      OwnCancellationFeature(), .timerAndWork, state: .init(), log: \.log)
    #expect(expected == ["workDone"])

    let store = TestStore(
      reducer: OwnCancellationFeature(), initialState: .init(), clock: ManualTestClock())
    store.exhaustivity = exhaustive ? .on : .off
    await store.send(.timerAndWork)
    // Idle means the work cancelled the timer and the timer's emission was dropped.
    await waitUntilIdle(store)
    if exhaustive {
      await store.receive(.workDone) { $0.log = ["workDone"] }
    }
    await store.finish()
    #expect(store.state.log == expected)
  }

  @Test(
    "Follow-ups of a run's emission precede the run's next emission",
    arguments: [true, false], [true, false])
  func followUpPrecedesNextEmission(secondCancelsFollowUp: Bool, exhaustive: Bool) async {
    let action = FollowUpFeature.Action.start(secondCancelsFollowUp: secondCancelsFollowUp)
    let expected = await storeLog(FollowUpFeature(), action, state: .init(), log: \.log)
    #expect(expected == ["first", "firstFollowUp", "second"])

    let store = TestStore(reducer: FollowUpFeature(), initialState: .init())
    store.exhaustivity = exhaustive ? .on : .off
    await store.send(action)
    // Both emissions are buffered before the test receives the first.
    await waitFor(store) { store.unverifiedSnapshot().actionCount == 2 }
    if exhaustive {
      await store.receive(.first) { $0.log = ["first"] }
      await store.receive(.firstFollowUp) { $0.log = ["first", "firstFollowUp"] }
      await store.receive(.second(cancelsFollowUp: secondCancelsFollowUp)) {
        $0.log = ["first", "firstFollowUp", "second"]
      }
    }
    await store.finish()
    #expect(store.state.log == expected)
  }

  @Test(
    "A received action's cancel removes settled actions buffered behind it",
    arguments: [true, false], [true, false])
  func receivedCancelRemovesSettledActionsBehindIt(markCancels: Bool, exhaustive: Bool) async {
    let action = BehindFeature.Action.start(markCancels: markCancels)
    let expected = await storeLog(BehindFeature(), action, state: .init(), log: \.log)
    #expect(expected == (markCancels ? ["mark"] : ["mark", "late"]))

    let store = TestStore(reducer: BehindFeature(), initialState: .init())
    store.exhaustivity = exhaustive ? .on : .off
    await store.send(action)
    // `.mark` and `.late` are both buffered and settled by the effect's own cancel.
    await waitUntilIdle(store)
    if exhaustive {
      await store.receive(.mark(cancels: markCancels)) { $0.log = ["mark"] }
      if !markCancels {
        await store.receive(.late) { $0.log = ["mark", "late"] }
      }
    }
    await store.finish()
    #expect(store.state.log == expected)
  }

  @Test("A test-issued cancel still removes a buffered action no own cancel has passed")
  func testCancelRemovesUnsettledAction() async {
    let store = TestStore(reducer: OwnCancellationFeature(), initialState: .init())
    await store.send(.runUnderMark)
    await waitUntilIdle(store)
    #expect(store.unverifiedSnapshot().actionCount == 1)
    // The schedule where the cancellation lands first: nothing to receive.
    await store.cancelEffects(identifiedBy: markID)
    await store.finish()
    #expect(store.state.log.isEmpty)
  }

  @Test("A test-issued cancel keeps a buffered action its effect's own cancel has passed")
  func testCancelKeepsSettledAction() async {
    let expected = await storeLog(
      OwnCancellationFeature(), .markThenCancelOther, state: .init(), log: \.log)
    #expect(expected == ["mark"])

    let store = TestStore(reducer: OwnCancellationFeature(), initialState: .init())
    await store.send(.markThenCancelOther)
    await waitUntilIdle(store)
    await store.cancelEffects(identifiedBy: markID)
    await store.cancelAllEffects()
    await store.receive(.mark) { $0.log = ["mark"] }
    await store.finish()
  }

  @Test("Cancelling the dispatch still removes a settled buffered action")
  func dispatchCancelRemovesSettledAction() async {
    let store = TestStore(reducer: OwnCancellationFeature(), initialState: .init())
    let dispatch = await store.send(.start(.sendThenCancel))
    await waitUntilIdle(store)
    #expect(store.unverifiedSnapshot().actionCount == 1)
    dispatch.cancel()
    #expect(store.unverifiedSnapshot().actionCount == 0)
    // The removed action no longer holds the dispatch open.
    await dispatch.finish()
    #expect(dispatch.isFinished)
    await store.finish()
    #expect(store.state.log.isEmpty)
  }

  @Test("An output delivered before its effect's own cancel is received", arguments: [true, false])
  func outputBeforeOwnCancelIsReceived(exhaustive: Bool) async {
    let outputStore = Store(reducer: OutputFeature(), initialState: .init())
    let captured = outputStore.send(.start, capturingOutputs: .unbounded)
    var expected: [OutputFeature.Output] = []
    for await output in captured.outputs { expected.append(output) }
    withExtendedLifetime(outputStore) {}
    #expect(expected == [.done])

    let store = TestStore(reducer: OutputFeature(), initialState: .init())
    store.exhaustivity = exhaustive ? .on : .off
    await store.send(.start)
    await waitUntilIdle(store)
    await store.receiveOutput(.done, timeout: .zero)
    await store.finish()
  }

  @Test("A scoped receive gets a child action its effect's own cancel has passed")
  func scopedReceiveGetsSettledAction() async {
    let store = TestStore(reducer: ScopedParentFeature(), initialState: .init())
    let child = store.scope(state: \.child, action: ScopedParentFeature.Action.childPath)
    await child.send(.start)
    await waitUntilIdle(store)
    await child.receive(.mark) { $0.log = ["mark"] }
    await store.finish()
  }
}
