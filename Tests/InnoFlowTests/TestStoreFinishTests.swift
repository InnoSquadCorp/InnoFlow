// MARK: - TestStoreFinishTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import Testing

@testable import InnoFlowCore
@testable import InnoFlowTesting

@Suite("TestStore Finish Tests", .serialized)
@MainActor
struct TestStoreFinishTests {
  @Test("finish returns immediately when no effects or actions remain")
  func finishReturnsImmediatelyWithoutWork() async {
    let store = TestStore(reducer: FinishFeature(gate: RunStartGate()))

    let result = await store.finishResult(timeout: .zero)

    #expect(result == .success)
  }

  @Test("finish reports every buffered action")
  func finishReportsEveryBufferedAction() async {
    let store = TestStore(reducer: FinishFeature(gate: RunStartGate()))

    store.deliverAction(.response(1), context: nil)
    store.deliverAction(.response(2), context: nil)

    guard
      case .unhandledActions(let actions) =
        await store.finishResult(timeout: .seconds(1))
    else {
      Issue.record("Expected finish to report buffered actions")
      return
    }

    #expect(actions.count == 2)
    #expect(actions[0].contains("1"))
    #expect(actions[1].contains("2"))
  }

  @Test("finish waits for a running effect to complete")
  func finishWaitsForRunningEffect() async {
    let gate = RunStartGate()
    let store = TestStore(reducer: FinishFeature(gate: gate))

    await store.send(.wait)
    #expect(store.finishActivity.snapshot.runCount == 1)

    let finishing = Task { @MainActor in
      await store.finishResult(timeout: .seconds(1))
    }
    await gate.open()

    #expect(await finishing.value == .success)
  }

  @Test("finish tracks unawaited merge composite handoff")
  func finishTracksMergeComposite() async {
    let gate = RunStartGate()
    let store = TestStore(reducer: FinishCompositeFeature(gate: gate))

    await store.send(.merge)
    #expect(store.finishActivity.snapshot.compositeCount == 2)

    let finishing = Task { @MainActor in
      await store.finishResult(timeout: .seconds(1))
    }
    await gate.open()

    #expect(await finishing.value == .success)
  }

  @Test("finish tracks unawaited concatenate composite handoff")
  func finishTracksConcatenateComposite() async {
    let gate = RunStartGate()
    let store = TestStore(reducer: FinishCompositeFeature(gate: gate))

    await store.send(.concatenate)
    #expect(store.finishActivity.snapshot.compositeCount == 1)

    let finishing = Task { @MainActor in
      await store.finishResult(timeout: .seconds(1))
    }
    await gate.open()

    #expect(await finishing.value == .success)
  }

  @Test("cancelling an unawaited concatenate releases finish activity")
  func cancellingConcatenateReleasesFinishActivity() async {
    let gate = RunStartGate()
    let store = TestStore(
      reducer: FinishCompositeFeature(gate: gate)
    )

    await store.send(.concatenate)
    #expect(store.finishActivity.snapshot.compositeCount == 1)

    await store.cancelAllEffects()
    await gate.open()
    let released = await waitUntil(
      timeout: .seconds(1),
      pollInterval: .milliseconds(1)
    ) {
      store.finishActivity.snapshot.activeCount == 0
    }

    #expect(released)
    #expect(await store.finishResult(timeout: .zero) == .success)
  }

  @Test("finish detects an action emitted while it is waiting")
  func finishDetectsLateAction() async {
    let gate = RunStartGate()
    let store = TestStore(reducer: FinishFeature(gate: gate))

    await store.send(.emitAfterGate(42))
    let finishing = Task { @MainActor in
      await store.finishResult(timeout: .seconds(1))
    }

    await gate.open()

    guard case .unhandledActions(let actions) = await finishing.value else {
      Issue.record("Expected finish to report the late action")
      return
    }
    #expect(actions.count == 1)
    #expect(actions[0].contains("42"))
  }

