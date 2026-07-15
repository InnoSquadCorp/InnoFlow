// MARK: - TestStore+Exhaustivity.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

extension TestStore {
  package func assertStateTransition(
    from previousState: R.State,
    expectedStateMutation: ((inout R.State) -> Bool)?,
    mismatchLabel: String = "State",
    eventDescription: String,
    failureContext: String? = nil,
    exhaustiveGuidance: String? = nil,
    file: StaticString,
    line: UInt
  ) {
    switch exhaustivity {
    case .on:
      var expectedState = previousState
      guard expectedStateMutation?(&expectedState) != false else {
        reportUnavailableStateAssertion(
          eventDescription: eventDescription,
          failureContext: failureContext,
          guidance: exhaustiveGuidance,
          file: file,
          line: line
        )
        return
      }
      guard state != expectedState else { return }

      reportStateMismatch(
        expected: expectedState,
        actual: state,
        mismatchLabel: mismatchLabel,
        eventDescription: eventDescription,
        failureContext: failureContext,
        guidance: exhaustiveGuidance,
        file: file,
        line: line
      )

    case .off(let showSkippedAssertions):
      if let expectedStateMutation {
        var partiallyExpectedState = state
        guard expectedStateMutation(&partiallyExpectedState) else {
          reportUnavailableStateAssertion(
            eventDescription: eventDescription,
            failureContext: failureContext,
            guidance: exhaustiveGuidance,
            file: file,
            line: line
          )
          return
        }
        guard partiallyExpectedState == state else {
          reportStateMismatch(
            expected: partiallyExpectedState,
            actual: state,
            mismatchLabel: mismatchLabel,
            eventDescription: eventDescription,
            failureContext: failureContext,
            guidance: nil,
            file: file,
            line: line
          )
          return
        }
      }

      guard showSkippedAssertions else { return }
      guard previousState != state else { return }

      reportSkippedStateAssertions(
        expected: previousState,
        actual: state,
        eventDescription: eventDescription,
        failureContext: failureContext,
        file: file,
        line: line
      )
    }
  }

  private func reportUnavailableStateAssertion(
    eventDescription: String,
    failureContext: String?,
    guidance: String?,
    file: StaticString,
    line: UInt
  ) {
    let guidanceSection = guidance.map { "\n\n\($0)" } ?? ""
    assertionFailureReporter(
      decorate(
        """
        Could not evaluate the scoped state assertion \(eventDescription)

        The scoped value is no longer present in the root state.\(guidanceSection)
        """,
        with: failureContext
      ),
      file,
      line
    )
  }

  private func reportStateMismatch(
    expected: R.State,
    actual: R.State,
    mismatchLabel: String,
    eventDescription: String,
    failureContext: String?,
    guidance: String?,
    file: StaticString,
    line: UInt
  ) {
    let diffSection = formattedDiff(expected: expected, actual: actual)
    let guidanceSection = guidance.map { "\n\n\($0)" } ?? ""
    let message =
      """
      \(mismatchLabel) \(eventDescription)

      \(diffSection)Expected:
      \(expected)

      Actual:
      \(actual)\(guidanceSection)
      """

    assertionFailureReporter(
      decorate(message, with: failureContext),
      file,
      line
    )
  }

  private func reportSkippedStateAssertions(
    expected: R.State,
    actual: R.State,
    eventDescription: String,
    failureContext: String?,
    file: StaticString,
    line: UInt
  ) {
    let message =
      """
      State transition was checked non-exhaustively \(eventDescription)

      The diff lists every reducer change; asserted and skipped fields are not distinguished so the assertion closure executes exactly once.

      \(formattedDiff(expected: expected, actual: actual))Before:
      \(expected)

      After:
      \(actual)
      """

    skippedAssertionReporter(
      decorate(message, with: failureContext),
      file,
      line
    )
  }

  private func formattedDiff(expected: R.State, actual: R.State) -> String {
    renderStateDiff(
      expected: expected,
      actual: actual,
      lineLimit: diffLineLimit
    ).map {
      "Diff:\n\($0)\n\n"
    } ?? ""
  }

  private func decorate(_ message: String, with failureContext: String?) -> String {
    guard let failureContext else { return message }
    return "\(failureContext)\n\n\(message)"
  }
}
