// MARK: - TestStore+Finish.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

@MainActor
package final class TestStoreFinishActivity {
  package enum Kind: Hashable, Sendable {
    case run
    case composite
    case debounce
    case throttle
  }

  package struct Snapshot: Equatable, Sendable {
    package let revision: UInt64
    package let runCount: Int
    package let compositeCount: Int
    package let debounceCount: Int
    package let throttleCount: Int

    package var activeCount: Int {
      runCount + compositeCount + debounceCount + throttleCount
    }
  }

  private struct Waiter {
    let continuation: CheckedContinuation<Bool, Never>
    let timeoutTask: Task<Void, Never>
  }

  private let clock = ContinuousClock()
  private var activities: [UUID: Kind] = [:]
  private var revision: UInt64 = 0
  private var waiters: [UUID: Waiter] = [:]

  @discardableResult
  package func begin(_ kind: Kind, token: UUID = UUID()) -> UUID {
    activities[token] = kind
    notifyChange()
    return token
  }

  package func end(_ token: UUID) {
    guard activities.removeValue(forKey: token) != nil else { return }
    notifyChange()
  }

  package func noteProgress() {
    notifyChange()
  }

  package var snapshot: Snapshot {
    Snapshot(
      revision: revision,
      runCount: count(.run),
      compositeCount: count(.composite),
      debounceCount: count(.debounce),
      throttleCount: count(.throttle)
    )
  }

  package func waitForChange(
    after expectedRevision: UInt64,
    until deadline: ContinuousClock.Instant
  ) async -> Bool {
    guard revision == expectedRevision else { return true }
    guard clock.now < deadline else { return false }

    let waiterID = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard revision == expectedRevision else {
          continuation.resume(returning: true)
          return
        }

        let clock = self.clock
        let timeoutTask = Task { @MainActor [weak self] in
          do {
            try await clock.sleep(until: deadline)
          } catch {
            return
          }
          guard Task.isCancelled == false else { return }
          self?.resolveWaiter(id: waiterID, returning: false)
        }
        waiters[waiterID] = Waiter(
          continuation: continuation,
          timeoutTask: timeoutTask
        )
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.resolveWaiter(id: waiterID, returning: false)
      }
    }
  }

  private func count(_ kind: Kind) -> Int {
    activities.values.lazy.filter { $0 == kind }.count
  }

  private func notifyChange() {
    revision &+= 1
    let currentWaiters = waiters
    waiters.removeAll(keepingCapacity: true)
    for waiter in currentWaiters.values {
      waiter.timeoutTask.cancel()
      waiter.continuation.resume(returning: true)
    }
  }

  private func resolveWaiter(id: UUID, returning didChange: Bool) {
    guard let waiter = waiters.removeValue(forKey: id) else { return }
    waiter.timeoutTask.cancel()
    waiter.continuation.resume(returning: didChange)
  }
}

package enum TestStoreFinishResult: Equatable, Sendable {
  case success
  case unhandledActions([String])
  case timedOut(TestStoreFinishActivity.Snapshot)
  case cancelled
}

package struct TestStoreTerminalVerificationDiagnostic {
  package enum Severity {
    case failure
    case warning
  }

  package let severity: Severity
  package let message: String
  package let file: StaticString
  package let line: UInt
}