  @Test("non-exhaustive finish reduces an action emitted while waiting")
  func nonExhaustiveFinishReducesLateAction() async {
    let gate = RunStartGate()
    let store = TestStore(reducer: FinishFeature(gate: gate))
    store.exhaustivity = .off

    await store.send(.emitAfterGate(42))
    let finishing = Task { @MainActor in
      await store.finishResult(timeout: .seconds(1))
    }

    await gate.open()

    #expect(await finishing.value == .success)
    #expect(store.state.responses == [42])
  }

  @Test("non-exhaustive finish times out an immediate action loop")
  func nonExhaustiveFinishTimesOutActionLoop() async {
    let store = TestStore(reducer: FinishFeature(gate: RunStartGate()))
    store.exhaustivity = .off
    store.deliverAction(.loop, context: nil)

    guard case .timedOut = await store.finishResult(timeout: .milliseconds(5)) else {
      Issue.record("Expected finish to time out on a self-reenqueuing action")
      return
    }

    #expect(store.finishActivity.snapshot.activeCount == 0)
  }

  @Test("non-exhaustive finish cancels a run started by a skipped action")
  func nonExhaustiveFinishCancelsRunFromSkippedAction() async {
    let store = TestStore(reducer: FinishFeature(gate: RunStartGate()))
    store.exhaustivity = .off
    store.deliverAction(.startSkippedRun, context: nil)

    guard
      case .timedOut(let snapshot) =
        await store.finishResult(timeout: .milliseconds(20))
    else {
      Issue.record("Expected finish to time out on the skipped action's run")
      return
    }

    #expect(snapshot.runCount == 1)
    let released = await waitUntil(
      timeout: .seconds(1),
      pollInterval: .milliseconds(1)
    ) {
      store.finishActivity.snapshot.activeCount == 0
    }
    #expect(released)
  }

  @Test("finish wakes for an action before its run completes")
  func finishWakesBeforeRunCompletion() async throws {
    let emit = RunStartGate()
    let complete = RunStartGate()
    let store = TestStore(
      reducer: FinishHeldEmissionFeature(
        emit: emit,
        complete: complete
      )
    )

    await store.send(.start)
    let runTask = try #require(store.runningTasks.values.first?.task)
    let finishing = Task { @MainActor in
      await store.finishResult(timeout: .seconds(1))
    }

    await emit.open()
    let result = await finishing.value

    #expect(store.finishActivity.snapshot.runCount == 1)
    await complete.open()
    _ = await runTask.result

    guard case .unhandledActions(let actions) = result else {
      Issue.record("Expected finish to wake for the emitted action")
      return
    }
    #expect(actions == ["response"])
    #expect(store.finishActivity.snapshot.activeCount == 0)
  }

  @Test("finish times out and cancels a manual-clock run without advancing time")
  func finishTimesOutAndCancelsRun() async throws {
    let clock = ManualTestClock()
    let store = TestStore(
      reducer: FinishFeature(gate: RunStartGate()),
      clock: clock
    )

    await store.send(.sleep)
    try #require(
      await waitUntilAsync(timeout: .seconds(1), pollInterval: .milliseconds(1)) {
        await clock.sleeperCount == 1
      }
    )
    let runTask = try #require(store.runningTasks.values.first?.task)
    let manualNow = await clock.now

    guard
      case .timedOut(let snapshot) =
        await store.finishResult(timeout: .milliseconds(20))
    else {
      Issue.record("Expected finish to time out")
      return
    }

