// MARK: - TestStoreReceiveTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import Testing
import os

@testable import InnoFlowCore
@testable import InnoFlowTesting

@Suite("TestStore Receive Tests", .serialized)
@MainActor
struct TestStoreReceiveTests {
  @Test("Exact receive keeps buffered zero-timeout behavior")
  func exactReceiveConsumesBufferedActionWithZeroTimeout() async {
    let store = TestStore(
      reducer: ExactReceiveFeature(),
      initialState: .init(),
      effectTimeout: .zero
    )
    store.deliverAction(.increment, context: nil)

    await store.receive(.increment) {
      $0.count = 1
    }

    #expect(store.state.count == 1)
  }

  @Test("Exact receive can override the store timeout per call")
  func exactReceiveUsesPerCallTimeout() async {
    let store = TestStore(
      reducer: ExactReceiveFeature(),
      initialState: .init(),
      effectTimeout: .zero
    )
    let delivery = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(10))
      store.deliverAction(.increment, context: nil)
    }

    await store.receive(.increment, timeout: .seconds(1)) {
      $0.count = 1
    }
    await delivery.value

    #expect(store.state.count == 1)
  }

  @Test("Case-path and predicate receive support non-Equatable actions")
  func casePathAndPredicateSupportNonEquatableActions() async {
    let store = TestStore(reducer: ReceiveFeature(), initialState: .init())
    store.deliverAction(.value(42), context: nil)

    let value = await store.receive(
      ReceiveFeature.Action.valueCasePath,
      caseName: "value",
      timeout: .zero
    ) { state, payload in
      state.values.append(payload)
      state.reductionCount += 1
    }

    store.deliverAction(.value(7), context: nil)
    let action = await store.receive(
      where: {
        guard case .value(let payload) = $0 else { return false }
        return payload == 7
      },
      description: "value 7",
      timeout: .zero,
      assert: { state, receivedAction in
        guard case .value(let payload) = receivedAction else { return }
        state.values.append(payload)
        state.reductionCount += 1
      }
    )

    #expect(value == 42)
    guard case .value(7)? = action else {
      Issue.record("Expected predicate receive to return .value(7)")
      return
    }
    #expect(store.state.values == [42, 7])
  }

  @Test("Case-path receive distinguishes a matched nil optional payload")
  func casePathReceivePreservesMatchedNilPayload() async {
    let store = TestStore(reducer: ReceiveFeature(), initialState: .init())
    store.deliverAction(.optional(nil), context: nil)

    let received: Int?? = await store.receive(
      ReceiveFeature.Action.optionalCasePath,
      caseName: "optional",
      timeout: .zero
    ) { state, payload in
      state.optionalReceiveCount += 1
      state.lastOptionalWasNil = payload == nil
      state.reductionCount += 1
    }

    guard case .some(.none) = received else {
      Issue.record("Expected a matched nil payload, not a failed match")
      return
    }
    #expect(store.state.optionalReceiveCount == 1)
    #expect(store.state.lastOptionalWasNil)
  }

  @Test("Scoped receive mirrors case-path and predicate APIs")
  func scopedReceiveSupportsCasePathAndPredicate() async {
    let store = TestStore(reducer: ReceiveFeature(), initialState: .init())
    let child = store.scope(
      state: \ReceiveFeature.State.child,
      action: ReceiveFeature.Action.childCasePath
    )
    child.exhaustivity = .off

    store.deliverAction(.child(.value(3)), context: nil)
    let value = await child.receive(
      ReceiveFeature.ChildAction.valueCasePath,
      caseName: "child.value",
      timeout: .zero
    ) { state, payload in
      state.values = [payload]
    }

    store.deliverAction(.child(.value(5)), context: nil)
    let action = await child.receive(
      where: {
        guard case .value(let payload) = $0 else { return false }
        return payload == 5
      },
      description: "child value 5",
      timeout: .zero,
      assert: { state, receivedAction in
        guard case .value(let payload) = receivedAction else { return }
        state.values = [3, payload]
      }
    )

    #expect(value == 3)
    guard case .value(5)? = action else {
      Issue.record("Expected scoped predicate receive to return .value(5)")
      return
    }
    #expect(child.state.values == [3, 5])
  }

  @Test("Scoped receive evaluates its action extractor once per dequeued action")
  func scopedReceiveEvaluatesActionExtractorOnce() async {
    let extractionCounter = ReceiveExtractionCounter()
    let actionPath = CasePath<ReceiveFeature.Action, ReceiveFeature.ChildAction>(
      embed: ReceiveFeature.Action.child,
      extract: { action in
        extractionCounter.increment()
        guard case .child(let childAction) = action else { return nil }
        return childAction
      }
    )
    let store = TestStore(reducer: ReceiveFeature(), initialState: .init())
    let child = store.scope(state: \ReceiveFeature.State.child, action: actionPath)
    child.exhaustivity = .off
    store.deliverAction(.value(99), context: nil)
    store.deliverAction(.child(.value(11)), context: nil)

    _ = await child.receive(
      ReceiveFeature.ChildAction.valueCasePath,
      timeout: .seconds(1)
    ) { state, payload in
      state.values = [payload]
    }

    #expect(extractionCounter.count == 2)
  }

  @Test("PhaseMap receive forwards its per-call timeout")
  func phaseMapReceiveForwardsPerCallTimeout() async {
    let store = TestStore(reducer: PhaseMapHarness(), initialState: .init())
    await store.send(.load, through: PhaseMapHarness.phaseMap) {
      $0.phase = .loading
    }
    store.deliverAction(.loaded([1, 2]), context: nil)

    await store.receive(
      .loaded([1, 2]),
      through: PhaseMapHarness.phaseMap,
      timeout: .zero
    ) {
      $0.phase = .loaded
      $0.values = [1, 2]
    }

    #expect(store.state.phase == .loaded)
  }

  @Test("A mismatch consumes one action without running the reducer")
  func receiveMismatchConsumesExactlyOneActionWithoutReducing() async {
    let store = TestStore(reducer: ReceiveFeature(), initialState: .init())
    store.deliverAction(.ignored, context: nil)
    store.deliverAction(.value(9), context: nil)

    let mismatch: TestStoreReceiveResult<ReceiveFeature.Action, Int> =
      await store.receiveResult(timeout: .zero) { action in
        guard case .value(let payload) = action else { return .mismatched }
        return .matched(payload)
      }
    guard case .mismatched(let action) = mismatch, case .ignored = action else {
      Issue.record("Expected the first valid action to mismatch")
      return
    }
    #expect(store.state.reductionCount == 0)

    let next: TestStoreReceiveResult<ReceiveFeature.Action, Int> =
      await store.receiveResult(timeout: .zero) { action in
        guard case .value(let payload) = action else { return .mismatched }
        return .matched(payload)
      }
    guard case .matched(action: _, value: 9) = next else {
      Issue.record("Expected only the mismatched action to be consumed")
      return
    }
    #expect(store.state.reductionCount == 0)
  }

  @Test("Receive cancellation removes its waiter and preserves later actions")
  func receiveCancellationCleansUpWaiterAndPreservesLateAction() async {
    let store = TestStore(reducer: ReceiveFeature(), initialState: .init())
    let pendingReceive = Task { @MainActor in
      let result = await store.receiveResult(timeout: .seconds(60)) { action in
        TestStoreActionMatch.matched(action)
      }
      if case .cancelled = result { return true }
      return false
    }

    let didInstallWaiter = await waitUntil {
      store.queue.pendingWaiterCount == 1
    }
    #expect(didInstallWaiter)

    pendingReceive.cancel()
    store.deliverAction(.value(13), context: nil)
    let wasCancelled = await pendingReceive.value
    guard wasCancelled else {
      Issue.record("Expected receive cancellation to be reported distinctly")
      return
    }
    #expect(store.queue.pendingWaiterCount == 0)

    let lateAction = await store.receiveResult(timeout: .zero) { action in
      TestStoreActionMatch.matched(action)
    }
    guard case .matched(action: .value(13), value: _) = lateAction else {
      Issue.record("Expected the late action to remain available")
      return
    }
  }

  @Test("An expired deadline preserves valid actions behind stale buffered work")
  func expiredDeadlinePreservesValidActionAfterStaleBuffer() async {
    let store = TestStore(reducer: ReceiveFeature(), initialState: .init())
    let cancellationID = AnyEffectID(StaticEffectID("receive-buffered-deadline"))
    let sequence = store.nextSequence()
    let staleContext = store.makeEffectContext(
      sequence: sequence,
      cancellationIDs: [cancellationID],
      potentialCancellationIDs: [cancellationID]
    )
    store.deliverAction(.ignored, context: staleContext)
    _ = store.markCancelled(id: cancellationID, upTo: sequence)
    store.deliverAction(.value(21), context: nil)

    let timedOut = await store.receiveResult(timeout: .zero) { action in
      TestStoreActionMatch.matched(action)
    }
    guard case .timedOut(timeout: .zero) = timedOut else {
      Issue.record("Expected the deadline to stop after discarding the stale action")
      return
    }

    let preserved = await store.receiveResult(timeout: .zero) { action in
      TestStoreActionMatch.matched(action)
    }
    guard case .matched(action: .value(21), value: _) = preserved else {
      Issue.record("Expected the valid buffered action to remain available")
      return
    }
  }

  @Test("Invalidated actions do not reset the receive deadline")
  func invalidatedActionsDoNotResetReceiveDeadline() async {
    let store = TestStore(reducer: ReceiveFeature(), initialState: .init())
    let cancellationID = AnyEffectID(StaticEffectID("receive-total-deadline"))
    let sequence = store.nextSequence()
    let staleContext = store.makeEffectContext(
      sequence: sequence,
      cancellationIDs: [cancellationID],
      potentialCancellationIDs: [cancellationID]
    )
    let totalTimeout = Duration.seconds(5)
    let minimumConsumedBudget = Duration.milliseconds(50)
    var observedTimeouts: [Duration] = []
    var receiveResult: TestStoreReceiveResult<ReceiveFeature.Action, Void>?
    store.queue.waitTimeoutObserver = { observedTimeouts.append($0) }

    let receiving = Task { @MainActor in
      receiveResult = await store.receiveResult(timeout: totalTimeout) { _ in
        TestStoreActionMatch.matched(())
      }
    }

    let didInstallFirstWaiter = await waitUntil {
      observedTimeouts.count == 1 && store.queue.pendingWaiterCount == 1
    }
    guard didInstallFirstWaiter else {
      receiving.cancel()
      _ = await receiving.value
      store.queue.waitTimeoutObserver = nil
      Issue.record("Expected the initial receive waiter to be installed")
      return
    }

    try? await Task.sleep(for: .milliseconds(100))
    store.deliverAction(.ignored, context: staleContext)
    _ = store.markCancelled(id: cancellationID, upTo: sequence)

    let didInstallSecondWaiter = await waitUntil {
      observedTimeouts.count == 2 && store.queue.pendingWaiterCount == 1
    }
    receiving.cancel()
    _ = await receiving.value
    store.queue.waitTimeoutObserver = nil

    #expect(didInstallSecondWaiter)
    guard observedTimeouts.count == 2 else {
      Issue.record("Expected one wait budget before and after the invalidated action")
      return
    }
    guard case .cancelled = receiveResult else {
      Issue.record("Expected cancellation after observing the reused deadline")
      return
    }

    let consumedBudget = observedTimeouts[0] - observedTimeouts[1]
    #expect(observedTimeouts[1] > .zero)
    #expect(consumedBudget >= minimumConsumedBudget)
    #expect(store.queue.pendingWaiterCount == 0)
  }
}

