// MARK: - TestStore+Output.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
public import InnoFlowCore

extension TestStore {
  /// Receives the next reducer output and verifies its exact value.
  ///
  /// In non-exhaustive mode, skips mismatches under one total timeout, just
  /// like `receive`. An already-buffered match can be received with `.zero`.
  public func receiveOutput(
    _ expectedOutput: R.Output,
    timeout: Duration? = nil,
    file: StaticString = #file,
    line: UInt = #line
  ) async where R.Output: Equatable {
    _ = await receiveMatchedOutput(
      expectation: String(describing: expectedOutput),
      timeout: timeout,
      file: file,
      line: line
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
    file: StaticString = #file,
    line: UInt = #line
  ) async -> R.Output? {
    await receiveMatchedOutput(
      expectation: description.map { "predicate '\($0)'" } ?? "the supplied predicate",
      timeout: timeout,
      file: file,
      line: line
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
    file: StaticString = #file,
    line: UInt = #line
  ) async -> Value? {
    await receiveMatchedOutput(
      expectation: caseName.map { "case path '\($0)'" } ?? "the supplied case path",
      timeout: timeout,
      file: file,
      line: line
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
    file: StaticString,
    line: UInt,
    matching matcher: (R.Output) -> TestStoreActionMatch<Value>
  ) async -> Value? {
    noteTestInteraction(file: file, line: line)
    let resolvedTimeout = timeout ?? effectTimeout
    let deadline = wallClock.now.advanced(by: resolvedTimeout)
    var didSkipOutput = false

    func reportTimeout() {
      assertionFailureReporter(
        "Expected to receive output:\n\(expectation)\n\nBut timed out after \(resolvedTimeout).",
        file,
        line
      )
    }

    while true {
      guard !Task.isCancelled else { return nil }
      if didSkipOutput, wallClock.now >= deadline {
        reportTimeout()
        return nil
      }

      let queuedOutput: ActionQueue<R.Output>.QueuedAction
      if let buffered = outputQueue.popBuffered() {
        queuedOutput = buffered
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

      guard shouldProceed(context: queuedOutput.context) else {
        didSkipOutput = true
        continue
      }
      switch matcher(queuedOutput.action) {
      case .matched(let value):
        return .some(value)
      case .mismatched:
        break
      }

      if exhaustivity.isOn {
        assertionFailureReporter(
          "Received unexpected output.\n\nExpected:\n\(expectation)\n\nReceived:\n\(queuedOutput.action)",
          file,
          line
        )
        return nil
      }
      if exhaustivity.showsSkippedAssertions {
        skippedAssertionReporter(
          "TestStore skipped output while receiving another output:\n\(queuedOutput.action)",
          file,
          line
        )
      }
      didSkipOutput = true
    }
  }

  package func popBufferedOutput() async -> R.Output? {
    while let queuedOutput = outputQueue.popBuffered() {
      guard shouldProceed(context: queuedOutput.context) else { continue }
      return queuedOutput.action
    }
    return nil
  }
}
