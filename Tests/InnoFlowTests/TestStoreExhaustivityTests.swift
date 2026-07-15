// MARK: - TestStoreExhaustivityTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Testing

@testable import InnoFlowCore
@testable import InnoFlowTesting

@Suite("TestStore Exhaustivity Tests", .serialized)
@MainActor
struct TestStoreExhaustivityTests {
  @Test("exhaustivity defaults to on and scoped stores forward it")
  func exhaustivityDefaultsToOnAndScopesForwardIt() {
    let store = TestStore(reducer: ExhaustivityStateFeature())
    let child = store.scope(
      state: \ExhaustivityStateFeature.State.child,
      action: ExhaustivityStateFeature.Action.childCasePath
    )

    requireSendable(Exhaustivity.on)
    #expect(store.exhaustivity == .on)
    #expect(child.exhaustivity == .on)
    #expect(Exhaustivity.off == .off(showSkippedAssertions: false))

    child.exhaustivity = .off(showSkippedAssertions: true)

    #expect(store.exhaustivity == .off(showSkippedAssertions: true))
    #expect(child.exhaustivity == .off(showSkippedAssertions: true))
  }

  @Test("exhaustive send treats an omitted assertion as no state change")
  func exhaustiveSendWithoutAssertionReportsStateChange() async {
    let store = TestStore(reducer: ExhaustivityStateFeature())
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }

    await store.send(.mutateBoth)