extension TestStore {
  /// Waits for all in-flight effects to finish and asserts that every emitted
  /// action has been received.
  ///
  /// When ``exhaustivity`` is `.off`, unreceived actions are reduced and their
  /// follow-up effects are drained until the harness becomes idle. Exhaustive
  /// stores continue to report every unreceived action.
  ///
  /// The timeout uses wall time and never advances a supplied
  /// ``ManualTestClock``. Advance the manual clock before calling `finish()`
  /// when delayed effects are expected to complete.
  ///
  /// On failure, cancellation is requested for all remaining framework-owned
  /// effects and their subsequent action emissions are suppressed. An effect
  /// that ignores cooperative cancellation may still continue its own work.
  ///
  /// This is the canonical terminal assertion. As a safety net, deinitializing
  /// a store with valid buffered actions or active framework-owned effects
  /// reports one failure in exhaustive mode, one warning when skipped
  /// assertions are enabled, or remains silent in `.off`. The deinitializer
  /// does not wait or reduce actions, and an idle store does not fail merely
  /// because `finish()` was omitted. A completed or failed `finish()` is not
  /// reported again unless new work begins or arrives afterward.
  ///
  /// - Parameters:
  ///   - timeout: The total wall-clock deadline. Pass `nil` to use the timeout
  ///     configured when this `TestStore` was initialized.
  ///   - file: The source file reported when terminal verification fails.
  ///   - line: The source line reported when terminal verification fails.
  public func finish(
    timeout: Duration? = nil,
    file: StaticString = #file,
    line: UInt = #line
  ) async {
    let resolvedTimeout = timeout ?? effectTimeout
    let result = await finishResult(
      timeout: resolvedTimeout,
      file: file,
      line: line
    )

    switch result {
    case .success, .cancelled:
      return

    case .unhandledActions(let actions):
      let actionList = actions.map { "- \($0)" }.joined(separator: "\n")
      assertionFailureReporter(
        """
        TestStore finished with \(actions.count) unhandled effect action(s):
        \(actionList)

        Every effect-emitted action must be verified with `receive(_:assert:)` before the test finishes.
        """,
        file,
        line
      )

    case .timedOut(let snapshot):
      assertionFailureReporter(
        """
        Timed out waiting for TestStore to become idle after \(resolvedTimeout).

        Active effects at timeout:
        - run: \(snapshot.runCount)
        - composite: \(snapshot.compositeCount)
        - debounce: \(snapshot.debounceCount)
        - throttle: \(snapshot.throttleCount)

        Complete or cancel long-running effects before finishing. A continuously emitted action chain can also prevent the harness from becoming idle. When using `ManualTestClock`, advance it far enough for delayed effects to fire before calling `finish()`.
        """,
        file,
        line
      )
    }
  }

  package func finishResult(
    timeout: Duration? = nil,
    file: StaticString = #file,
    line: UInt = #line
  ) async -> TestStoreFinishResult {
    let terminalRevision = beginTerminalVerification(file: file, line: line)
    let resolvedTimeout = timeout ?? effectTimeout
    let deadline = wallClock.now.advanced(by: resolvedTimeout)
    var didDrainAction = false

    while true {
      if Task.isCancelled {
        cancelRemainingEffectsForFinish()
        markTerminalVerificationHandled(terminalRevision)
        return .cancelled
      }

      if exhaustivity.isOn {
        let actions = await takeAllBufferedActionDescriptions()
        if actions.isEmpty == false {
          cancelRemainingEffectsForFinish()
          markTerminalVerificationHandled(terminalRevision)
          return .unhandledActions(actions)
        }
      } else if let action = await popBufferedAction() {
        // Always allow one already-buffered action to be reduced, even for a
        // zero timeout. Subsequent actions remain bounded by the total
        // deadline so a self-reenqueuing reducer cannot trap finish forever.
        if didDrainAction, wallClock.now >= deadline {
          let snapshot = finishActivity.snapshot
          cancelRemainingEffectsForFinish()
          markTerminalVerificationHandled(terminalRevision)
          return .timedOut(snapshot)
        }
        reportSkippedAction(
          action,
          context: "finishing",
          file: file,
          line: line
        )
        await applyUnassertedAction(action, file: file, line: line)
        didDrainAction = true
        continue
      }

      let snapshot = finishActivity.snapshot
      if snapshot.activeCount == 0 {
        markTerminalVerificationHandled(terminalRevision)
        return .success
      }

      if wallClock.now >= deadline {
        cancelRemainingEffectsForFinish()
        markTerminalVerificationHandled(terminalRevision)
        return .timedOut(snapshot)
      }

      _ = await finishActivity.waitForChange(
        after: snapshot.revision,
        until: deadline
      )
    }
  }

  private func takeAllBufferedActionDescriptions() async -> [String] {
    var actions: [String] = []
    while let action = await popBufferedAction() {
      actions.append(String(describing: action))
    }
    return actions
  }

