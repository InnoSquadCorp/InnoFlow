// MARK: - StoreActionQueue.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

package let storeActionQueueRetainedStorageBudget = 64 * 1024

package struct StoreQueuedAction<Action> {
  package let action: Action
  package let animation: EffectAnimation?
}

package struct StoreActionQueueDrainSnapshot: Sendable, Equatable {
  package let processedActionCount: Int
  package let pendingActionHighWaterMark: Int
  package let storageHighWaterMark: Int
  package let retainedCapacity: Int
  package let retainedByteEstimate: Int
  package let didReleaseExcessCapacity: Bool
}

@MainActor
package final class StoreActionQueue<Action> {
  // Back-pressure policy: see docs/adr/ADR-store-action-queue-burst.md.
  // The queue intentionally has no drop / collapse / hard-cap policy because
  // those decisions are domain-shaped and belong in EffectTask.throttle,
  // EffectTask.debounce, or a collapsing reducer.
  private var buffered: [StoreQueuedAction<Action>] = []
  private var head = 0
  private var isDraining = false
  private var processedActionCount = 0
  private var pendingActionHighWaterMark = 0
  private var storageHighWaterMark = 0

  package init() {}

  package func enqueue(_ action: Action, animation: EffectAnimation?) {
    buffered.append(.init(action: action, animation: animation))
    pendingActionHighWaterMark = max(pendingActionHighWaterMark, buffered.count - head)
    storageHighWaterMark = max(storageHighWaterMark, buffered.count)
  }

  package func beginDrain() -> Bool {
    guard !isDraining else { return false }
    isDraining = true
    return true
  }

  package func next() -> StoreQueuedAction<Action>? {
    guard head < buffered.count else { return nil }
    let action = buffered[head]
    head += 1
    processedActionCount += 1
    compactBufferIfNeeded()
    return action
  }

  package func finishDrain() -> StoreActionQueueDrainSnapshot {
    isDraining = false

    let retainedBytesBeforeClear = estimatedBytes(forCapacity: buffered.capacity)
    let didReleaseExcessCapacity =
      retainedBytesBeforeClear > storeActionQueueRetainedStorageBudget

    if didReleaseExcessCapacity {
      buffered = []
    } else {
      buffered.removeAll(keepingCapacity: true)
    }
    head = 0

    let snapshot = StoreActionQueueDrainSnapshot(
      processedActionCount: processedActionCount,
      pendingActionHighWaterMark: pendingActionHighWaterMark,
      storageHighWaterMark: storageHighWaterMark,
      retainedCapacity: buffered.capacity,
      retainedByteEstimate: estimatedBytes(forCapacity: buffered.capacity),
      didReleaseExcessCapacity: didReleaseExcessCapacity
    )
    processedActionCount = 0
    pendingActionHighWaterMark = 0
    storageHighWaterMark = 0
    return snapshot
  }

  private func compactBufferIfNeeded() {
    guard head >= 64, head * 2 >= buffered.count else { return }
    buffered.removeFirst(head)
    head = 0
  }

  private func estimatedBytes(forCapacity capacity: Int) -> Int {
    let result = capacity.multipliedReportingOverflow(
      by: MemoryLayout<StoreQueuedAction<Action>>.stride
    )
    return result.overflow ? .max : result.partialValue
  }
}
