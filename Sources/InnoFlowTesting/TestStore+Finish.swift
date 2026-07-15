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

extension TestStore {
  /// Waits for all in-flight effects to finish and asserts that every emitted
  /// action has been received.
  ///
  /// The timeout uses wall time and never advances a supplied
  /// ``ManualTestClock``. Advance the manual clock before calling `finish()`
  /// when delayed effects are expected to complete.
  ///
  /// On failure, cancellation is requested for all remaining framework-owned
  /// effects and their subsequent action emissions are suppressed. An effect
  /// that ignores cooperative cancellation may still continue its own work.
  ///
  /// - Parameter timeout: The total wall-clock deadline. Pass `nil` to use the
  ///   timeout configured when this `TestStore` was initialized.
  public func finish(
    timeout: Duration? = nil,
    file: StaticString = #file,
    line: UInt = #line
  ) async {
    let resolvedTimeout = timeout ?? effectTimeout
    let result = await finishResult(timeout: resolvedTimeout)

    switch result {
    case .success, .cancelled:
      return

    case .unhandledActions(let actions):
      let actionList = actions.map { "- \($0)" }.joined(separator: "\n")
      testStoreAssertionFailure(
        """
        TestStore finished with \(actions.count) unhandled effect action(s):
        \(actionList)

        Every effect-emitted action must be verified with `receive(_:assert:)` before the test finishes.
        """,
        file: file,
        line: line
      )

    case .timedOut(let snapshot):
      testStoreAssertionFailure(
        """
        Timed out waiting for TestStore effects to finish after \(resolvedTimeout).

        Active effects:
        - run: \(snapshot.runCount)
        - composite: \(snapshot.compositeCount)
        - debounce: \(snapshot.debounceCount)
        - throttle: \(snapshot.throttleCount)

        Complete or cancel long-running effects before finishing. When using `ManualTestClock`, advance it far enough for delayed effects to fire before calling `finish()`.
        """,
        file: file,
        line: line
      )
    }
  }

  package func finishResult(timeout: Duration? = nil) async -> TestStoreFinishResult {
    let resolvedTimeout = timeout ?? effectTimeout
    let deadline = wallClock.now.advanced(by: resolvedTimeout)

    while true {
      if Task.isCancelled {
        cancelRemainingEffectsForFinish()
        return .cancelled
      }

      let actions = await takeAllBufferedActionDescriptions()
      if actions.isEmpty == false {
        cancelRemainingEffectsForFinish()
        return .unhandledActions(actions)
      }

      let snapshot = finishActivity.snapshot
      if snapshot.activeCount == 0 {
        return .success
      }

      if wallClock.now >= deadline {
        cancelRemainingEffectsForFinish()
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
}
