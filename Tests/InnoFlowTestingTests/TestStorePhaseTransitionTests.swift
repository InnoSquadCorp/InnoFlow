// MARK: - TestStorePhaseTransitionTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import InnoFlowCore
import InnoFlowTesting
import Testing
import os

// A phase helper — `send` or `receive` with `tracking:through:`, or with
// `through:` a `PhaseMap` — checks the transition its action makes: from the
// phase right before that action is reduced to the phase right after.
//
// One call can reduce more than that action. A `send` first reduces the
// buffered effect actions, and a non-exhaustive `receive` reduces the actions
// it skips. A helper that reads the earlier phase before the call counts
// those reductions as part of its action's transition: two transitions the
// graph allows look like one it does not, a transition the graph does not
// allow goes unreported when the combined one is allowed or ends where it
// began, and a transition another action made is reported as this action's.
// The helper does not check the transitions of those other actions.
//
// The tests on a leading action take `Lead` as an argument. `.beforeTheCall`
// is the control: the same reductions with nothing reduced inside the call.
// The helper must report the same in both.

@Suite("TestStore phase transition helpers", .timeLimit(.minutes(5)))
@MainActor
struct TestStorePhaseTransitionTests {
  /// Where the action ahead of the checked one is reduced.
  enum Lead: CaseIterable, Sendable {
    /// Inside the helper call: a send reduces it first, and a non-exhaustive
    /// receive skips it.
    case insideTheCall
    /// By a `receive` of its own, before the helper call.
    case beforeTheCall
  }

  private typealias Direct = DirectPhaseFeature

  private static let sendFailure = "Illegal phase transition detected."
  private static let receiveFailure =
    "Illegal phase transition detected while receiving effect action."

  // MARK: - send

  @Test(
    "send checks the sent action's transition, not the drained action's with it",
    arguments: Lead.allCases)
  func sendBehindLeadingActionAllowsEachAllowedStep(lead: Lead) async {
    let store = TestStore(reducer: Direct())
    store.exhaustivity = .off
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }
    store.deliverAction(.begin, context: nil)
    if lead == .beforeTheCall { await store.receive(.begin) }

    // idle → loading, then loading → loaded: idle → loaded is not an edge.
    await store.send(.load, tracking: \.phase, through: Direct.linear)

