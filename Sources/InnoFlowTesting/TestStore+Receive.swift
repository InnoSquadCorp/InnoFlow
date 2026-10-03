// MARK: - TestStore+Receive.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
package import InnoFlowCore

package enum TestStoreActionMatch<Value> {
  case matched(Value)
  case mismatched
}

package enum TestStoreReceiveResult<Action, Value> {
  case matched(action: Action, value: Value)
  case mismatched(action: Action)
  case timedOut(timeout: Duration)
  case cancelled
}

extension TestStore {
  /// Receives according to the store's exhaustivity policy while preserving
  /// one total wall-clock deadline. In non-exhaustive mode, valid mismatches
  /// are reduced and their effects are walked before matching continues.
  package func receiveMatchingResult<Value>(
    timeout: Duration? = nil,
    location: TestStoreSourceLocation,
    matching matcher: (R.Action) -> TestStoreActionMatch<Value>
  ) async -> TestStoreReceiveResult<ActionQueue<R.Action>.QueuedAction, Value> {
    noteTestInteraction(location: location)
    let resolvedTimeout = timeout ?? effectTimeout
    let deadline = wallClock.now.advanced(by: resolvedTimeout)
    var didSkipMismatch = false

    while true {
      guard !Task.isCancelled else { return .cancelled }
      if didSkipMismatch, wallClock.now >= deadline {
        return .timedOut(timeout: resolvedTimeout)
      }

      let remaining = max(wallClock.now.duration(to: deadline), .zero)
      let result = await receiveQueuedResult(timeout: remaining, matching: matcher)

      switch result {
      case .matched:
        return result

      case .mismatched(let action):
        await applyUnassertedAction(action, location: location)
        guard exhaustivity.isOn == false else {
          return .mismatched(action: action)
        }
        reportSkippedAction(
          action.action,
          context: "receiving another action",
          location: location
        )
        didSkipMismatch = true

      case .timedOut:
        return .timedOut(timeout: resolvedTimeout)

      case .cancelled:
        return .cancelled
      }
    }
  }

  /// Dequeues one valid effect action and evaluates it without applying the
  /// reducer. Invalidated actions are skipped under a single wall-clock
  /// deadline; a valid mismatch is consumed and returned immediately.
  package func receiveQueuedResult<Value>(
    timeout: Duration? = nil,
    matching matcher: (R.Action) -> TestStoreActionMatch<Value>
  ) async -> TestStoreReceiveResult<ActionQueue<R.Action>.QueuedAction, Value> {
    let resolvedTimeout = timeout ?? effectTimeout
    let deadline = wallClock.now.advanced(by: resolvedTimeout)
    var didDiscardInvalidatedAction = false

    while true {
      guard !Task.isCancelled else { return .cancelled }

      let queuedAction: ActionQueue<R.Action>.QueuedAction
      if didDiscardInvalidatedAction, wallClock.now >= deadline {
        return .timedOut(timeout: resolvedTimeout)
      }
      if let bufferedAction = queue.popBuffered() {
        queuedAction = bufferedAction
      } else {
        let remaining = wallClock.now.duration(to: deadline)
        guard remaining > .zero else {
          return .timedOut(timeout: resolvedTimeout)
        }

        guard let awaitedAction = await queue.next(timeout: remaining) else {
          return Task.isCancelled
            ? .cancelled
            : .timedOut(timeout: resolvedTimeout)
        }
        queuedAction = awaitedAction
      }

      guard shouldProceed(context: queuedAction.context) else {
        queuedAction.finish()
        didDiscardInvalidatedAction = true
        continue
      }

      switch matcher(queuedAction.action) {
      case .matched(let value):
        return .matched(action: queuedAction, value: value)
      case .mismatched:
        return .mismatched(action: queuedAction)
      }
    }
  }
  // Value-only inspection helper. Runtime reduction always uses the owned entry.
  package func receiveResult<Value>(
    timeout: Duration? = nil,
    matching matcher: (R.Action) -> TestStoreActionMatch<Value>
  ) async -> TestStoreReceiveResult<R.Action, Value> {
    switch await receiveQueuedResult(timeout: timeout, matching: matcher) {
    case .matched(let entry, let value):
      entry.finish()
      return .matched(action: entry.action, value: value)
    case .mismatched(let entry):
      entry.finish()
      return .mismatched(action: entry.action)
    case .timedOut(let timeout): return .timedOut(timeout: timeout)
    case .cancelled: return .cancelled
    }
  }

}