private struct ExactReceiveFeature: Reducer {
  struct State: Equatable, Sendable {
    var count = 0
  }

  enum Action: Equatable, Sendable {
    case increment
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    state.count += 1
    return .none
  }
}

private struct ReceiveFeature: Reducer {
  struct ChildState: Equatable, Sendable {
    var values: [Int] = []
  }

  struct State: Equatable, Sendable {
    var values: [Int] = []
    var optionalReceiveCount = 0
    var lastOptionalWasNil = false
    var child = ChildState()
    var reductionCount = 0
  }

  enum ChildAction: Sendable {
    case value(Int)

    static let valueCasePath = CasePath<Self, Int>(
      embed: Self.value,
      extract: { action in
        guard case .value(let payload) = action else { return nil }
        return payload
      }
    )
  }

  enum Action: Sendable {
    case value(Int)
    case optional(Int?)
    case child(ChildAction)
    case ignored

    static let valueCasePath = CasePath<Self, Int>(
      embed: Self.value,
      extract: { action in
        guard case .value(let payload) = action else { return nil }
        return payload
      }
    )

    static let optionalCasePath = CasePath<Self, Int?>(
      embed: Self.optional,
      extract: { action in
        guard case .optional(let payload) = action else { return nil }
        return .some(payload)
      }
    )

    static let childCasePath = CasePath<Self, ChildAction>(
      embed: Self.child,
      extract: { action in
        guard case .child(let childAction) = action else { return nil }
        return childAction
      }
    )
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    state.reductionCount += 1
    switch action {
    case .value(let payload):
      state.values.append(payload)
    case .optional(let payload):
      state.optionalReceiveCount += 1
      state.lastOptionalWasNil = payload == nil
    case .child(.value(let payload)):
      state.child.values.append(payload)
    case .ignored:
      break
    }
    return .none
  }
}

private final class ReceiveExtractionCounter: Sendable {
  private let storage = OSAllocatedUnfairLock<Int>(initialState: 0)

  var count: Int {
    storage.withLock { $0 }
  }

  func increment() {
    storage.withLock { $0 += 1 }
  }
}