    await store.finish()
    #expect(store.state.phase == .loaded)
    #expect(failures == [])
  }

  @Test(
    "send reports a transition the graph does not allow behind a drained action",
    arguments: Lead.allCases)
  func sendBehindLeadingActionReportsIllegalStep(lead: Lead) async {
    let store = TestStore(reducer: Direct())
    store.exhaustivity = .off
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }
    store.deliverAction(.begin, context: nil)
    if lead == .beforeTheCall { await store.receive(.begin) }

    // idle → loading, then loading → failed: idle → failed is an edge.
    await store.send(.fail, tracking: \.phase, through: Direct.deadEnd)

    await store.finish()
    #expect(store.state.phase == .failed)
    #expect(
      failures == [
        illegalTransition(Self.sendFailure, action: "fail", from: "loading", to: "failed")
      ])
  }

  @Test(
    "send reports a transition back to the phase a drained action left",
    arguments: Lead.allCases)
  func sendBehindLeadingActionReportsIllegalStepBack(lead: Lead) async {
    let store = TestStore(reducer: Direct())
    store.exhaustivity = .off
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }
    store.deliverAction(.begin, context: nil)
    if lead == .beforeTheCall { await store.receive(.begin) }

    // idle → loading, then loading → idle: the call ends where it began.
    await store.send(.reset, tracking: \.phase, through: Direct.oneWay)

    await store.finish()
    #expect(store.state.phase == .idle)
    #expect(
      failures == [
        illegalTransition(Self.sendFailure, action: "reset", from: "loading", to: "idle")
      ])
  }

  @Test("send does not check the transition of the action it drains", arguments: Lead.allCases)
  func sendChecksNoTransitionOfLeadingAction(lead: Lead) async {
    let store = TestStore(reducer: Direct())
    store.exhaustivity = .off
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }
    store.deliverAction(.begin, context: nil)
    if lead == .beforeTheCall { await store.receive(.begin) }

    // idle → loading is not an edge, but `ping` does not make it.
    await store.send(.ping, tracking: \.phase, through: Direct.noEdges)

    await store.finish()
    #expect(store.state.phase == .loading)
    #expect(failures == [])
  }

  @Test("an exhaustive send behind an unreceived action reports that action only")
  func exhaustiveSendBehindUnreceivedActionReportsItOnly() async {
    let store = TestStore(reducer: Direct())
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }
    store.deliverAction(.begin, context: nil)

    await store.send(.load, tracking: \.phase, through: Direct.linear) {
      $0.phase = .loaded
    }

    await store.finish()
    #expect(store.state.phase == .loaded)
    #expect(failures.count == 1)
    #expect(failures.first?.contains("1 effect action(s) before a new action was sent") == true)
  }

  // MARK: - receive

  @Test(
    "receive checks the received action's transition, not the skipped action's with it",
    arguments: Lead.allCases, [false, true])
  func receiveBehindLeadingActionAllowsEachAllowedStep(lead: Lead, usesTimeout: Bool) async {
    let store = TestStore(reducer: Direct())
    store.exhaustivity = .off
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }
    store.deliverAction(.begin, context: nil)
    store.deliverAction(.load, context: nil)
    if lead == .beforeTheCall { await store.receive(.begin) }

    // idle → loading, then loading → loaded: idle → loaded is not an edge.
    await receive(.load, on: store, through: Direct.linear, usesTimeout: usesTimeout)

    await store.finish()
    #expect(store.state.phase == .loaded)
    #expect(failures == [])
  }

  @Test(
    "receive reports a transition the graph does not allow behind a skipped action",
    arguments: Lead.allCases, [false, true])
  func receiveBehindLeadingActionReportsIllegalStep(lead: Lead, usesTimeout: Bool) async {
    let store = TestStore(reducer: Direct())
    store.exhaustivity = .off
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }
    store.deliverAction(.begin, context: nil)
    store.deliverAction(.fail, context: nil)
    if lead == .beforeTheCall { await store.receive(.begin) }

    // idle → loading, then loading → failed: idle → failed is an edge.
    await receive(.fail, on: store, through: Direct.deadEnd, usesTimeout: usesTimeout)

    await store.finish()
    #expect(store.state.phase == .failed)
    #expect(
      failures == [
        illegalTransition(Self.receiveFailure, action: "fail", from: "loading", to: "failed")
      ])
  }

  @Test(
    "receive reports a transition back to the phase a skipped action left",
    arguments: Lead.allCases, [false, true])
  func receiveBehindLeadingActionReportsIllegalStepBack(lead: Lead, usesTimeout: Bool) async {
    let store = TestStore(reducer: Direct())
    store.exhaustivity = .off
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }
    store.deliverAction(.begin, context: nil)
    store.deliverAction(.reset, context: nil)
    if lead == .beforeTheCall { await store.receive(.begin) }

    // idle → loading, then loading → idle: the call ends where it began.
    await receive(.reset, on: store, through: Direct.oneWay, usesTimeout: usesTimeout)

    await store.finish()
    #expect(store.state.phase == .idle)
    #expect(
      failures == [
        illegalTransition(Self.receiveFailure, action: "reset", from: "loading", to: "idle")
      ])
  }

  @Test(
    "receive does not check the transition of the action it skips",
    arguments: Lead.allCases, [false, true])
  func receiveChecksNoTransitionOfLeadingAction(lead: Lead, usesTimeout: Bool) async {
    let store = TestStore(reducer: Direct())
    store.exhaustivity = .off
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }
    store.deliverAction(.begin, context: nil)
    store.deliverAction(.ping, context: nil)
    if lead == .beforeTheCall { await store.receive(.begin) }

    // idle → loading is not an edge, but `ping` does not make it.
    await receive(.ping, on: store, through: Direct.noEdges, usesTimeout: usesTimeout)

    await store.finish()
    #expect(store.state.phase == .loading)
    #expect(failures == [])
  }

  @Test(
    "an exhaustive receive that gets another action checks no transition",
    arguments: [false, true])
  func exhaustiveReceiveOfAnotherActionChecksNoTransition(usesTimeout: Bool) async {
    let store = TestStore(reducer: Direct())
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }
    store.deliverAction(.begin, context: nil)

    // `begin` arrives instead and is reduced; `load` is never reduced, so the
    // transition `begin` makes is not `load`'s.
    await receive(.load, on: store, through: Direct.noEdges, usesTimeout: usesTimeout)

    await store.finish()
    #expect(store.state.phase == .loading)
    #expect(failures.count == 1)
    #expect(failures.first?.contains("Received unexpected action.") == true)
  }

  // MARK: - PhaseMap

  @Test(
    "a map-owned phase passes a receive behind a skipped action",
    arguments: Lead.allCases, [false, true])
  func mappedReceiveBehindLeadingAction(lead: Lead, usesTimeout: Bool) async {
    let map = MappedPhaseFeature.phaseMap
    let store = TestStore(reducer: MappedPhaseFeature())
    store.exhaustivity = .off
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }
    await store.send(.start, through: map)
    if lead == .beforeTheCall { await store.receive(._connected, through: map) }

    // connecting → loading, then loading → loaded: the map declares both,
    // and no connecting → loaded.
    if usesTimeout {
      await store.receive(._loaded, through: map, timeout: .seconds(60))
    } else {
      await store.receive(._loaded, through: map)
    }

    await store.finish()
    #expect(store.state.phase == .loaded)
    #expect(failures == [])
  }

  @Test("a map-owned phase passes a send behind a drained action", arguments: Lead.allCases)
  func mappedSendBehindLeadingAction(lead: Lead) async {
    let map = MappedPhaseFeature.phaseMap
    let store = TestStore(reducer: MappedPhaseFeature())
    store.exhaustivity = .off
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }
    await store.send(.start, through: map)
    await store.receive(._connected, through: map)
    if lead == .beforeTheCall { await store.receive(._loaded, through: map) }

    // loading → loaded, then loaded → idle: the map declares both, and no
    // loading → idle.
    await store.send(.reset, through: map)

    await store.finish()
    #expect(store.state.phase == .idle)
    #expect(failures == [])
  }

  // MARK: - Reporting

  @Test("a phase failure follows the state assertion of the same reduction")
  func phaseFailureFollowsStateAssertion() async {
    let store = TestStore(reducer: Direct())
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }

    // Neither call describes the state change it makes.
    await store.send(.load, tracking: \.phase, through: Direct.noEdges)
    store.deliverAction(.begin, context: nil)
    await store.receive(.begin, tracking: \.phase, through: Direct.noEdges)

    await store.finish()
    #expect(failures.count == 4)
    guard failures.count == 4 else { return }
    #expect(failures[0].contains("State mismatch after action."))
    #expect(
      failures[1]
        == illegalTransition(Self.sendFailure, action: "load", from: "idle", to: "loaded"))
    #expect(failures[2].contains("State mismatch after receiving action."))
    #expect(
      failures[3]
        == illegalTransition(Self.receiveFailure, action: "begin", from: "loaded", to: "loading"))
  }

  @Test("a phase failure is recorded at the helper's call site by the default reporter")
  func phaseFailureUsesCallSite() async {
    let store = TestStore(reducer: Direct())
    store.exhaustivity = .off
    let matchedIssues = OSAllocatedUnfairLock(initialState: 0)
    let expectedMessage = illegalTransition(
      Self.sendFailure, action: "load", from: "idle", to: "loaded")

    await withKnownIssue("An intentional illegal transition verifies the real reporter") {
      await store.send(
        .load, tracking: \.phase, through: Direct.noEdges,
        fileID: "PhaseTests/Explicit.swift", filePath: "/fixtures/Explicit.swift", line: 73,
        column: 5)
    } matching: { issue in
      guard let error = issue.error,
        String(describing: error) == expectedMessage,
        issue.sourceLocation
          == SourceLocation(
            fileID: "PhaseTests/Explicit.swift", filePath: "/fixtures/Explicit.swift", line: 73,
            column: 5)
      else { return false }
      return matchedIssues.withLock { count in
        count += 1
        return count == 1
      }
    }

    #expect(matchedIssues.withLock { $0 } == 1)
    await store.finish()
  }

  // MARK: - Helpers

  /// Receives through the overload with or without a per-assertion timeout.
  /// The action is already buffered, so the timeout is never waited for.
  private func receive(
    _ action: Direct.Action,
    on store: TestStore<Direct>,
    through graph: Direct.Graph,
    usesTimeout: Bool
  ) async {
    if usesTimeout {
      await store.receive(action, tracking: \.phase, through: graph, timeout: .seconds(60))
    } else {
      await store.receive(action, tracking: \.phase, through: graph)
    }
  }
}

