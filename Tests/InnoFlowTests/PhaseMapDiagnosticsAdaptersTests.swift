// MARK: - PhaseMapDiagnosticsAdaptersTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import Testing
import os
import OSLog

@testable import InnoFlow

private enum TestPhase: Hashable, Sendable {
  case idle
  case loading
  case loaded
}

private enum TestAction: Equatable, Sendable {
  case load
  case finish
}

private final class ViolationProbe: Sendable {
  private let lock = OSAllocatedUnfairLock<[PhaseMapViolation<TestAction, TestPhase>]>(initialState: [])

  var events: [PhaseMapViolation<TestAction, TestPhase>] {
    lock.withLock { $0 }
  }

  func record(_ event: PhaseMapViolation<TestAction, TestPhase>) {
    lock.withLock { $0.append(event) }
  }
}

@Suite("PhaseMapDiagnostics standard adapters", .serialized)
@MainActor
struct PhaseMapDiagnosticsAdaptersTests {

  private func sampleViolation() -> PhaseMapViolation<TestAction, TestPhase> {
    .undeclaredTarget(
      action: .finish,
      sourcePhase: .loading,
      target: .idle,
      declaredTargets: [.loaded]
    )
  }

  @Test(".sink forwards every violation to the supplied closure")
  func sinkForwardsViolation() {
    let probe = ViolationProbe()
    let diagnostics: PhaseMapDiagnostics<TestAction, TestPhase> = .sink { violation in
      probe.record(violation)
    }

    diagnostics.report(sampleViolation())
    diagnostics.report(.directPhaseMutation(action: .load, previousPhase: .idle, postReducePhase: .loaded))

    #expect(probe.events.count == 2)
  }

  @Test(".combined fans every violation out to each adapter in order")
  func combinedFansOut() {
    let firstProbe = ViolationProbe()
    let secondProbe = ViolationProbe()

    let diagnostics: PhaseMapDiagnostics<TestAction, TestPhase> = .combined(
      .sink { violation in firstProbe.record(violation) },
      .sink { violation in secondProbe.record(violation) }
    )

    diagnostics.report(sampleViolation())

    #expect(firstProbe.events.count == 1)
    #expect(secondProbe.events.count == 1)
  }

  @Test(".osLog evaluates without crashing for both violation cases")
  func osLogEmitsBothCases() {
    let logger = Logger(subsystem: "InnoFlowTests", category: "phaseMapDiagnostics")
    let diagnostics: PhaseMapDiagnostics<TestAction, TestPhase> = .osLog(logger: logger)

    diagnostics.report(sampleViolation())
    diagnostics.report(.directPhaseMutation(action: .load, previousPhase: .idle, postReducePhase: .loaded))
    // Reaching this point means the closure ran for both cases without trapping.
  }

  @Test(".signpost evaluates without crashing for both violation cases")
  func signpostEmitsBothCases() {
    let signposter = OSSignposter(subsystem: "InnoFlowTests", category: "phaseMapDiagnostics")
    let diagnostics: PhaseMapDiagnostics<TestAction, TestPhase> = .signpost(signposter: signposter)

    diagnostics.report(sampleViolation())
    diagnostics.report(.directPhaseMutation(action: .load, previousPhase: .idle, postReducePhase: .loaded))
  }

  @Test("Adapter composition: combined(.sink, .osLog) still routes to the sink probe")
  func combinedWithOsLogStillRoutesToSink() {
    let probe = ViolationProbe()
    let logger = Logger(subsystem: "InnoFlowTests", category: "phaseMapDiagnostics")

    let diagnostics: PhaseMapDiagnostics<TestAction, TestPhase> = .combined(
      .sink { violation in probe.record(violation) },
      .osLog(logger: logger)
    )

    diagnostics.report(sampleViolation())

    #expect(probe.events.count == 1)
  }
}