    #expect(snapshot.runCount == 1)
    _ = await runTask.result
    #expect(await clock.now == manualNow)
    #expect(store.finishActivity.snapshot.activeCount == 0)
  }

  @Test("finish succeeds after explicit effect cancellation")
  func finishSucceedsAfterExplicitCancellation() async throws {
    let clock = ManualTestClock()
    let store = TestStore(
      reducer: FinishFeature(gate: RunStartGate()),
      clock: clock
    )

    await store.send(.sleep)
    try #require(
      await waitUntilAsync(timeout: .seconds(1), pollInterval: .milliseconds(1)) {
        await clock.sleeperCount == 1
      }
    )
    let runTask = try #require(store.runningTasks.values.first?.task)

    await store.cancelAllEffects()

    #expect(await store.finishResult(timeout: .seconds(1)) == .success)
    _ = await runTask.result
    #expect(store.finishActivity.snapshot.activeCount == 0)
  }

  @Test("finish uses wall time without advancing a manual debounce clock")
  func finishDoesNotAdvanceManualDebounceClock() async throws {
    let clock = ManualTestClock()
    let store = TestStore(
      reducer: FinishFeature(gate: RunStartGate()),
      clock: clock
    )

    await store.send(.debounce)
    try #require(
      await waitUntilAsync(timeout: .seconds(1), pollInterval: .milliseconds(1)) {
        await clock.sleeperCount == 1
      }
    )
    let manualNow = await clock.now
    let debounceTask = try #require(store.debounceTasksByID.values.first?.task)

    guard
      case .timedOut(let snapshot) =
        await store.finishResult(timeout: .milliseconds(20))
    else {
      Issue.record("Expected finish to time out on the pending debounce")
      return
    }

    #expect(snapshot.debounceCount == 1)
    _ = await debounceTask.result
    #expect(await clock.now == manualNow)
    #expect(await clock.sleeperCount == 0)
    #expect(store.finishActivity.snapshot.activeCount == 0)
  }

  @Test("finish tracks trailing throttle sleep without advancing manual time")
  func finishTracksTrailingThrottle() async throws {
    let clock = ManualTestClock()
    let store = TestStore(
      reducer: FinishFeature(gate: RunStartGate()),
      clock: clock
    )

    await store.send(.trailing)
    try #require(
      await waitUntilAsync(timeout: .seconds(1), pollInterval: .milliseconds(1)) {
        await clock.sleeperCount == 1
      }
    )
    let manualNow = await clock.now
    let throttleID = AnyEffectID(StaticEffectID("finish-throttle"))
    let throttleTask = try #require(store.throttleState.trailingTask(for: throttleID))

    guard
      case .timedOut(let snapshot) =
        await store.finishResult(timeout: .milliseconds(20))
    else {
      Issue.record("Expected finish to time out on trailing throttle work")
      return
    }

    #expect(snapshot.throttleCount == 1)
    _ = await throttleTask.result
    #expect(await clock.now == manualNow)
    #expect(await clock.sleeperCount == 0)
    #expect(store.finishActivity.snapshot.activeCount == 0)
  }

  @Test("finish tracks a leading-only throttle window without advancing manual time")
  func finishTracksLeadingOnlyThrottleWindow() async throws {
    let clock = ManualTestClock()
    let store = TestStore(
      reducer: FinishFeature(gate: RunStartGate()),
      clock: clock
    )

    await store.send(.leading)
    try #require(
      await waitUntilAsync(timeout: .seconds(1), pollInterval: .milliseconds(1)) {
        await clock.sleeperCount == 1
      }
    )
    let manualNow = await clock.now
    let throttleID = AnyEffectID(StaticEffectID("finish-leading-throttle"))
    let throttleTask = try #require(store.throttleState.trailingTask(for: throttleID))

    guard
      case .timedOut(let snapshot) =
        await store.finishResult(timeout: .milliseconds(20))
    else {
      Issue.record("Expected finish to time out on the active leading-only throttle window")
      return
    }

    #expect(snapshot.throttleCount == 1)
    _ = await throttleTask.result
    #expect(await clock.now == manualNow)
    #expect(await clock.sleeperCount == 0)
    #expect(store.throttleState.scope(for: throttleID) == nil)
    #expect(store.throttleActivityTokenByID[throttleID] == nil)
    #expect(store.finishActivity.snapshot.activeCount == 0)
  }

  @Test("finish activity spans debounce post-fire recursion")
  func finishActivitySpansDebounceRecursion() async throws {
    let store = TestStore(reducer: FinishFeature(gate: RunStartGate()))
    let id = AnyEffectID(StaticEffectID("finish-post-fire-debounce"))
    let sequence = store.nextSequence()
    let context = store.makeEffectContext(
      sequence: sequence,
      cancellationIDs: [id],
      potentialCancellationIDs: [id]
    )
    let recursionStarted = AsyncTestSignal()
    let releaseRecursion = RunStartGate()

    let task = try #require(
      await store.scheduleDebounce(
        .none,
        id: id,
        interval: .zero,
        context: context,
        scope: .init(
          ownerID: id,
          sequence: sequence,
          cancellationContext: context
        ),
        nestedAwaited: false
      ) { _, _, _ in
        recursionStarted.signal()
        await releaseRecursion.wait()
      }
    )

    try #require(await recursionStarted.wait())
    #expect(store.debounceTasksByID[id] == nil)
    #expect(store.finishActivity.snapshot.debounceCount == 1)

    let finishing = Task { @MainActor in
      await store.finishResult(timeout: .seconds(1))
    }
    await releaseRecursion.open()

    #expect(await finishing.value == .success)
    _ = await task.result
  }

  @Test("finish activity spans trailing throttle post-fire recursion")
  func finishActivitySpansThrottleRecursion() async throws {
    let store = TestStore(reducer: FinishFeature(gate: RunStartGate()))
    let id = AnyEffectID(StaticEffectID("finish-post-fire-throttle"))
    let sequence = store.nextSequence()
    let context = store.makeEffectContext(
      sequence: sequence,
      cancellationIDs: [id],
      potentialCancellationIDs: [id]
    )
    let recursionStarted = AsyncTestSignal()
    let releaseRecursion = RunStartGate()

    store.throttleState.storePending(.none, context: context, for: id)
    let task = store.scheduleTrailingDrain(
      for: id,
      interval: .zero,
      schedulingContext: context,
      awaited: false
    ) { _, _, _ in
      recursionStarted.signal()
      await releaseRecursion.wait()
    }

    try #require(await recursionStarted.wait())
    #expect(store.throttleState.pending(for: id) == nil)
    #expect(store.finishActivity.snapshot.throttleCount == 1)

    let finishing = Task { @MainActor in
      await store.finishResult(timeout: .seconds(1))
    }
    await releaseRecursion.open()

    #expect(await finishing.value == .success)
    _ = await task.result
  }

  @Test("finish timeout cancels debounce post-fire recursion")
  func finishTimeoutCancelsDebounceRecursion() async throws {
    let store = TestStore(reducer: FinishFeature(gate: RunStartGate()))
    let id = AnyEffectID(StaticEffectID("finish-cancel-post-fire-debounce"))
    let sequence = store.nextSequence()
    let context = store.makeEffectContext(
      sequence: sequence,
      cancellationIDs: [id],
      potentialCancellationIDs: [id]
    )
    let recursionStarted = AsyncTestSignal()

    let task = try #require(
      await store.scheduleDebounce(
        .none,
        id: id,
        interval: .zero,
        context: context,
        scope: .init(
          ownerID: id,
          sequence: sequence,
          cancellationContext: context
        ),
        nestedAwaited: false
      ) { _, _, _ in
        recursionStarted.signal()
        try? await Task.sleep(for: .seconds(60))
      }
    )

    try #require(await recursionStarted.wait())
    #expect(store.debounceTasksByID[id] == nil)

    guard
      case .timedOut(let snapshot) =
        await store.finishResult(timeout: .milliseconds(20))
    else {
      Issue.record("Expected finish to time out during debounce recursion")
      return
    }

    #expect(snapshot.debounceCount == 1)
    _ = await task.result
    #expect(store.finishActivity.snapshot.activeCount == 0)
  }

  @Test("finish timeout cancels trailing throttle post-fire recursion")
  func finishTimeoutCancelsThrottleRecursion() async throws {
    let store = TestStore(reducer: FinishFeature(gate: RunStartGate()))
    let id = AnyEffectID(StaticEffectID("finish-cancel-post-fire-throttle"))
    let sequence = store.nextSequence()
    let context = store.makeEffectContext(
      sequence: sequence,
      cancellationIDs: [id],
      potentialCancellationIDs: [id]
    )
    let recursionStarted = AsyncTestSignal()

    store.throttleState.storePending(.none, context: context, for: id)
    let task = store.scheduleTrailingDrain(
      for: id,
      interval: .zero,
      schedulingContext: context,
      awaited: false
    ) { _, _, _ in
      recursionStarted.signal()
      try? await Task.sleep(for: .seconds(60))
    }

    try #require(await recursionStarted.wait())
    #expect(store.throttleState.pending(for: id) == nil)

    guard
      case .timedOut(let snapshot) =
        await store.finishResult(timeout: .milliseconds(20))
    else {
      Issue.record("Expected finish to time out during throttle recursion")
      return
    }

    #expect(snapshot.throttleCount == 1)
    _ = await task.result
    #expect(store.finishActivity.snapshot.activeCount == 0)
  }

  @Test("ScopedTestStore finish delegates to the parent harness")
  func scopedFinishDelegatesToParent() async {
    let store = TestStore(
      reducer: ScopedTestHarnessFeature(),
      initialState: .init()
    )
    let child = store.scope(
      state: \.child,
      action: ScopedTestHarnessFeature.Action.childCasePath
    )

    await child.send(.start) {
      $0.log = ["start"]
    }
    await child.receive(.finished) {
      $0.log = ["start", "finished"]
    }
    await child.finish()
  }
}

