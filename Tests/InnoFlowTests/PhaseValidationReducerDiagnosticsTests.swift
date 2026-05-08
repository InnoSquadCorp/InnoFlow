// MARK: - PhaseValidationReducerDiagnosticsTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import Testing
import os

@testable import InnoFlow

private struct PhaseValidationFeature: Reducer {
  enum Phase: Hashable, Sendable {
    case idle
    case loading
    case loaded
    case failed
  }

  struct State: Equatable, Sendable, DefaultInitializable {
    var phase: Phase = .idle
  }

  enum Action: Equatable, Sendable {
    case forcePhase(Phase)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .forcePhase(let phase):
      state.phase = phase
      return .none
    }
  }
}

private let phaseGraph = PhaseTransitionGraph<PhaseValidationFeature.Phase>([
  .idle: [.loading],
  .loading: [.loaded, .failed],
  .failed: [.loading]
])

private final class ViolationProbe: Sendable {
  private let lock = OSAllocatedUnfairLock<[String]>(initialState: [])

  var events: [String] {
    lock.withLock { $0 }
  }

  func record(_ event: String) {
    lock.withLock { $0.append(event) }
  }
}

@Suite("PhaseValidationReducer diagnostics", .serialized)
@MainActor
struct PhaseValidationReducerDiagnosticsTests {

  @Test("Custom diagnostics reporter receives undeclared transitions in every build configuration")
  func diagnosticsReceivesUndeclaredTransitions() {
    let probe = ViolationProbe()
    let reducer = PhaseValidationFeature().validatePhaseTransitions(
      tracking: \.phase,
      through: phaseGraph,
      diagnostics: .init { violation in
        switch violation {
        case .undeclaredTransition(let action, let previous, let next, let allowed):
          probe.record(
            "violation:action=\(action) previous=\(previous) next=\(next) allowed=\(allowed.sorted(by: { "\($0)" < "\($1)" }))"
          )
        }
      }
    )

    var state = PhaseValidationFeature.State()
    // idle -> loaded is not declared (must go through loading first).
    _ = reducer.reduce(into: &state, action: .forcePhase(.loaded))

    #expect(probe.events.count == 1)
    let event = try! #require(probe.events.first)
    #expect(event.contains("previous=idle"))
    #expect(event.contains("next=") && event.contains(".loaded") || event.contains("next=loaded"))
    // The set may render as `[loading]` or `[Module.Type.Phase.loading]`
    // depending on type metadata visibility, so assert the substring.
    #expect(event.contains("loading"))
    // Reducer keeps the (now-violating) post-reduce state as-is.
    #expect(state.phase == .loaded)
  }

  @Test("Custom diagnostics reporter is silent on legal transitions")
  func diagnosticsSilentOnLegalTransitions() {
    let probe = ViolationProbe()
    let reducer = PhaseValidationFeature().validatePhaseTransitions(
      tracking: \.phase,
      through: phaseGraph,
      diagnostics: .init { _ in
        probe.record("unexpected")
      }
    )

    var state = PhaseValidationFeature.State()
    _ = reducer.reduce(into: &state, action: .forcePhase(.loading))
    _ = reducer.reduce(into: &state, action: .forcePhase(.loaded))

    #expect(probe.events.isEmpty)
    #expect(state.phase == .loaded)
  }

  @Test("Same-phase actions never trigger diagnostics")
  func samePhaseActionsAreNotReported() {
    let probe = ViolationProbe()
    let reducer = PhaseValidationFeature().validatePhaseTransitions(
      tracking: \.phase,
      through: phaseGraph,
      diagnostics: .init { _ in
        probe.record("unexpected")
      }
    )

    var state = PhaseValidationFeature.State()
    _ = reducer.reduce(into: &state, action: .forcePhase(.idle))

    #expect(probe.events.isEmpty)
    #expect(state.phase == .idle)
  }

  @Test("Default .disabled diagnostics keeps legacy behavior on legal transitions")
  func defaultDiagnosticsLegalTransitionsCompile() {
    // The .disabled default still relies on `assertionFailure` for illegal
    // transitions, which traps under debug. We exercise only the legal path
    // here to guard the public default surface from regressing in source.
    let reducer = PhaseValidationFeature().validatePhaseTransitions(
      tracking: \.phase,
      through: phaseGraph
    )

    var state = PhaseValidationFeature.State()
    _ = reducer.reduce(into: &state, action: .forcePhase(.loading))
    #expect(state.phase == .loading)
  }
}
