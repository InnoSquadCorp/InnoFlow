// MARK: - TestStore+Exhaustivity.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

extension TestStore {
  package func prepareForSend(
    file: StaticString,
    line: UInt
  ) async {
    noteTestInteraction(file: file, line: line)
    let deadline = wallClock.now.advanced(by: effectTimeout)
    var skippedActionCount = 0
    var skippedActionDescriptions: [String] = []
    var didDrainAction = false

    while let action = await popBufferedAction() {
      // Give one already-buffered action a chance to recover even when the
      // configured timeout is zero, then bound recursive synchronous sends.
      if didDrainAction, wallClock.now >= deadline {
        let sequence = markCancelledAll()
        cancelAllEffectsSynchronously(upTo: sequence)
        let actionList = formattedSkippedActions(
          skippedActionDescriptions,
          totalCount: skippedActionCount
        )
        assertionFailureReporter(
          """
          Timed out draining effect actions before a new action after \(effectTimeout).

          Reduced \(skippedActionCount) action(s) before the deadline:
          \(actionList)

          Next unhandled action:
          \(action)

          Remaining effect work was cancelled before reducing the new action.
          """,
          file,
          line
        )
        return
      }
      if skippedActionDescriptions.count < 20 {
        skippedActionDescriptions.append(String(describing: action))
      }
      skippedActionCount += 1
      await applyUnassertedAction(action)
      didDrainAction = true
    }

    guard skippedActionCount > 0 else { return }

    let actionList = formattedSkippedActions(
      skippedActionDescriptions,
      totalCount: skippedActionCount
    )
    switch exhaustivity {
    case .on:
      assertionFailureReporter(
        """
        TestStore received \(skippedActionCount) effect action(s) before a new action was sent:
        \(actionList)

        Receive every effect action before sending another action. The skipped actions were reduced to preserve runtime order.
        """,
        file,
        line
      )

    case .off(let showSkippedAssertions):
      guard showSkippedAssertions else { return }
      skippedAssertionReporter(
        """
        TestStore skipped \(skippedActionCount) effect action(s) before sending a new action:
        \(actionList)

        The skipped actions were reduced to preserve runtime order.
        """,
        file,
        line
      )
    }
  }

  private func formattedSkippedActions(
    _ descriptions: [String],
    totalCount: Int
  ) -> String {
    var lines = descriptions.map { "- \($0)" }
    let omittedCount = totalCount - descriptions.count
    if omittedCount > 0 {
      lines.append("- ... \(omittedCount) more action(s)")
    }
    return lines.joined(separator: "\n")
  }

  package func applyUnassertedAction(_ action: R.Action) async {
    let effect = reducer.reduce(into: &state, action: action)
    let sequence = nextSequence()
    await walker.walk(effect, context: .init(sequence: sequence), awaited: false)
  }

  package func reportSkippedAction(
    _ action: R.Action,
    context: String,
    file: StaticString,
    line: UInt
  ) {
    guard exhaustivity.showsSkippedAssertions else { return }
    skippedAssertionReporter(
      """
      TestStore skipped effect action while \(context):
      \(action)

      The skipped action was reduced to preserve runtime order.
      """,
      file,
      line
    )
  }

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
