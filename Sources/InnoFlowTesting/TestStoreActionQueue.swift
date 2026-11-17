// MARK: - TestStoreActionQueue.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import InnoFlowCore
import Synchronization

package let testStoreActionQueueRetainedStorageBudget = 64 * 1024

private final class ActionQueueWaiterResolution: Sendable {
  private enum State: Equatable {
    case pending
    case delivered
    case cancelled
    case timedOut
  }

  private let state = Mutex(State.pending)

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

/// An entry owns dispatch progress until reduction has registered all descendants.
/// Explicit release is idempotent; deinitialization covers discard and store teardown.
package final class TestStoreDispatchActivity: Sendable {
  let tracker: FlowTaskTracker
  let token: FlowTaskActivityID

  init(_ tracker: FlowTaskTracker) {
    self.tracker = tracker
    token = tracker.beginActivity()
  }

  func attach(_ task: Task<Void, Never>) { tracker.attach(task, to: token) }
  func finish() { tracker.endActivity(token) }
  deinit { finish() }
}

/// What a test store knows about one delivered effect action or output.
///
/// A `Store` reduces an effect action, and publishes an output, the moment an
/// effect delivers it. A test store buffers the value until the test receives
/// it, so a cancellation applied in between decides from this record whether
/// a `Store` would already have handled the value.
@MainActor
package final class TestStoreDelivery {
  private static var lastOrder: UInt64 = 0

  /// The order every buffered action and output of every test store shares.
  package let order: UInt64
  /// The run that emitted the action, when a run emitted it.
  package let runToken: UUID?
  /// The continuation of the effect sequence that delivered the value has
  /// moved past it, so a `Store` has certainly handled it: only a
  /// cancellation applied while the test reduces an earlier received action,
  /// or the end of its dispatch, still removes it.
  package var isSettled = false
  /// A cancellation applied while the test reduced an earlier received action
  /// covered the value, which a `Store` would therefore never have delivered.
  package var isWithdrawn = false

  init(runToken: UUID?) {
    Self.lastOrder &+= 1
    order = Self.lastOrder
    self.runToken = runToken
  }

  /// Every delivery recorded so far has an order below this one.
  package static var nextOrder: UInt64 { lastOrder &+ 1 }
}

@MainActor
package final class ActionQueue<Action: Sendable> {
  package struct QueuedAction: Sendable {
    let action: Action
    let context: EffectExecutionContext?
    let delivery: TestStoreDelivery
    private let activity: TestStoreDispatchActivity?

    init(
      action: Action,
      context: EffectExecutionContext?,
      delivery: TestStoreDelivery,
      tracksActivity: Bool
    ) {
      self.action = action
      self.context = context?.frozenForExecution()
      self.delivery = delivery
      activity =
        tracksActivity ? (context?.flowTaskTracker).map(TestStoreDispatchActivity.init) : nil
    }

    /// Whether the test may still receive the value. A settled value ignores
    /// later cancellation of its effect, but not the end of its dispatch.
    @MainActor package var isDeliverable: Bool {
      guard !delivery.isWithdrawn else { return false }
      guard !delivery.isSettled else { return context?.flowTaskTracker?.isCancelled != true }
      return context?.shouldProceed ?? true
    }

    func finish() { activity?.finish() }
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
  /// Values resumed to a waiter that has not run yet; they are still pending.
  private var handedOff: [QueuedAction] = []

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

  /// Buffered values and values already resumed to a waiter that has not run.
  func forEachPending(_ body: (QueuedAction) -> Void) {
    handedOff.forEach(body)
    forEachBuffered(body)
  }

  // Internal diagnostics hook for verifying forwarded wait budgets without
  // coupling tests to scheduler-dependent wall-clock completion thresholds.
  var waitTimeoutObserver: ((Duration) -> Void)?

  /// Delivers a value to the first waiter, or buffers it. A value buffered
  /// with `aheadOfRun` goes before the first buffered value that run emitted.
  func enqueue(
    _ action: Action,
    context: EffectExecutionContext?,
    tracksActivity: Bool = true,
    runToken: UUID? = nil,
    aheadOfRun anchor: UUID? = nil
  ) {
    let queuedAction = QueuedAction(
      action: action,
      context: context,
      delivery: TestStoreDelivery(runToken: runToken),
      tracksActivity: tracksActivity
    )
    while !waiters.isEmpty {
      let head = waiters.removeFirst()
      head.timeoutTask?.cancel()
      guard head.resolution.claimDelivery() else {
        head.continuation.resume(returning: nil)
        continue
      }
      handedOff.append(queuedAction)
      head.continuation.resume(returning: queuedAction)
      return
    }

    if let anchor,
      let index = buffer[headIndex...].firstIndex(where: { $0.delivery.runToken == anchor })
    {
      buffer.insert(queuedAction, at: index)
    } else {
      buffer.append(queuedAction)
    }
  }

  func removeBuffered(where predicate: (QueuedAction) -> Bool) {
    let remaining = buffer.dropFirst(headIndex).filter { entry in
      guard predicate(entry) else { return true }
      entry.finish()
      return false
    }
    buffer = remaining
    headIndex = 0
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
    let received: QueuedAction? = await withTaskCancellationHandler {
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
    if let received {
      handedOff.removeAll { $0.delivery === received.delivery }
    }
    return received
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
