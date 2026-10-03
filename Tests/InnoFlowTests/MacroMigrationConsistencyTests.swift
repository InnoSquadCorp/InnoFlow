// MARK: - MacroMigrationConsistencyTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import InnoFlow
import Testing

@Suite("Macro migration consumers")
struct MacroMigrationConsistencyTests {
  @Test("Swift.Never retains the explicit output-free contract")
  func moduleQualifiedNeverCompiles() {
    var state = QualifiedNeverFeature.State()
    _ = QualifiedNeverFeature().reduce(into: &state, action: .go)
    #expect(state.count == 1)
  }

  @Test("legacy output-free effects can be repaired into a typed output feature")
  func promotedLegacyBodyCompiles() {
    var state = PromotedLegacyOutputFeature.State()
    _ = PromotedLegacyOutputFeature().reduce(into: &state, action: .go)
    #expect(state.count == 1)
  }

  @Test("strict totality follows the real compiler’s conditional configuration")
  func conditionalPhaseConsumer() {
    var state = ConditionalPhaseConsumer.State()
    _ = ConditionalPhaseConsumer().reduce(into: &state, action: .go)
    #if os(macOS)
      #expect(state.phase == .desktop)
    #else
      #expect(state.phase == .portable)
    #endif
  }
}

@InnoFlow
private struct QualifiedNeverFeature {
  struct State: Equatable, Sendable { var count = 0 }
  enum Action: Equatable, Sendable { case go }
  var body: some Reducer<State, Action, Swift.Never> {
    Reduce { state, _ in
      state.count += 1
      return .none
    }
  }
}

/// This is the explicit-reduce Fix-It shape for an old EffectTask-returning
/// method on a feature that already declares a nested Output.
@InnoFlow
private struct PromotedLegacyOutputFeature {
  struct State: Equatable, Sendable { var count = 0 }
  enum Action: Equatable, Sendable { case go }
  enum Output: Equatable, Sendable {
    @available(*, deprecated, renamed: "ready", message: "Use the new event")
    case old
    case ready
  }
  var body: some Reducer<State, Action, Output> {
    Reduce<State, Action, Never> { state, _ in
      state.count += 1
      return EffectTask<Action>.none
    }
    .promoteOutput(to: Output.self)
  }
}

@InnoFlow(phaseManaged: true, strictPhaseTotality: true)
private struct ConditionalPhaseConsumer {
  struct State: Equatable, Sendable {
    enum Phase: Hashable, Sendable {
      case idle
      #if os(macOS)
        case desktop
      #else
        case portable
      #endif
    }
    var phase: Phase = .idle
  }
  enum Action: Equatable, Sendable { case go }
  static var phaseMap: PhaseMap<State, Action, State.Phase> {
    PhaseMap(\State.phase) {
      From(.idle) {
        #if os(macOS)
          On(.go, to: .desktop)
        #else
          On(.go, to: .portable)
        #endif
      }
    }
  }
  var body: some Reducer<State, Action, Never> { Reduce { _, _ in .none } }
}