    #expect(store.state.count == 1)
    #expect(store.state.note == "updated")
    #expect(failures.count == 1)
    #expect(failures[0].contains("State mismatch after action"))
  }

  @Test("exhaustive receive treats an omitted assertion as no state change")
  func exhaustiveReceiveWithoutAssertionReportsStateChange() async {
    let store = TestStore(reducer: ExhaustivityStateFeature())
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }
    store.deliverAction(.mutateBoth, context: nil)

    await store.receive(.mutateBoth, timeout: .zero)

    #expect(store.state.count == 1)
    #expect(store.state.note == "updated")
    #expect(failures.count == 1)
    #expect(failures[0].contains("State mismatch after receiving action"))
  }

  @Test("exhaustive assertions must describe the complete transition")
  func exhaustiveAssertionRequiresWholeState() async {
    let store = TestStore(reducer: ExhaustivityStateFeature())
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }

    await store.send(.mutateBoth) {
      $0.count = 1
    }

    #expect(failures.count == 1)
    #expect(failures[0].contains("note"))
  }

  @Test("non-exhaustive assertions are partial and start from actual state")
  func nonExhaustiveAssertionsArePartial() async {
    let store = TestStore(reducer: ExhaustivityStateFeature())
    store.exhaustivity = .off
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }

    await store.send(.mutateBoth) {
      $0.count = 1
    }

    #expect(failures.isEmpty)
    #expect(store.state == .init(count: 1, note: "updated"))

    await store.send(.mutateBoth)

    #expect(failures.isEmpty)
    #expect(store.state == .init(count: 2, note: "updated"))
  }

  @Test("non-exhaustive assertions still reject incorrect values")
  func nonExhaustiveIncorrectAssertionFails() async {
    let store = TestStore(reducer: ExhaustivityStateFeature())
    store.exhaustivity = .off
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }

    await store.send(.mutateBoth) {
      $0.count = 999
    }

    #expect(failures.count == 1)
    #expect(failures[0].contains("expected 999"))
  }

  @Test("non-exhaustive warning mode reports omitted state assertions")
  func warningModeReportsSkippedStateAssertions() async {
    let store = TestStore(reducer: ExhaustivityStateFeature())
    store.exhaustivity = .off(showSkippedAssertions: true)
    var warnings: [String] = []
    store.skippedAssertionReporter = { message, _, _ in warnings.append(message) }

    await store.send(.mutateBoth) {
      $0.count = 1
    }

    #expect(warnings.count == 1)
    #expect(warnings[0].contains("checked non-exhaustively"))
    #expect(warnings[0].contains("note"))
  }

  @Test("warning mode evaluates the assertion closure exactly once")
  func warningModeEvaluatesAssertionOnce() async {
    let store = TestStore(reducer: ExhaustivityStateFeature())
    store.exhaustivity = .off(showSkippedAssertions: true)
    store.skippedAssertionReporter = { _, _, _ in }
    var assertionCount = 0

    await store.send(.mutateBoth) {
      assertionCount += 1
      $0.count = 1
    }

    #expect(assertionCount == 1)
  }

  @Test("scoped exhaustive assertions compare the full root state")
  func scopedExhaustiveAssertionComparesRootState() async {
    let store = TestStore(reducer: ExhaustivityStateFeature())
    let child = store.scope(
      state: \ExhaustivityStateFeature.State.child,
      action: ExhaustivityStateFeature.Action.childCasePath
    )
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }

    await child.send(.increment) {
      $0.count = 1
    }

    #expect(store.state.child.count == 1)
    #expect(store.state.parentCount == 1)
    #expect(failures.count == 1)
    #expect(failures[0].contains("parentCount"))
    #expect(failures[0].contains("parent TestStore"))
  }

  @Test("scoped non-exhaustive assertions remain partial")
  func scopedNonExhaustiveAssertionIsPartial() async {
    let store = TestStore(reducer: ExhaustivityStateFeature())
    let child = store.scope(
      state: \ExhaustivityStateFeature.State.child,
      action: ExhaustivityStateFeature.Action.childCasePath
    )
    child.exhaustivity = .off
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }

    await child.send(.increment) {
      $0.count = 1
    }

    #expect(failures.isEmpty)
    #expect(store.state.child.count == 1)
    #expect(store.state.parentCount == 1)
  }

  @Test("non-exhaustive collection removal reports instead of trapping")
  func collectionRemovalReportsUnavailableScopedAssertion() async {
    let store = TestStore(reducer: ExhaustivityRemovalFeature())
    store.exhaustivity = .off
    let row = store.scope(
      collection: \ExhaustivityRemovalFeature.State.rows,
      id: 1,
      action: ExhaustivityRemovalFeature.Action.rowActionPath
    )
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }

    await row.send(.remove) {
      $0.value = 1
    }

    #expect(store.state.rows.isEmpty)
    #expect(failures.count == 1)
    #expect(failures[0].contains("no longer present"))
    #expect(failures[0].contains("parent TestStore"))
  }

  @Test("exhaustive send reports and reduces every pending effect action")
  func exhaustiveSendReportsAndReducesPendingActions() async {
    let store = TestStore(reducer: ExhaustivityActionFeature())
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }

    await store.send(.beginPending)
    await store.send(.manual) {
      $0.events.append("manual")
    }

    #expect(store.state.events == ["unexpected", "followUp", "manual"])
    #expect(failures.count == 1)
    #expect(failures[0].contains("2 effect action(s)"))
    #expect(failures[0].contains("unexpectedWithFollowUp"))
    #expect(failures[0].contains("followUp"))
  }

  @Test("non-exhaustive send drains pending actions without failing")
  func nonExhaustiveSendDrainsPendingActions() async {
    let store = TestStore(reducer: ExhaustivityActionFeature())
    store.exhaustivity = .off
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }

    await store.send(.beginPending)
    await store.send(.manual)

    #expect(store.state.events == ["unexpected", "followUp", "manual"])
    #expect(failures.isEmpty)
  }

  @Test("send bounds a recursively emitted pending action")
  func sendBoundsRecursivePendingAction() async {
    let store = TestStore(
      reducer: ExhaustivityActionFeature(),
      effectTimeout: .milliseconds(5)
    )
    store.exhaustivity = .off
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }
    store.deliverAction(.loop, context: nil)

    await store.send(.manual) {
      $0.events = ["manual"]
    }

    #expect(store.state.events == ["manual"])
    #expect(failures.count == 1)
    #expect(failures[0].contains("Timed out draining effect actions"))
    #expect(failures[0].contains("Remaining effect work was cancelled"))
  }

  @Test("warning mode reports pending actions without failing")
  func warningModeReportsPendingActions() async {
    let store = TestStore(reducer: ExhaustivityActionFeature())
    store.exhaustivity = .off(showSkippedAssertions: true)
    var failures: [String] = []
    var warnings: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }
    store.skippedAssertionReporter = { message, _, _ in warnings.append(message) }

    await store.send(.beginPending)
    await store.send(.manual)

    let actionWarnings = warnings.filter { $0.contains("before sending a new action") }
    #expect(actionWarnings.count == 1)
    #expect(actionWarnings[0].contains("2 effect action(s)"))
    #expect(failures.isEmpty)
  }

  @Test("exhaustive receive applies a mismatch and preserves the target")
  func exhaustiveReceiveAppliesMismatchAndPreservesTarget() async {
    let store = TestStore(reducer: ExhaustivityActionFeature())
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }
    store.deliverAction(.unexpectedWithFollowUp, context: nil)
    store.deliverAction(.target, context: nil)

    await store.receive(.target, timeout: .zero)

    #expect(store.state.events == ["unexpected"])
    #expect(failures.count == 1)
    #expect(failures[0].contains("Received unexpected action"))

    await store.receive(.target, timeout: .zero) {
      $0.events.append("target")
    }
    await store.receive(.followUp, timeout: .zero) {
      $0.events.append("followUp")
    }

    #expect(store.state.events == ["unexpected", "target", "followUp"])
    #expect(failures.count == 1)
  }

  @Test("non-exhaustive receive walks effects from skipped actions")
  func nonExhaustiveReceiveWalksSkippedEffects() async {
    let store = TestStore(reducer: ExhaustivityActionFeature())
    store.exhaustivity = .off
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }
    store.deliverAction(.unexpectedWithFollowUp, context: nil)

    await store.receive(.followUp, timeout: .seconds(1)) {
      $0.events = ["unexpected", "followUp"]
    }

    #expect(store.state.events == ["unexpected", "followUp"])
    #expect(failures.isEmpty)
  }

  @Test("non-exhaustive receive keeps one total deadline and preserves the target")
  func nonExhaustiveReceivePreservesTargetAfterDeadline() async {
    let store = TestStore(reducer: ExhaustivityActionFeature())
    store.exhaustivity = .off
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }
    store.deliverAction(.unexpected, context: nil)
    store.deliverAction(.target, context: nil)

    await store.receive(.target, timeout: .zero)

    #expect(store.state.events == ["unexpected"])
    #expect(failures.count == 1)
    #expect(failures[0].contains("timed out"))

    await store.receive(.target, timeout: .zero) {
      $0.events = ["unexpected", "target"]
    }

    #expect(store.state.events == ["unexpected", "target"])
    #expect(failures.count == 1)
  }

  @Test("scoped non-exhaustive receive skips parent and child mismatches")
  func scopedNonExhaustiveReceiveSkipsMismatches() async {
    let store = TestStore(reducer: ExhaustivityActionFeature())
    store.exhaustivity = .off
    let child = store.scope(
      state: \ExhaustivityActionFeature.State.child,
      action: ExhaustivityActionFeature.Action.childCasePath
    )
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }
    store.deliverAction(.parentNoise, context: nil)
    store.deliverAction(.child(.noise), context: nil)
    store.deliverAction(.child(.target), context: nil)

    await child.receive(.target, timeout: .seconds(1)) {
      $0.events = ["noise", "target"]
    }

    #expect(store.state.events == ["parentNoise"])
    #expect(store.state.child.events == ["noise", "target"])
    #expect(failures.isEmpty)
  }

  @Test("scoped exhaustive receive applies a parent mismatch and preserves the target")
  func scopedExhaustiveReceiveAppliesParentMismatch() async {
    let store = TestStore(reducer: ExhaustivityActionFeature())
    let child = store.scope(
      state: \ExhaustivityActionFeature.State.child,
      action: ExhaustivityActionFeature.Action.childCasePath
    )
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }
    store.deliverAction(.parentNoise, context: nil)
    store.deliverAction(.child(.target), context: nil)

    await child.receive(.target, timeout: .zero)

    #expect(store.state.events == ["parentNoise"])
    #expect(store.state.child.events.isEmpty)
    #expect(failures.count == 1)
    #expect(failures[0].contains("unexpected parent action"))

    await child.receive(.target, timeout: .zero) {
      $0.events.append("target")
    }

    #expect(store.state.child.events == ["target"])
    #expect(failures.count == 1)
  }

  @Test("scoped send applies the parent exhaustivity policy")
  func scopedSendAppliesParentExhaustivityPolicy() async {
    let store = TestStore(reducer: ExhaustivityActionFeature())
    let child = store.scope(
      state: \ExhaustivityActionFeature.State.child,
      action: ExhaustivityActionFeature.Action.childCasePath
    )
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }

    await store.send(.beginPending)
    await child.send(.target) {
      $0.events.append("target")
    }

    #expect(store.state.events == ["unexpected", "followUp"])
    #expect(store.state.child.events == ["target"])
    #expect(failures.count == 1)
    #expect(failures[0].contains("2 effect action(s)"))
  }

  @Test("collection scope skips actions for sibling IDs in non-exhaustive mode")
  func collectionScopeSkipsSiblingActions() async {
    let store = TestStore(reducer: ExhaustivityActionFeature())
    store.exhaustivity = .off
    let firstRow = store.scope(
      collection: \ExhaustivityActionFeature.State.rows,
      id: 1,
      action: ExhaustivityActionFeature.Action.rowActionPath
    )
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }
    store.deliverAction(.row(id: 2, action: .noise), context: nil)
    store.deliverAction(.row(id: 1, action: .target), context: nil)

    await firstRow.receive(.target, timeout: .seconds(1)) {
      $0.events = ["target"]
    }

    #expect(store.state.rows[0].events == ["target"])
    #expect(store.state.rows[1].events == ["noise"])
    #expect(failures.isEmpty)
  }

  @Test("non-exhaustive finish drains actions and their follow-up effects")
  func nonExhaustiveFinishDrainsActionsAndEffects() async {
    let store = TestStore(reducer: ExhaustivityActionFeature())
    store.exhaustivity = .off

    await store.send(.beginPending)

    #expect(await store.finishResult(timeout: .seconds(1)) == .success)
    #expect(store.state.events == ["unexpected", "followUp"])
  }

  @Test("warning mode reports skipped receive and finish actions")
  func warningModeReportsReceiveAndFinishActions() async {
    let store = TestStore(reducer: ExhaustivityActionFeature())
    store.exhaustivity = .off(showSkippedAssertions: true)
    var warnings: [String] = []
    store.skippedAssertionReporter = { message, _, _ in warnings.append(message) }
    store.deliverAction(.unexpected, context: nil)
    store.deliverAction(.target, context: nil)

    await store.receive(.target, timeout: .seconds(1)) {
      $0.events = ["unexpected", "target"]
    }

    store.deliverAction(.unexpected, context: nil)
    #expect(await store.finishResult(timeout: .zero) == .success)

    #expect(warnings.filter { $0.contains("receiving another action") }.count == 1)
    #expect(warnings.filter { $0.contains("finishing") }.count == 1)
  }
}

