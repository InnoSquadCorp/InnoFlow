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