/// The failure a phase helper reports for a transition out of a phase that
/// has no successor in the graph.
private func illegalTransition(
  _ failure: String, action: String, from: String, to: String
) -> String {
  """
  \(failure)

  Action:
  \(action)

  From:
  \(from)

  To:
  \(to)

  Allowed next phases:
  []
  """
}

/// Writes its phase directly, so a test can make any transition. Each action
/// enters one phase, whether the test sends it or an effect delivers it.
private struct DirectPhaseFeature: Reducer {
  typealias Graph = PhaseTransitionGraph<Phase>

  enum Phase: String, Hashable, Sendable {
    case idle
    case loading
    case loaded
    case failed
  }

  struct State: Equatable, Sendable, DefaultInitializable {
    var phase: Phase = .idle
  }

  enum Action: Equatable, Sendable {
    /// Enters `loading`.
    case begin
    /// Enters `loaded`.
    case load
    /// Enters `failed`.
    case fail
    /// Enters `idle`.
    case reset
    /// Leaves the phase where it is.
    case ping
  }

  /// idle → loading → loaded.
  static let linear: Graph = [.idle: [.loading], .loading: [.loaded]]
  /// idle → loading and idle → failed; nothing leaves `loading`.
  static let deadEnd: Graph = [.idle: [.loading, .failed]]
  /// idle → loading only.
  static let oneWay: Graph = [.idle: [.loading]]
  /// No transition at all.
  static let noEdges = Graph([:])

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .begin:
      state.phase = .loading
    case .load:
      state.phase = .loaded
    case .fail:
      state.phase = .failed
    case .reset:
      state.phase = .idle
    case .ping:
      break
    }
    return .none
  }
}

/// A `PhaseMap` owns the phase, so every transition the reducer makes is one
/// the map declares, and a helper checking against that map reports none.
private struct MappedPhaseFeature: Reducer {
  enum Phase: String, Hashable, Sendable {
    case idle
    case connecting
    case loading
    case loaded
  }

  struct State: Equatable, Sendable, DefaultInitializable {
    var phase: Phase = .idle
  }

  enum Action: Equatable, Sendable {
    case start
    case _connected
    case _loaded
    case reset
  }

  static var phaseMap: PhaseMap<State, Action, Phase> {
    PhaseMap(\.phase) {
      From(.idle) {
        On(.start, to: .connecting)
      }
      From(.connecting) {
        On(._connected, to: .loading)
      }
      From(.loading) {
        On(._loaded, to: .loaded)
      }
      From(.loaded) {
        On(.reset, to: .idle)
      }
    }
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    Reduce<State, Action, Never> { _, action in
      switch action {
      case .start:
        return .send(._connected)
      case ._connected:
        return .send(._loaded)
      case ._loaded, .reset:
        return .none
      }
    }.phaseMap(Self.phaseMap).reduce(into: &state, action: action)
  }
}
