// MARK: - ProjectionReleaseScalingTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import InnoFlowCore
import Testing

// Locks the release cost of key-path selections that share one dependency
// bucket: releasing one must not copy the whole bucket. The check measures
// wall-clock time, so it stays a host suite outside the focused platform
// runtime inventory, whose consistency suites hold deterministic assertions.

private struct ScalingFeature: Reducer {
  struct State: Equatable, Sendable {
    var count = 0
  }

  enum Action: Sendable {
    case increment
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .increment:
      state.count += 1
    }
    return .none
  }
}

@MainActor
@Suite("Projection release scaling", .serialized, .timeLimit(.minutes(5)))
struct ProjectionReleaseScalingTests {
  @Test("Releasing selections that share one dependency costs time linear in their number")
  func releasingSelectionsOfOneDependencyIsLinear() async {
    func secondsToRelease(_ count: Int) -> Double {
      let store = Store(reducer: ScalingFeature(), initialState: .init())
      var held = (0..<count).map { _ in store.select(dependingOn: \.count) { $0 } }
      let elapsed = ContinuousClock().measure { held.removeAll() }
      return Double(elapsed.components.seconds)
        + Double(elapsed.components.attoseconds) / 1e18
    }
    // Every measurement runs on the MainActor without suspending, so the
    // sizes stay small and the test yields between measurements: tests that
    // run in the same process must not be starved past their own deadlines.
    func best(_ count: Int) async -> Double {
      var best = Double.infinity
      for _ in 0..<3 {
        best = min(best, secondsToRelease(count))
        await Task.yield()
      }
      return best
    }
    _ = secondsToRelease(200)

    // Four times the selections: about 4x when each release is O(1), about
    // 16x when each release copies the whole shared bucket.
    let small = await best(750)
    let large = await best(3_000)

    #expect(large < small * 9)
  }
}