private struct FinishFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var responses: [Int] = []
  }

  enum Action: Equatable, Sendable {
    case wait
    case sleep
    case emitAfterGate(Int)
    case emitImmediately(Int)
    case debounce
    case leading
    case trailing
    case response(Int)
    case loop
    case startSkippedRun
  }

  let gate: RunStartGate

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .wait:
      return .run { _ in
        await gate.wait()
      }

    case .sleep:
      return .run { _, context in
        try? await context.sleep(for: .seconds(60))
      }

    case .emitAfterGate(let value):
      return .run { send in
        await gate.wait()
        await send(.response(value))
      }

    case .emitImmediately(let value):
      return .send(.response(value))

    case .debounce:
      return .send(.response(1))
        .debounce("finish-debounce", for: .seconds(60))

    case .leading:
      return .none
        .throttle("finish-leading-throttle", for: .seconds(60))

    case .trailing:
      return .send(.response(1))
        .throttle("finish-throttle", for: .seconds(60), leading: false, trailing: true)

    case .response(let value):
      state.responses.append(value)
      return .none

    case .loop:
      return .send(.loop)

    case .startSkippedRun:
      return .run { _, context in
        try? await context.sleep(for: .seconds(60))
      }
    }
  }
}

private struct FinishHeldEmissionFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {}

  enum Action: Equatable, Sendable {
    case start
    case response
  }

  let emit: RunStartGate
  let complete: RunStartGate

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start:
      return .run { send in
        await emit.wait()
        await send(.response)
        await complete.wait()
      }
    case .response:
      return .none
    }
  }
}

private struct FinishCompositeFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {}

  enum Action: Equatable, Sendable {
    case merge
    case concatenate
  }

  let gate: RunStartGate

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    let first = EffectTask<Action>.run { _ in
      await gate.wait()
    }
    let second = EffectTask<Action>.run { _ in
      await gate.wait()
    }

    switch action {
    case .merge:
      return .merge(first, second)
    case .concatenate:
      return .concatenate(first, second)
    }
  }
}
