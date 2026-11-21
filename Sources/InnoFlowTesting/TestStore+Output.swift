// MARK: - TestStore+Output.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
public import InnoFlowCore

extension TestStore {
  /// Receives the next reducer output and verifies its exact value.
  ///
  /// In non-exhaustive mode, skips mismatches under one total timeout, just
  /// like `receive`, and advances intermediate FIFO actions and their effects.
  /// Before it skips a buffered output, it reduces the buffered actions a
  /// `Store` reduced before it published that output, so an output that
  /// comes after the expected one is never skipped. A `.zero` timeout
  /// examines only the output at the head of the buffer: a match there is
  /// received.
  public func receiveOutput(
    _ expectedOutput: R.Output,
    timeout: Duration? = nil,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) async where R.Output: Equatable {
    await receiveOutput(
      expectedOutput, timeout: timeout,
      location: .init(fileID: fileID, filePath: filePath, line: line, column: column))
  }

  package func receiveOutput(
    _ expectedOutput: R.Output,
    timeout: Duration? = nil,
    location: TestStoreSourceLocation
  ) async where R.Output: Equatable {
    _ = await receiveMatchedOutput(
      expectation: String(describing: expectedOutput),
      timeout: timeout,
      location: location
    ) { output in
      output == expectedOutput ? .matched(()) : .mismatched
    }
  }

  /// Receives an output accepted by a predicate, without requiring `Equatable`.
  ///
  /// The predicate executes on the main actor. Exhaustive stores report the
  /// first mismatch; non-exhaustive stores skip it and continue within the
  /// original timeout. Cancellation returns `nil` without reporting a timeout.
  @discardableResult
  public func receiveOutput(
    where predicate: (R.Output) -> Bool,
    description: String? = nil,
    timeout: Duration? = nil,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) async -> R.Output? {
    await receiveOutput(
      where: predicate, description: description, timeout: timeout,
      location: .init(fileID: fileID, filePath: filePath, line: line, column: column))
  }

  @discardableResult
  package func receiveOutput(
    where predicate: (R.Output) -> Bool,
    description: String? = nil,
    timeout: Duration? = nil,
    location: TestStoreSourceLocation
  ) async -> R.Output? {
    await receiveMatchedOutput(
      expectation: description.map { "predicate '\($0)'" } ?? "the supplied predicate",
      timeout: timeout,
      location: location
    ) { output in
      predicate(output) ? .matched(output) : .mismatched
    }
  }

  /// Receives an output matching a case path and returns its payload.
  ///
  /// No `Equatable` conformance is required. A matched optional `nil` payload
  /// is returned as `.some(nil)`, distinct from mismatch, timeout, or cancellation.
  @discardableResult
  public func receiveOutput<Value>(
    _ path: CasePath<R.Output, Value>,
    caseName: String? = nil,
    timeout: Duration? = nil,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) async -> Value? {
    await receiveOutput(
      path, caseName: caseName, timeout: timeout,
      location: .init(fileID: fileID, filePath: filePath, line: line, column: column))
  }

  @discardableResult
  package func receiveOutput<Value>(
    _ path: CasePath<R.Output, Value>,
    caseName: String? = nil,
    timeout: Duration? = nil,
    location: TestStoreSourceLocation
  ) async -> Value? {
    await receiveMatchedOutput(
      expectation: caseName.map { "case path '\($0)'" } ?? "the supplied case path",
      timeout: timeout,
      location: location
    ) { output in
      switch path.extract(output) {
      case .some(let value): .matched(value)
      case .none: .mismatched
      }
    }
  }

  package func receiveMatchedOutput<Value>(
    expectation: String,
    timeout: Duration?,
    location: TestStoreSourceLocation,
    matching matcher: (R.Output) -> TestStoreActionMatch<Value>
  ) async -> Value? {
    noteTestInteraction(location: location)
    let resolvedTimeout = timeout ?? effectTimeout
    let deadline = wallClock.now.advanced(by: resolvedTimeout)
    var didProgress = false

    func reportTimeout() {
      issueReporter(
        "Expected to receive output:\n\(expectation)\n\nBut timed out after \(resolvedTimeout).",
        location
      )
    }

    while true {
      guard !Task.isCancelled else { return nil }
      if didProgress, wallClock.now >= deadline {
        reportTimeout()
        return nil
      }
      // A composite task the test store follows can still buffer a value
      // ahead of the ones buffered now.
      await followedTasks.settle()

      // Capture before inspecting either queue; waiting never consumes a value.
      let revision = finishActivity.snapshot.revision
      let queuedOutput: ActionQueue<R.Output>.QueuedAction
      if let buffered = outputQueue.popBuffered() {
        queuedOutput = buffered
      } else if !exhaustivity.isOn {
        // Prefer an already-delivered output, then advance exactly one FIFO
        // action before checking outputs again. An action flood cannot starve
        // the output side, and the original deadline covers all progress.
        if let action = queue.popBuffered() {
          guard action.isDeliverable else {
            action.finish()
            didProgress = true
            continue
          }
          reportSkippedAction(action.action, context: "receiving an output", location: location)
          await applyUnassertedAction(action, location: location)
          didProgress = true
          continue
        }
        guard wallClock.now < deadline else {
          reportTimeout()
          return nil
        }
        let changed = await finishActivity.waitForChange(after: revision, until: deadline)
        if !changed {
          if !Task.isCancelled { reportTimeout() }
          return nil
        }
        didProgress = true
        continue
      } else {
        let remaining = wallClock.now.duration(to: deadline)
        guard remaining > .zero,
          let received = await outputQueue.next(timeout: remaining)
        else {
          if !Task.isCancelled { reportTimeout() }
          return nil
        }
        queuedOutput = received
      }

      guard queuedOutput.isDeliverable else {
        didProgress = true
        continue
      }
      switch matcher(queuedOutput.action) {
      case .matched(let value):
        return .some(value)
      case .mismatched:
        break
      }

      // A `Store` reduced a buffered action keyed before this output before
      // it published the output, and what that reduction publishes comes
      // first: keep the output and reduce the action instead of skipping it.
      if !exhaustivity.isOn,
        let action = popBufferedQueuedAction(before: queuedOutput.delivery.storeOrder)
      {
        outputQueue.restoreFirst(queuedOutput)
        reportSkippedAction(action.action, context: "receiving an output", location: location)
        await applyUnassertedAction(action, location: location)
        didProgress = true
        continue
      }

      if exhaustivity.isOn {
        issueReporter(
          "Received unexpected output.\n\nExpected:\n\(expectation)\n\nReceived:\n\(queuedOutput.action)",
          location
        )
        return nil
      }
      if exhaustivity.showsSkippedAssertions {
        warningReporter(
          "TestStore skipped output while receiving another output:\n\(queuedOutput.action)",
          location
        )
      }
      didProgress = true
    }
  }

  package func popBufferedOutput() async -> R.Output? {
    await followedTasks.settle()
    while let queuedOutput = outputQueue.popBuffered() {
      guard queuedOutput.isDeliverable else { continue }
      return queuedOutput.action
    }
    return nil
  }
}
