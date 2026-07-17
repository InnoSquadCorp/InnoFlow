// MARK: - TestStoreActionQueue.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import InnoFlowCore
import os

package let testStoreActionQueueRetainedStorageBudget = 64 * 1024

private final class ActionQueueWaiterResolution: Sendable {
  private enum State: Equatable {
    case pending
    case delivered
    case cancelled
    case timedOut
  }

  private let state = OSAllocatedUnfairLock(initialState: State.pending)

  var isCancellationClaimed: Bool {
    state.withLock { $0 == .cancelled }
  }

  func claimDelivery() -> Bool {
    claim(.delivered)
  }

  func claimCancellation() -> Bool {
    claim(.cancelled)
  }

  func claimTimeout() -> Bool {
    claim(.timedOut)
  }

  private func claim(_ terminalState: State) -> Bool {
    state.withLock { state in
      guard state == .pending else { return false }
      state = terminalState
      return true
    }
  }
}

@MainActor
package final class ActionQueue<Action: Sendable> {
  struct QueuedAction: Sendable {
    let action: Action
    let context: EffectExecutionContext?
  }

  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<QueuedAction?, Never>
    let timeoutTask: Task<Void, Never>?
    let resolution: ActionQueueWaiterResolution
  }

  private var buffer: [QueuedAction] = []
  private var headIndex = 0
  // Waiters intentionally use an ordered array instead of a dictionary so
  // resumption is FIFO. The previous dictionary-based implementation woke
  // an arbitrary waiter via `waiters.keys.first`, which made multi-waiter
  // test scenarios non-deterministic across runs.
  private var waiters: [Waiter] = []

  package var pendingWaiterCount: Int {
    waiters.count
  }

  package var retainedByteEstimate: Int {
    estimatedBytes(forCapacity: buffer.capacity)
  }

  func forEachBuffered(_ body: (QueuedAction) -> Void) {
    guard headIndex < buffer.count else { return }
    for index in headIndex..<buffer.count {
      body(buffer[index])
    }
  }

  // Internal diagnostics hook for verifying forwarded wait budgets without
  // coupling tests to scheduler-dependent wall-clock completion thresholds.
  var waitTimeoutObserver: ((Duration) -> Void)?

  func enqueue(_ action: Action, context: EffectExecutionContext?) {
    let queuedAction = QueuedAction(
      action: action,
      context: context?.frozenForExecution()
    )
    while !waiters.isEmpty {
      let head = waiters.removeFirst()
      head.timeoutTask?.cancel()
      guard head.resolution.claimDelivery() else {
        head.continuation.resume(returning: nil)
        continue
      }
      head.continuation.resume(returning: queuedAction)
      return
    }

    buffer.append(queuedAction)
  }

  func next(timeout: Duration) async -> QueuedAction? {
    if headIndex < buffer.count {
      let queuedAction = buffer[headIndex]
      headIndex += 1
      compactBufferIfNeeded()
      return queuedAction
    }

    waitTimeoutObserver?(timeout)

    let waiterID = UUID()
    let resolution = ActionQueueWaiterResolution()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !resolution.isCancellationClaimed else {
          continuation.resume(returning: nil)
          return
        }

        let timeoutTask = Task { @MainActor [weak self] in
          try? await Task.sleep(for: timeout)
          guard !Task.isCancelled else { return }
          guard resolution.claimTimeout() else { return }
          self?.resolveWaiter(id: waiterID, returning: nil)
        }
        waiters.append(
          Waiter(
            id: waiterID,
            continuation: continuation,
            timeoutTask: timeoutTask,
            resolution: resolution
          )
        )
      }
    } onCancel: {
      guard resolution.claimCancellation() else { return }
      Task { @MainActor [weak self] in
        self?.resolveWaiter(id: waiterID, returning: nil)
      }
    }
  }

  func popBuffered() -> QueuedAction? {
    guard headIndex < buffer.count else { return nil }
    let queuedAction = buffer[headIndex]
    headIndex += 1
    compactBufferIfNeeded()
    return queuedAction
  }

  private func resolveWaiter(id waiterID: UUID, returning queuedAction: QueuedAction?) {
    guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
    let waiter = waiters.remove(at: index)
    waiter.timeoutTask?.cancel()
    waiter.continuation.resume(returning: queuedAction)
  }

  private func compactBufferIfNeeded() {
    guard headIndex > 0 else { return }
    if headIndex == buffer.count {
      if retainedByteEstimate > testStoreActionQueueRetainedStorageBudget {
        buffer = []
      } else {
        buffer.removeAll(keepingCapacity: true)
      }
      headIndex = 0
    } else if headIndex >= 64, headIndex * 2 >= buffer.count {
      buffer.removeFirst(headIndex)
      headIndex = 0
    }
  }

  private func estimatedBytes(forCapacity capacity: Int) -> Int {
    let result = capacity.multipliedReportingOverflow(
      by: MemoryLayout<QueuedAction>.stride
    )
    return result.overflow ? .max : result.partialValue
  }
}
