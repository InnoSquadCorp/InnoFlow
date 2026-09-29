// MARK: - TestStoreScenario.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
package import InnoFlowCore

package enum TestStoreScenarioStepOutcome: Sendable {
  case completed
  case cancelled
}

/// One typed, deterministic interaction in a TestStore scenario.
public struct TestStoreScenarioStep<R: Reducer>: Sendable where R.State: Equatable {
  public let label: String
  package let operation: @MainActor @Sendable (TestStore<R>) async -> TestStoreScenarioStepOutcome

  public init(
    _ label: String,
    operation: @escaping @MainActor @Sendable (TestStore<R>) async -> Void
  ) {
    self.label = label
    self.operation = { store in
      guard Task.isCancelled == false else { return .cancelled }
      await operation(store)
      return Task.isCancelled ? .cancelled : .completed
    }
  }

  package init(
    _ label: String,
    cancellationAwareOperation operation:
      @escaping @MainActor @Sendable (TestStore<R>) async -> TestStoreScenarioStepOutcome
  ) {
    self.label = label
    self.operation = operation
  }

  public static func send(
    _ action: R.Action,
    label: String? = nil,
    file: StaticString = #filePath,
    line: UInt = #line,
    assert: (@MainActor @Sendable (inout R.State) -> Void)? = nil
  ) -> Self {
    .init(label ?? "send \(String(describing: action))") { store in
      await store.send(action, assert: assert, file: file, line: line)
    }
  }

  public static func advance(
    _ clock: ManualTestClock,
    by duration: Duration,
    onceSleepersReach count: Int? = nil,
    label: String? = nil
  ) -> Self {
    .init(
      label ?? "advance \(duration)",
      cancellationAwareOperation: { _ in
        guard Task.isCancelled == false else { return .cancelled }
        if let count {
          do {
            try await clock.advance(by: duration, onceSleepersReach: count)
          } catch is CancellationError {
            return .cancelled
          } catch {
            return Task.isCancelled ? .cancelled : .completed
          }
        } else {
          await clock.advance(by: duration)
        }
        return Task.isCancelled ? .cancelled : .completed
      })
  }

  public static func finish(
    timeout: Duration? = nil,
    label: String = "finish",
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> Self {
    .init(label) { store in
      await store.finish(timeout: timeout, file: file, line: line)
    }
  }
}

extension TestStoreScenarioStep where R.Action: Equatable {
  public static func receive(
    _ action: R.Action,
    timeout: Duration? = nil,
    label: String? = nil,
    file: StaticString = #filePath,
    line: UInt = #line,
    assert: (@MainActor @Sendable (inout R.State) -> Void)? = nil
  ) -> Self {
    .init(label ?? "receive \(String(describing: action))") { store in
      if let timeout {
        await store.receive(action, timeout: timeout, assert: assert, file: file, line: line)
      } else {
        await store.receive(action, assert: assert, file: file, line: line)
      }
    }
  }
}

extension TestStoreScenarioStep where R.Output: Equatable {
  public static func receiveOutput(
    _ output: R.Output,
    timeout: Duration? = nil,
    label: String? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> Self {
    .init(label ?? "receive output \(String(describing: output))") { store in
      await store.receiveOutput(output, timeout: timeout, file: file, line: line)
    }
  }
}

/// Reusable sequence of typed TestStore interactions.
public struct TestStoreScenario<R: Reducer>: Sendable where R.State: Equatable {
  public let seed: UInt64?
  public private(set) var steps: [TestStoreScenarioStep<R>]

  public init(
    seed: UInt64? = nil,
    steps: [TestStoreScenarioStep<R>] = []
  ) {
    self.seed = seed
    self.steps = steps
  }

  public mutating func append(_ step: TestStoreScenarioStep<R>) {
    steps.append(step)
  }

  @MainActor
  public func run(on store: TestStore<R>) async -> TestStoreScenarioResult {
    let originalFailureReporter = store.assertionFailureReporter
    let originalSkippedReporter = store.skippedAssertionReporter
    defer {
      store.assertionFailureReporter = originalFailureReporter
      store.skippedAssertionReporter = originalSkippedReporter
    }

    var completedLabels: [String] = []
    for (offset, step) in steps.enumerated() {
      guard Task.isCancelled == false else {
        await store.cancelAllEffects()
        return TestStoreScenarioResult(
          seed: seed,
          completedStepLabels: completedLabels,
          wasCancelled: true,
          cancelledStepIndex: offset,
          cancelledStepLabel: step.label
        )
      }
      let prefix = "Scenario step \(offset + 1)/\(steps.count): \(step.label)"
      store.assertionFailureReporter = { message, file, line in
        originalFailureReporter("\(prefix)\n\n\(message)", file, line)
      }
      store.skippedAssertionReporter = { message, file, line in
        originalSkippedReporter("\(prefix)\n\n\(message)", file, line)
      }
      let outcome = await step.operation(store)
      guard case .completed = outcome, Task.isCancelled == false else {
        await store.cancelAllEffects()
        return TestStoreScenarioResult(
          seed: seed,
          completedStepLabels: completedLabels,
          wasCancelled: true,
          cancelledStepIndex: offset,
          cancelledStepLabel: step.label
        )
      }
      completedLabels.append(step.label)
    }
    return TestStoreScenarioResult(
      seed: seed,
      completedStepLabels: completedLabels,
      wasCancelled: false,
      cancelledStepIndex: nil,
      cancelledStepLabel: nil
    )
  }
}

/// Semantic execution summary for a TestStore scenario.
public struct TestStoreScenarioResult: Sendable, Equatable {
  public let seed: UInt64?
  public let completedStepLabels: [String]
  public let wasCancelled: Bool
  /// Zero-based index of the step interrupted by cancellation.
  public let cancelledStepIndex: Int?
  public let cancelledStepLabel: String?

  public var completedStepCount: Int {
    completedStepLabels.count
  }
}
