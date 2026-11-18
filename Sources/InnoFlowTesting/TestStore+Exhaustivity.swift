// MARK: - TestStore+Exhaustivity.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

extension TestStore {
  /// Reduces the buffered actions a `Store` reduced before an action the
  /// test sends now: those delivered before the send, with the values their
  /// reductions drain and the values of interpreter tasks that already ran.
  ///
  /// - Returns: The walks of the drained actions whose interpreter tasks a
  ///   `Store` runs after it reduces the sent action; the send runs them
  ///   after its reduction.
  package func prepareForSend(
    location: TestStoreSourceLocation
  ) async -> TestStoreDeferredWalks {
    noteTestInteraction(location: location)
    let deadline = wallClock.now.advanced(by: effectTimeout)
    var skippedActionCount = 0
    var skippedActionDescriptions: [String] = []
    var didDrainAction = false
    // A `Store` reduces the sent action in the current MainActor job, before
    // any job queued now runs: values delivered or anchored from now on stay
    // buffered.
    let sendOrder = TestStoreOrder.now()
    var deferred = TestStoreDeferredWalks()

    while let action = popBufferedQueuedAction(before: sendOrder) {
      // Give one already-buffered action a chance to recover even when the
      // configured timeout is zero, then bound recursive synchronous sends.
      if didDrainAction, wallClock.now >= deadline {
        let sequence = markCancelledAll()
        purgeDeliveries(cancelledBy: nil, upTo: sequence)
        cancelAllEffectsSynchronously(upTo: sequence)
        let actionList = formattedSkippedActions(
          skippedActionDescriptions,
          totalCount: skippedActionCount
        )
        issueReporter(
          """
          Timed out draining effect actions before a new action after \(effectTimeout).

          Reduced \(skippedActionCount) action(s) before the deadline:
          \(actionList)

          Next unhandled action:
          \(action.action)

          Remaining effect work was cancelled before reducing the new action.
          """,
          location
        )
        action.finish()
        return deferred
      }
      if skippedActionDescriptions.count < 20 {
        skippedActionDescriptions.append(String(describing: action.action))
      }
      skippedActionCount += 1
      await reduceBufferedActionBeforeSend(action, location: location, deferring: &deferred)
      didDrainAction = true
    }

    guard skippedActionCount > 0 else { return deferred }

    let actionList = formattedSkippedActions(
      skippedActionDescriptions,
      totalCount: skippedActionCount
    )
    switch exhaustivity {
    case .on:
      issueReporter(
        """
        TestStore received \(skippedActionCount) effect action(s) before a new action was sent:
        \(actionList)

        Receive every effect action before sending another action. The skipped actions were reduced to preserve runtime order.
        """,
        location
      )

    case .off(let showSkippedAssertions):
      guard showSkippedAssertions else { return deferred }
      warningReporter(
        """
        TestStore skipped \(skippedActionCount) effect action(s) before sending a new action:
        \(actionList)

        The skipped actions were reduced to preserve runtime order.
        """,
        location
      )
    }
    return deferred
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

  package func applyUnassertedAction(
    _ queuedAction: ActionQueue<R.Action>.QueuedAction,
    location: TestStoreSourceLocation
  ) async {
    await reduceReceivedAction(
      queuedAction, source: .automatic, location: location,
      willReduce: { _ in }, didReduce: { _ in })
  }

  package func reportSkippedAction(
    _ action: R.Action,
    context: String,
    location: TestStoreSourceLocation
  ) {
    guard exhaustivity.showsSkippedAssertions else { return }
    warningReporter(
      """
      TestStore skipped effect action while \(context):
      \(action)

      The skipped action was reduced to preserve runtime order.
      """,
      location
    )
  }

  package func assertStateTransition(
    from previousState: R.State,
    expectedStateMutation: ((inout R.State) -> Bool)?,
    mismatchLabel: String = "State",
    eventDescription: String,
    failureContext: String? = nil,
    exhaustiveGuidance: String? = nil,
    location: TestStoreSourceLocation
  ) {
    switch exhaustivity {
    case .on:
      var expectedState = previousState
      guard expectedStateMutation?(&expectedState) != false else {
        reportUnavailableStateAssertion(
          eventDescription: eventDescription,
          failureContext: failureContext,
          guidance: exhaustiveGuidance,
          location: location
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
        location: location
      )

    case .off(let showSkippedAssertions):
      if let expectedStateMutation {
        var partiallyExpectedState = state
        guard expectedStateMutation(&partiallyExpectedState) else {
          reportUnavailableStateAssertion(
            eventDescription: eventDescription,
            failureContext: failureContext,
            guidance: exhaustiveGuidance,
            location: location
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
            location: location
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
        location: location
      )
    }
  }

  private func reportUnavailableStateAssertion(
    eventDescription: String,
    failureContext: String?,
    guidance: String?,
    location: TestStoreSourceLocation
  ) {
    let guidanceSection = guidance.map { "\n\n\($0)" } ?? ""
    issueReporter(
      decorate(
        """
        Could not evaluate the scoped state assertion \(eventDescription)

        The scoped value is no longer present in the root state.\(guidanceSection)
        """,
        with: failureContext
      ),
      location
    )
  }

  private func reportStateMismatch(
    expected: R.State,
    actual: R.State,
    mismatchLabel: String,
    eventDescription: String,
    failureContext: String?,
    guidance: String?,
    location: TestStoreSourceLocation
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

    issueReporter(
      decorate(message, with: failureContext),
      location
    )
  }

  private func reportSkippedStateAssertions(
    expected: R.State,
    actual: R.State,
    eventDescription: String,
    failureContext: String?,
    location: TestStoreSourceLocation
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

    warningReporter(
      decorate(message, with: failureContext),
      location
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