  private func cancelRemainingEffectsForFinish() {
    let sequence = markCancelledAll()
    cancelAllEffectsSynchronously(upTo: sequence)
  }

  package func noteTestInteraction(
    file: StaticString,
    line: UInt
  ) {
    terminalVerificationRevision &+= 1
    terminalVerificationSource = (file, line)
  }

  package func noteUnverifiedWorkAfterTerminalVerification() {
    guard
      lastHandledTerminalVerificationRevision == terminalVerificationRevision
    else { return }
    terminalVerificationRevision &+= 1
  }

  @discardableResult
  package func beginFinishActivity(
    _ kind: TestStoreFinishActivity.Kind,
    token: UUID = UUID(),
    context: EffectExecutionContext?
  ) -> UUID {
    if shouldProceed(context: context) {
      noteUnverifiedWorkAfterTerminalVerification()
    }
    return finishActivity.begin(kind, token: token)
  }

  private func beginTerminalVerification(
    file: StaticString,
    line: UInt
  ) -> UInt64 {
    terminalVerificationSource = (file, line)
    return terminalVerificationRevision
  }

  private func markTerminalVerificationHandled(_ revision: UInt64) {
    guard
      lastHandledTerminalVerificationRevision.map({ $0 >= revision }) != true
    else { return }
    lastHandledTerminalVerificationRevision = revision
  }

  package func makeTerminalVerificationDiagnostic()
    -> TestStoreTerminalVerificationDiagnostic?
  {
    guard
      lastHandledTerminalVerificationRevision != terminalVerificationRevision
    else { return nil }

    var actionCount = 0
    var actionDescriptions: [String] = []
    queue.forEachBuffered { queuedAction in
      guard shouldProceed(context: queuedAction.context) else { return }
      actionCount += 1
      if actionDescriptions.count < 20 {
        actionDescriptions.append(String(describing: queuedAction.action))
      }
    }

    let activity = finishActivity.snapshot
    guard actionCount > 0 || activity.activeCount > 0 else { return nil }

    let severity: TestStoreTerminalVerificationDiagnostic.Severity
    let header: String
    let actionLabel: String
    let activityLabel: String
    let guidance: String
    switch exhaustivity {
    case .on:
      severity = .failure
      header = "TestStore was deinitialized with unverified work."
      actionLabel = "Unhandled effect actions"
      activityLabel = "Active framework-owned effects"
      guidance =
        "Call `await store.finish()` before the store leaves scope. In exhaustive mode, receive every effect-emitted action first. Advance `ManualTestClock` or cancel intentionally long-running effects before finishing."

    case .off(let showSkippedAssertions):
      guard showSkippedAssertions else { return nil }
      severity = .warning
      header = "TestStore skipped terminal verification while deinitializing."
      actionLabel = "Skipped effect actions"
      activityLabel = "Active framework-owned effects cancelled during deinitialization"
      guidance =
        "The remaining actions were not reduced. Call `await store.finish()` to drain non-exhaustive actions and effects before the store leaves scope."
    }

    var sections: [String] = [header]
    if actionCount > 0 {
      var actionLines = actionDescriptions.map { "- \($0)" }
      let omittedCount = actionCount - actionDescriptions.count
      if omittedCount > 0 {
        actionLines.append("- ... \(omittedCount) more action(s)")
      }
      sections.append(
        "\(actionLabel) (\(actionCount)):\n\(actionLines.joined(separator: "\n"))"
      )
    }
    if activity.activeCount > 0 {
      sections.append(
        """
        \(activityLabel):
        - run: \(activity.runCount)
        - composite: \(activity.compositeCount)
        - debounce: \(activity.debounceCount)
        - throttle: \(activity.throttleCount)
        """
      )
    }
    sections.append(guidance)

    let source = terminalVerificationSource ?? (#file, #line)
    return TestStoreTerminalVerificationDiagnostic(
      severity: severity,
      message: sections.joined(separator: "\n\n"),
      file: source.file,
      line: source.line
    )
  }
}