private func requireSendable<T: Sendable>(_ value: T) {}

private struct ExhaustivityStateFeature: Reducer {
  struct ChildState: Equatable, Sendable {
    var count = 0
  }

  struct State: Equatable, Sendable, DefaultInitializable {
    var count = 0
    var note = ""
    var child = ChildState()
    var parentCount = 0
  }

  enum ChildAction: Equatable, Sendable {
    case increment
  }

  enum Action: Equatable, Sendable {
    case mutateBoth
    case child(ChildAction)

    static let childCasePath = CasePath<Self, ChildAction>(
      embed: Self.child,
      extract: { action in
        guard case .child(let childAction) = action else { return nil }
        return childAction
      }
    )
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .mutateBoth:
      state.count += 1
      state.note = "updated"

    case .child(.increment):
      state.child.count += 1
      state.parentCount += 1
    }
    return .none
  }
}

private struct ExhaustivityRemovalFeature: Reducer {
  struct Row: Equatable, Identifiable, Sendable {
    let id: Int
    var value = 0
  }

  struct State: Equatable, Sendable, DefaultInitializable {
    var rows = [Row(id: 1)]
  }

  enum RowAction: Equatable, Sendable {
    case remove
  }

  enum Action: Equatable, Sendable {
    case row(id: Int, action: RowAction)

