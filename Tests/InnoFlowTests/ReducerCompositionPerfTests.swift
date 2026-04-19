// MARK: - ReducerCompositionPerfTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.
//
// Construction-heavy composition benchmark for `CombineReducers` + `ReducerBuilder`.
//
// This file measures:
//   1. Construct-only cost: repeatedly building `CombineReducers { ... }` with
//      N child reducers. Sensitive to intermediate closure allocations inside
//      the builder chain.
//   2. Dispatch cost: sending a single action through an already-constructed
//      composition many times. Sensitive to the per-step merge/closure overhead.
//
// The tests are not pass/fail gates — they print timings so humans can compare
// before/after numbers across refactors. The `_perf` prefix is only a naming
// convention; benchmarks run only when `INNOFLOW_PERF_BENCHMARKS=1` is set.

import Foundation
import Testing

@testable import InnoFlow

private var isReducerCompositionPerfBenchmarkEnabled: Bool {
  ProcessInfo.processInfo.environment["INNOFLOW_PERF_BENCHMARKS"] == "1"
}

// MARK: - Fixture

private struct PerfBenchState: Equatable, Sendable, DefaultInitializable {
  var tick: Int = 0
}

private enum PerfBenchAction: Equatable, Sendable {
  case bump
}

private struct PerfBenchAppender: Reducer {
  typealias State = PerfBenchState
  typealias Action = PerfBenchAction

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    state.tick &+= 1
    return .none
  }
}

// MARK: - Measurement helpers

private struct PerfResult {
  let label: String
  let iterations: Int
  let total: Duration
  var perIteration: Duration { total / iterations }

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
  label: String, iterations: Int, _ body: () -> Void
) -> PerfResult {
  // Warm-up to ensure JIT/codegen paths are primed.
  for _ in 0..<max(1, iterations / 10) { body() }

  let clock = ContinuousClock()
  let start = clock.now
  for _ in 0..<iterations { body() }
  let end = clock.now
  return PerfResult(label: label, iterations: iterations, total: start.duration(to: end))
}

// MARK: - Construction benchmarks

// Explicit unrolled `CombineReducers { ... }` blocks. We do NOT use helper
// factories that return `some Reducer` because that would partially hide the
// construction cost we want to measure.

@Suite(.serialized)
struct PerfReducerComposition {

  @Test func _perf_constructOnly_N2() async throws {
    guard isReducerCompositionPerfBenchmarkEnabled else { return }

    let result = measureBlock(label: "construct-only N=2", iterations: 5_000) {
      _ = CombineReducers<PerfBenchState, PerfBenchAction> {
        PerfBenchAppender()
        PerfBenchAppender()
      }
    }
    print(result.formatted())
  }

  @Test func _perf_constructOnly_N8() async throws {
    guard isReducerCompositionPerfBenchmarkEnabled else { return }

    let result = measureBlock(label: "construct-only N=8", iterations: 5_000) {
      _ = CombineReducers<PerfBenchState, PerfBenchAction> {
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
      }
    }
    print(result.formatted())
  }

  @Test func _perf_constructOnly_N32() async throws {
    guard isReducerCompositionPerfBenchmarkEnabled else { return }

    let result = measureBlock(label: "construct-only N=32", iterations: 2_000) {
      _ = CombineReducers<PerfBenchState, PerfBenchAction> {
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
        PerfBenchAppender()
      }
    }
    print(result.formatted())
  }

  // MARK: - Dispatch benchmarks

  @Test func _perf_dispatch_N8_10k() async throws {
    guard isReducerCompositionPerfBenchmarkEnabled else { return }

    let reducer = CombineReducers<PerfBenchState, PerfBenchAction> {
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
    }
    var state = PerfBenchState()

    let result = measureBlock(label: "dispatch N=8 × 10k", iterations: 10_000) {
      _ = reducer.reduce(into: &state, action: .bump)
    }
    print(result.formatted())
    #expect(state.tick > 0)
  }

  @Test func _perf_dispatch_N32_10k() async throws {
    guard isReducerCompositionPerfBenchmarkEnabled else { return }

    let reducer = CombineReducers<PerfBenchState, PerfBenchAction> {
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
    }
    var state = PerfBenchState()

    let result = measureBlock(label: "dispatch N=32 × 10k", iterations: 10_000) {
      _ = reducer.reduce(into: &state, action: .bump)
    }
    print(result.formatted())
    #expect(state.tick > 0)
  }
}
