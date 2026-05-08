// MARK: - PhaseValidationReducerDiagnosticsTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import OSLog
import Testing
import os

@testable import InnoFlowCore

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
  .failed: [.loading],
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

private final class DescriptionCounter: Sendable {
  private let lock = OSAllocatedUnfairLock<Int>(initialState: 0)

  var count: Int {
    lock.withLock { $0 }
  }

  func increment() {
    lock.withLock { $0 += 1 }
  }
}

private struct DescriptionCountingAction: Sendable, CustomStringConvertible {
  let counter: DescriptionCounter

  var description: String {
    counter.increment()
    return "sensitive-action"
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

  @Test(".sink forwards undeclared transitions to the supplied closure")
  func sinkForwardsUndeclaredTransitions() {
    let probe = ViolationProbe()
    let reducer = PhaseValidationFeature().validatePhaseTransitions(
      tracking: \.phase,
      through: phaseGraph,
      diagnostics: .sink { violation in
        switch violation {
        case .undeclaredTransition(_, let previous, let next, _):
          probe.record("previous=\(previous) next=\(next)")
        }
      }
    )

    var state = PhaseValidationFeature.State()
    _ = reducer.reduce(into: &state, action: .forcePhase(.loaded))

    #expect(probe.events.count == 1)
    #expect(probe.events.first?.contains("previous=idle") == true)
  }

  @Test(".combined fans out to every diagnostics adapter")
  func combinedFansOut() {
    let firstProbe = ViolationProbe()
    let secondProbe = ViolationProbe()
    let reducer = PhaseValidationFeature().validatePhaseTransitions(
      tracking: \.phase,
      through: phaseGraph,
      diagnostics: .combined(
        .sink { _ in firstProbe.record("first") },
        .sink { _ in secondProbe.record("second") }
      )
    )

    var state = PhaseValidationFeature.State()
    _ = reducer.reduce(into: &state, action: .forcePhase(.loaded))

    #expect(firstProbe.events == ["first"])
    #expect(secondProbe.events == ["second"])
  }

  @Test(".combined without active reporters preserves disabled semantics")
  func combinedWithoutActiveReportersRemainsDisabled() {
    let empty:
      PhaseValidationDiagnostics<
        PhaseValidationFeature.Action,
        PhaseValidationFeature.Phase
      > = .combined()
    let disabledOnly:
      PhaseValidationDiagnostics<
        PhaseValidationFeature.Action,
        PhaseValidationFeature.Phase
      > = .combined(.disabled)

    #expect(empty.report == nil)
    #expect(disabledOnly.report == nil)
  }

  @Test(".osLog and .signpost adapters evaluate without crashing")
  func standardLoggingAdaptersEvaluate() {
    let logger = Logger(subsystem: "InnoFlowTests", category: "phaseValidationDiagnostics")
    let signposter = OSSignposter(
      subsystem: "InnoFlowTests", category: "phaseValidationDiagnostics")
    let reducer = PhaseValidationFeature().validatePhaseTransitions(
      tracking: \.phase,
      through: phaseGraph,
      diagnostics: .combined(
        .osLog(logger: logger),
        .signpost(signposter: signposter)
      )
    )

    var state = PhaseValidationFeature.State()
    _ = reducer.reduce(into: &state, action: .forcePhase(.loaded))
  }

  @Test(".osLog redaction does not evaluate action descriptions")
  func osLogRedactionDoesNotEvaluateActionDescription() {
    let counter = DescriptionCounter()
    let logger = Logger(subsystem: "InnoFlowTests", category: "phaseValidationDiagnostics")
    let diagnostics:
      PhaseValidationDiagnostics<
        DescriptionCountingAction,
        PhaseValidationFeature.Phase
      > = .osLog(logger: logger)

    diagnostics.report?(
      .undeclaredTransition(
        action: DescriptionCountingAction(counter: counter),
        previousPhase: .idle,
        nextPhase: .loaded,
        allowedNextPhases: [.loading]
      )
    )

    #expect(counter.count == 0)
  }

  @Test(".signpost redaction does not evaluate action descriptions")
  func signpostRedactionDoesNotEvaluateActionDescription() {
    let counter = DescriptionCounter()
    let signposter = OSSignposter(
      subsystem: "InnoFlowTests", category: "phaseValidationDiagnostics")
    let diagnostics:
      PhaseValidationDiagnostics<
        DescriptionCountingAction,
        PhaseValidationFeature.Phase
      > = .signpost(signposter: signposter)

    diagnostics.report?(
      .undeclaredTransition(
        action: DescriptionCountingAction(counter: counter),
        previousPhase: .idle,
        nextPhase: .loaded,
        allowedNextPhases: [.loading]
      )
    )

    #expect(counter.count == 0)
  }

  @Test(".osLog includeActionPayload evaluates action descriptions")
  func osLogIncludeActionPayloadEvaluatesActionDescription() {
    let counter = DescriptionCounter()
    let logger = Logger(subsystem: "InnoFlowTests", category: "phaseValidationDiagnostics")
    let diagnostics:
      PhaseValidationDiagnostics<
        DescriptionCountingAction,
        PhaseValidationFeature.Phase
      > = .osLog(logger: logger, includeActionPayload: true)

    diagnostics.report?(
      .undeclaredTransition(
        action: DescriptionCountingAction(counter: counter),
        previousPhase: .idle,
        nextPhase: .loaded,
        allowedNextPhases: [.loading]
      )
    )

    #expect(counter.count == 1)
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
