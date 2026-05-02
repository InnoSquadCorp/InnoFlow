// MARK: - ProjectionObserverRegistryPerfTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.
//
// Opt-in microbenchmarks for projection observer fanout. These are maintainer
// tools, not CI pass/fail gates; they print timings only when
// INNOFLOW_PERF_BENCHMARKS=1 is set.

import Foundation
import Testing

@testable import InnoFlow

private var isProjectionObserverRegistryPerfBenchmarkEnabled: Bool {
  ProcessInfo.processInfo.environment["INNOFLOW_PERF_BENCHMARKS"] == "1"
}

struct ProjectionObserverRegistryPerfSnapshot: Equatable {
  var tracked: Int
  var other: Int
  var unrelated: Int
}

@MainActor
final class ProjectionObserverRegistryPerfObserver: ProjectionObserver {
  private var refreshCount = 0

  func refreshFromParentStore() -> Bool {
    refreshCount &+= 1
    return false
  }
}

struct ProjectionObserverRegistryPerfScenario: Sendable, CustomStringConvertible {
  let label: String
  let observerCount: Int
  let iterations: Int
  let registration: @MainActor (
    ProjectionObserverRegistry<ProjectionObserverRegistryPerfSnapshot>,
    ProjectionObserverRegistryPerfObserver
  ) -> Void
  let nextSnapshot: @Sendable (Int) -> ProjectionObserverRegistryPerfSnapshot

  var description: String { label }
}

let projectionObserverRegistryPerfScenarios: [ProjectionObserverRegistryPerfScenario] = [
  .init(
    label: "dependency fanout (1 bucket x 1000 observers)",
    observerCount: 1_000,
    iterations: 200,
    registration: { registry, observer in
      registry.register(
        observer,
        registration: .dependency(
          .keyPath(\ProjectionObserverRegistryPerfSnapshot.tracked),
          hasChanged: { previous, next in
            previous.tracked != next.tracked
          }
        )
      )
    },
    nextSnapshot: { iteration in
      .init(tracked: iteration, other: 0, unrelated: 0)
    }
  ),
  .init(
    label: "always refresh (1000 observers)",
    observerCount: 1_000,
    iterations: 200,
    registration: { registry, observer in
      registry.register(observer)
    },
    nextSnapshot: { iteration in
      .init(tracked: 0, other: 0, unrelated: iteration)
    }
  ),
  .init(
    label: "overlapping dependencies (2 buckets x 1000 observers)",
    observerCount: 1_000,
    iterations: 200,
    registration: { registry, observer in
      registry.register(
        observer,
        registration: .dependencies([
          .init(
            .keyPath(\ProjectionObserverRegistryPerfSnapshot.tracked),
            hasChanged: { previous, next in
              previous.tracked != next.tracked
            }
          ),
          .init(
            .keyPath(\ProjectionObserverRegistryPerfSnapshot.other),
            hasChanged: { previous, next in
              previous.other != next.other
            }
          ),
        ])
      )
    },
    nextSnapshot: { iteration in
      .init(tracked: iteration, other: iteration, unrelated: 0)
    }
  ),
]

private struct ProjectionObserverRegistryPerfResult {
  let label: String
  let observers: Int
  let iterations: Int
  let total: Duration
  let stats: ProjectionObserverRegistryStats

  func formatted() -> String {
    let totalMs =
      Double(total.components.seconds) * 1_000
      + Double(total.components.attoseconds) / 1e15
    let perRefreshUs = totalMs * 1_000 / Double(iterations)
    let paddedLabel = label.padding(toLength: 56, withPad: " ", startingAt: 0)
    let totalMsStr = String(format: "%8.2f", totalMs)
    let perRefreshUsStr = String(format: "%8.3f", perRefreshUs)
    return
      "[perf] \(paddedLabel) observers=\(observers) iters=\(iterations) total=\(totalMsStr) ms perRefresh=\(perRefreshUsStr) us evaluated=\(stats.evaluatedObservers)"
  }
}

@MainActor
private func measureProjectionObserverRegistry(
  scenario: ProjectionObserverRegistryPerfScenario
) -> ProjectionObserverRegistryPerfResult {
  let registry = ProjectionObserverRegistry<ProjectionObserverRegistryPerfSnapshot>()
  let observers = (0..<scenario.observerCount).map { _ in
    ProjectionObserverRegistryPerfObserver()
  }

  for observer in observers {
    scenario.registration(registry, observer)
  }

  var previous = ProjectionObserverRegistryPerfSnapshot(tracked: 0, other: 0, unrelated: 0)
  let clock = ContinuousClock()
  let start = clock.now
  for iteration in 1...scenario.iterations {
    let next = scenario.nextSnapshot(iteration)
    registry.refresh(from: previous, to: next)
    previous = next
  }
  let end = clock.now

  return withExtendedLifetime(observers) {
    .init(
      label: scenario.label,
      observers: scenario.observerCount,
      iterations: scenario.iterations,
      total: start.duration(to: end),
      stats: registry.statsSnapshot
    )
  }
}

@Suite(.serialized)
struct PerfProjectionObserverRegistry {
  @Test(
    "ProjectionObserverRegistry refresh benchmark",
    arguments: projectionObserverRegistryPerfScenarios
  )
  @MainActor
  func _perf_projectionObserverRegistry_refresh(
    scenario: ProjectionObserverRegistryPerfScenario
  ) {
    guard isProjectionObserverRegistryPerfBenchmarkEnabled else { return }

    let result = measureProjectionObserverRegistry(scenario: scenario)
    print(result.formatted())
    #expect(result.stats.registeredObservers == scenario.observerCount)
  }
}
