// MARK: - PhaseMapPerfTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.
//
// Hot-path benchmark for `PhaseMap` resolution after the base reducer runs.
//
// This file measures dispatch through a `PhaseMappedReducer` decorator across
// FSM sizes that are representative of real product features:
//   - small:  4 phases × 3 transitions per phase
//   - medium: 16 phases × 5 transitions per phase
//   - large:  64 phases × 5 transitions per phase
//
// PhaseMap already resolves the source phase in O(1) through
// `rulesBySourcePhase: [Phase: [PhaseRule]]`. The remaining work per action
// is linear in the number of declared transitions for that phase. This
// benchmark establishes a baseline so a future refactor that introduces a
// per-phase transition index (which would require a Hashable constraint on
// `Action` and an opt-in `PhaseMap` API) can be evaluated against measured
// numbers rather than against intuition.
//
// The tests are not pass/fail gates — they print timings so humans can
// compare before/after numbers across refactors. Following the convention
// established by `ReducerCompositionPerfTests`, benchmarks run only when
// `INNOFLOW_PERF_BENCHMARKS=1` is set.

import Foundation
import Testing

@testable import InnoFlow

private var isPhaseMapPerfBenchmarkEnabled: Bool {
  ProcessInfo.processInfo.environment["INNOFLOW_PERF_BENCHMARKS"] == "1"
}

// MARK: - Fixture

private struct PhaseMapPerfState: Equatable, Sendable, DefaultInitializable {
  var phase: Int = 0
  var bumps: Int = 0
}

private enum PhaseMapPerfAction: Equatable, Sendable {
  /// Encodes the source/target phases inside the action so the same fixture
  /// can drive arbitrary FSM sizes without changing the action surface.
  case advance(from: Int, to: Int)
}

private struct PhaseMapPerfBaseReducer: Reducer {
  typealias State = PhaseMapPerfState
  typealias Action = PhaseMapPerfAction

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .advance:
      state.bumps &+= 1
      return .none
    }
  }
}

private func makeRingPhaseMap(
  phaseCount: Int,
  transitionsPerPhase: Int
) -> PhaseMap<PhaseMapPerfState, PhaseMapPerfAction, Int> {
  precondition(phaseCount > 0)
  precondition(transitionsPerPhase > 0)
  precondition(transitionsPerPhase < phaseCount)

  return PhaseMap(\.phase) {
    for source in 0..<phaseCount {
      From(source) {
        for offset in 1...transitionsPerPhase {
          let target = (source + offset) % phaseCount
          On(.advance(from: source, to: target), to: target)
        }
      }
    }
  }
}

// MARK: - Measurement helpers

private struct PhaseMapPerfResult {
  let label: String
  let iterations: Int
  let total: Duration

  func formatted() -> String {
    let totalMs =
      Double(total.components.seconds) * 1_000
      + Double(total.components.attoseconds) / 1e15
    let perUs = totalMs * 1_000 / Double(iterations)
    let paddedLabel = label.padding(toLength: 48, withPad: " ", startingAt: 0)
    let totalMsStr = String(format: "%8.2f", totalMs)
    let perUsStr = String(format: "%8.3f", perUs)
    return "[perf] \(paddedLabel)  iters=\(iterations)  total=\(totalMsStr) ms  per=\(perUsStr) µs"
  }
}

private func measureBlock(
  label: String,
  iterations: Int,
  _ body: () -> Void
) -> PhaseMapPerfResult {
  for _ in 0..<max(1, iterations / 10) { body() }

  let clock = ContinuousClock()
  let start = clock.now
  for _ in 0..<iterations { body() }
  let end = clock.now
  return PhaseMapPerfResult(label: label, iterations: iterations, total: start.duration(to: end))
}

// MARK: - Dispatch benchmarks

@Suite(.serialized)
struct PerfPhaseMapDispatch {

  @Test func _perf_phaseMap_dispatch_small_4x3() async throws {
    guard isPhaseMapPerfBenchmarkEnabled else { return }

    let phaseCount = 4
    let transitionsPerPhase = 3
    let reducer = PhaseMapPerfBaseReducer().phaseMap(
      makeRingPhaseMap(phaseCount: phaseCount, transitionsPerPhase: transitionsPerPhase)
    )
    var state = PhaseMapPerfState()

    let result = measureBlock(
      label: "phaseMap dispatch small (4 phases × 3 transitions)",
      iterations: 10_000
    ) {
      let from = state.phase
      let to = (from + 1) % phaseCount
      _ = reducer.reduce(into: &state, action: .advance(from: from, to: to))
    }
    print(result.formatted())
    #expect(state.bumps > 0)
  }

  @Test func _perf_phaseMap_dispatch_medium_16x5() async throws {
    guard isPhaseMapPerfBenchmarkEnabled else { return }

    let phaseCount = 16
    let transitionsPerPhase = 5
    let reducer = PhaseMapPerfBaseReducer().phaseMap(
      makeRingPhaseMap(phaseCount: phaseCount, transitionsPerPhase: transitionsPerPhase)
    )
    var state = PhaseMapPerfState()

    let result = measureBlock(
      label: "phaseMap dispatch medium (16 phases × 5 transitions)",
      iterations: 10_000
    ) {
      let from = state.phase
      let to = (from + 1) % phaseCount
      _ = reducer.reduce(into: &state, action: .advance(from: from, to: to))
    }
    print(result.formatted())
    #expect(state.bumps > 0)
  }

  @Test func _perf_phaseMap_dispatch_large_64x5() async throws {
    guard isPhaseMapPerfBenchmarkEnabled else { return }

    let phaseCount = 64
    let transitionsPerPhase = 5
    let reducer = PhaseMapPerfBaseReducer().phaseMap(
      makeRingPhaseMap(phaseCount: phaseCount, transitionsPerPhase: transitionsPerPhase)
    )
    var state = PhaseMapPerfState()

    let result = measureBlock(
      label: "phaseMap dispatch large (64 phases × 5 transitions)",
      iterations: 10_000
    ) {
      let from = state.phase
      let to = (from + 1) % phaseCount
      _ = reducer.reduce(into: &state, action: .advance(from: from, to: to))
    }
    print(result.formatted())
    #expect(state.bumps > 0)
  }

  /// Worst-case-ish dispatch: the matching transition is the last one declared
  /// in the source phase. Linear scan over `transitionsPerPhase` always
  /// inspects every earlier transition before finding the match. A future
  /// per-phase transition index would collapse this to a single hash lookup.
  @Test func _perf_phaseMap_dispatch_large_lastTransition_64x5() async throws {
    guard isPhaseMapPerfBenchmarkEnabled else { return }

    let phaseCount = 64
    let transitionsPerPhase = 5
    let reducer = PhaseMapPerfBaseReducer().phaseMap(
      makeRingPhaseMap(phaseCount: phaseCount, transitionsPerPhase: transitionsPerPhase)
    )
    var state = PhaseMapPerfState()

    let result = measureBlock(
      label: "phaseMap dispatch large last-of-5 (64 phases × 5 transitions)",
      iterations: 10_000
    ) {
      let from = state.phase
      // Always pick the last declared transition in the current phase so
      // every iteration walks through 4 non-matching transitions first.
      let to = (from + transitionsPerPhase) % phaseCount
      _ = reducer.reduce(into: &state, action: .advance(from: from, to: to))
    }
    print(result.formatted())
    #expect(state.bumps > 0)
  }
}
