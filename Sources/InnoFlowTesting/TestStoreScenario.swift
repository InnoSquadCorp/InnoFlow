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
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column,
    assert: (@MainActor @Sendable (inout R.State) -> Void)? = nil
  ) -> Self {
    send(
      action, label: label,
      location: .init(fileID: fileID, filePath: filePath, line: line, column: column),
      assert: assert)
  }

  package static func send(
    _ action: R.Action,
    label: String? = nil,
    location: TestStoreSourceLocation,
    assert: (@MainActor @Sendable (inout R.State) -> Void)? = nil
  ) -> Self {
    .init(label ?? "send \(String(describing: action))") { store in
      _ = await store.send(action, assert: assert, location: location)
    }
  }

  public static func advance(
    _ clock: ManualTestClock,
    by duration: Duration,
    onceSleepersReach count: Int,
    label: String? = nil
  ) -> Self {
    .init(
      label ?? "advance \(duration)",
      cancellationAwareOperation: { _ in
        guard Task.isCancelled == false else { return .cancelled }
        do {
          try await clock.advance(by: duration, onceSleepersReach: count)
        } catch is CancellationError {
          return .cancelled
        } catch {
          return Task.isCancelled ? .cancelled : .completed
        }
        return Task.isCancelled ? .cancelled : .completed
      })
  }

  public static func finish(
    timeout: Duration? = nil,
    label: String = "finish",
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) -> Self {
    finish(
      timeout: timeout, label: label,
      location: .init(fileID: fileID, filePath: filePath, line: line, column: column))
  }

  package static func finish(
    timeout: Duration? = nil,
    label: String = "finish",
    location: TestStoreSourceLocation
  ) -> Self {
    .init(label) { store in
      await store.finish(timeout: timeout, location: location)
    }
  }
}

extension TestStoreScenarioStep where R.Action: Equatable {
  public static func receive(
    _ action: R.Action,
    timeout: Duration? = nil,
    label: String? = nil,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column,
    assert: (@MainActor @Sendable (inout R.State) -> Void)? = nil
  ) -> Self {
    receive(
      action, timeout: timeout, label: label,
      location: .init(fileID: fileID, filePath: filePath, line: line, column: column),
      assert: assert)
  }

  package static func receive(
    _ action: R.Action,
    timeout: Duration? = nil,
    label: String? = nil,
    location: TestStoreSourceLocation,
    assert: (@MainActor @Sendable (inout R.State) -> Void)? = nil
  ) -> Self {
    .init(label ?? "receive \(String(describing: action))") { store in
      if let timeout {
        await store.receive(action, timeout: timeout, assert: assert, location: location)
      } else {
        await store.receive(action, assert: assert, location: location)
      }
    }
  }
}

extension TestStoreScenarioStep where R.Output: Equatable {
  public static func receiveOutput(
    _ output: R.Output,
    timeout: Duration? = nil,
    label: String? = nil,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) -> Self {
    receiveOutput(
      output, timeout: timeout, label: label,
      location: .init(fileID: fileID, filePath: filePath, line: line, column: column))
  }

  package static func receiveOutput(
    _ output: R.Output,
    timeout: Duration? = nil,
    label: String? = nil,
    location: TestStoreSourceLocation
  ) -> Self {
    .init(label ?? "receive output \(String(describing: output))") { store in
      await store.receiveOutput(output, timeout: timeout, location: location)
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
    let originalFailureReporter = store.issueReporter
    let originalSkippedReporter = store.warningReporter
    defer {
      store.issueReporter = originalFailureReporter
      store.warningReporter = originalSkippedReporter
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
      store.issueReporter = { message, location in
        originalFailureReporter("\(prefix)\n\n\(message)", location)
      }
      store.warningReporter = { message, location in
        originalSkippedReporter("\(prefix)\n\n\(message)", location)
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
