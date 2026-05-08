// MARK: - PhaseTransitionGraphTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import Testing
import os

@testable import InnoFlowCore
@testable import InnoFlowTesting

@Suite("Phase Transition Graph Tests")
@MainActor
struct PhaseTransitionGraphTests {
  @Test("Graph exposes legal successors for a phase")
  func successors() {
    let graph = PhaseDrivenFeature.graph

    #expect(graph.allows(from: .idle, to: .loading))
    #expect(!graph.allows(from: .idle, to: .loaded))
    #expect(graph.successors(from: .loading) == [.loaded, .failed])
  }

  @Test("Graph supports linear declaration for simple workflows")
  func linearGraph() {
    let graph = PhaseTransitionGraph<PhaseDrivenFeature.Phase>.linear(.idle, .loading, .loaded)

    #expect(graph.allows(from: .idle, to: .loading))
    #expect(graph.allows(from: .loading, to: .loaded))
    #expect(!graph.allows(from: .loaded, to: .failed))
    #expect(
      graph.validate(
        allPhases: [.idle, .loading, .loaded],
        terminalPhases: [.loaded]
      ).isEmpty
    )
  }

  @Test("Single-phase linear graph preserves the inferred root")
  func singlePhaseLinearGraphPreservesRoot() {
    let graph = PhaseTransitionGraph<PhaseDrivenFeature.Phase>.linear(.idle)

    let issues = graph.validate(
      allPhases: [.idle],
      terminalPhases: [.idle]
    )

    #expect(issues.isEmpty)
    let report = graph.validationReport(
      allPhases: [.idle],
      terminalPhases: [.idle]
    )
    #expect(report.reachable == [.idle])
    #expect(report.unreachable.isEmpty)
  }

  @Test("Rootless graph validation reports missing root instead of passing silently")
  func rootlessGraphValidationReportsMissingRoot() {
    let graph: PhaseTransitionGraph<PhaseDrivenFeature.Phase> = [
      .idle: [.loading]
    ]

    let report = graph.validationReport(
      allPhases: [.idle, .loading],
      terminalPhases: [.loading]
    )

    #expect(report.issues.contains(.missingRoot))
    #expect(report.reachable.isEmpty)
    #expect(report.unreachable == [.idle, .loading])
  }

  @Test("Graph supports dictionary literal declaration")
  func dictionaryLiteralGraph() {
    let graph: PhaseTransitionGraph<PhaseDrivenFeature.Phase> = [
      .idle: [.loading],
      .loading: [.loaded, .failed],
    ]

    #expect(graph.allows(from: .idle, to: .loading))
    #expect(graph.successors(from: .loading) == [.loaded, .failed])
  }

  @Test("TestStore phase helper validates legal reducer transitions")
  func testStorePhaseTracking() async {
    let store = TestStore(reducer: PhaseDrivenFeature())

    await store.send(.load, tracking: \.phase, through: PhaseDrivenFeature.graph) {
      $0.phase = .loading
    }

    await store.receive(._loaded("done"), tracking: \.phase, through: PhaseDrivenFeature.graph) {
      $0.phase = .loaded
      $0.value = "done"
    }

    await store.assertNoMoreActions()
  }

  @Test("Graph validation reports unreachable phases and non-terminal dead ends")
  func graphValidationFindsStructuralIssues() {
    let graph: PhaseTransitionGraph<PhaseDrivenFeature.Phase> = [
      .idle: [.loading],
      .loading: [.loaded],
    ]

    let issues = graph.validate(
      allPhases: [.idle, .loading, .loaded, .failed],
      root: .idle
    )

    #expect(issues.contains(.unreachablePhase(.failed)))
    #expect(issues.contains(.nonTerminalDeadEnd(.loaded)))
  }

  @Test("Graph validation reports unknown successors and invalid terminal transitions")
  func graphValidationReportsUnknownSuccessorsAndTerminalViolations() {
    let graph: PhaseTransitionGraph<PhaseDrivenFeature.Phase> = [
      .idle: [.loading],
      .failed: [.loading],
    ]

    let issues = graph.validate(
      allPhases: [.idle, .loading],
      root: .idle,
      terminalPhases: [.idle]
    )

    #expect(issues.contains(.unknownSuccessor(from: .failed, to: .loading)))
    #expect(issues.contains(.terminalHasOutgoingEdges(.idle)))
  }

  @Test("Graph validation report includes root declaration and reachability context")
  func graphValidationReportIncludesReachabilityContext() {
    let graph: PhaseTransitionGraph<PhaseDrivenFeature.Phase> = [
      .idle: [.loading],
      .loading: [.loaded],
    ]

    let report = graph.validationReport(
      allPhases: [.idle, .loading, .loaded],
      root: .failed,
      terminalPhases: [.loaded]
    )

    #expect(report.issues.contains(.rootNotDeclared(.failed)))
    #expect(report.issues.contains(.unreachablePhase(.idle)))
    #expect(report.issues.contains(.unreachablePhase(.loading)))
    #expect(report.issues.contains(.unreachablePhase(.loaded)))
    #expect(report.reachable == [.failed])
    #expect(report.unreachable == [.idle, .loading, .loaded])
    #expect(report.declaredPhases == [.idle, .loading, .loaded])
    #expect(report.terminalPhases == [.loaded])
  }

  @Test("assertValidGraph passes clean graphs through the testing helper")
  func assertValidGraphHelper() {
    assertValidGraph(
      PhaseDrivenFeature.graph,
      allPhases: [.idle, .loading, .loaded, .failed],
      root: .idle,
      terminalPhases: [.loaded]
    )
  }
}
