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
  /// Dequeues one valid effect action and evaluates it without applying the
  /// reducer. Invalidated actions are skipped under a single wall-clock
  /// deadline; a valid mismatch is consumed and returned immediately.
  package func receiveResult<Value>(
    timeout: Duration? = nil,
    matching matcher: (R.Action) -> TestStoreActionMatch<Value>
  ) async -> TestStoreReceiveResult<R.Action, Value> {
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
        didDiscardInvalidatedAction = true
        continue
      }

      switch matcher(queuedAction.action) {
      case .matched(let value):
        return .matched(action: queuedAction.action, value: value)
      case .mismatched:
        return .mismatched(action: queuedAction.action)
      }
    }
  }
}