    static let rowActionPath = CollectionActionPath<Self, Int, RowAction>(
      embed: Self.row,
      extract: { action in
        guard case .row(let id, let rowAction) = action else { return nil }
        return (id, rowAction)
      }
    )
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .row(let id, .remove):
      state.rows.removeAll { $0.id == id }
      return .none
    }
  }
}

private struct ExhaustivityActionFeature: Reducer {
  struct ChildState: Equatable, Sendable {
    var events: [String] = []
  }

  struct State: Equatable, Sendable, DefaultInitializable {
    var events: [String] = []
    var child = ChildState()
    var rows = [Row(id: 1), Row(id: 2)]
  }

  struct Row: Equatable, Identifiable, Sendable {
    let id: Int
    var events: [String] = []
  }

  enum ChildAction: Equatable, Sendable {
    case noise
    case target
  }

  enum RowAction: Equatable, Sendable {
    case noise
    case target
  }

  enum Action: Equatable, Sendable {
    case beginPending
    case unexpected
    case unexpectedWithFollowUp
    case followUp
    case manual
    case target
    case parentNoise
    case child(ChildAction)
    case row(id: Int, action: RowAction)
    case loop

    static let childCasePath = CasePath<Self, ChildAction>(
      embed: Self.child,
      extract: { action in
        guard case .child(let childAction) = action else { return nil }
        return childAction
      }
    )

    static let rowActionPath = CollectionActionPath<Self, Int, RowAction>(
      embed: Self.row,
      extract: { action in
        guard case .row(let id, let rowAction) = action else { return nil }
        return (id, rowAction)
      }
    )
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .beginPending:
      return .send(.unexpectedWithFollowUp)

    case .unexpected:
      state.events.append("unexpected")
      return .none

    case .unexpectedWithFollowUp:
      state.events.append("unexpected")
      return .send(.followUp)

    case .followUp:
      state.events.append("followUp")
      return .none

    case .manual:
      state.events.append("manual")
      return .none

    case .target:
      state.events.append("target")
      return .none

    case .parentNoise:
      state.events.append("parentNoise")
      return .none

    case .child(.noise):
      state.child.events.append("noise")
      return .none

    case .child(.target):
      state.child.events.append("target")
      return .none

    case .row(let id, let rowAction):
      guard let index = state.rows.firstIndex(where: { $0.id == id }) else {
        return .none
      }
      switch rowAction {
      case .noise:
        state.rows[index].events.append("noise")
      case .target:
        state.rows[index].events.append("target")
      }
      return .none

    case .loop:
      return .send(.loop)
    }
  }
}
