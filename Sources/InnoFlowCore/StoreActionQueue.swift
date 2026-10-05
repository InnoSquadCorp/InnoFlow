// MARK: - StoreActionQueue.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

package let storeActionQueueRetainedStorageBudget = 64 * 1024

package struct StoreQueuedAction<Action> {
  package let context: EffectExecutionContext?
  package let action: Action
  package let animation: EffectAnimation?
  package let flowTaskTracker: FlowTaskTracker?
  package let flowTaskActivity: FlowTaskActivityID?
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

  private let collectingMetrics: Bool
  private let actionStride = MemoryLayout<StoreQueuedAction<Action>>.stride

  package init(collectingMetrics: Bool = true) { self.collectingMetrics = collectingMetrics }

  package func enqueue(
    _ action: Action,
    animation: EffectAnimation?,
    flowTaskTracker: FlowTaskTracker? = nil,
    context: EffectExecutionContext? = nil
  ) {
    buffered.append(
      .init(
        context: context?.frozenForExecution(),
        action: action,
        animation: animation,
        flowTaskTracker: flowTaskTracker,
        flowTaskActivity: flowTaskTracker?.beginActivity()
      )
    )
    if collectingMetrics {
      pendingActionHighWaterMark = max(pendingActionHighWaterMark, buffered.count - head)
      storageHighWaterMark = max(storageHighWaterMark, buffered.count)
    }
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
    if collectingMetrics { processedActionCount += 1 }
    compactBufferIfNeeded()
    return action
  }

  package func finishDrain() -> StoreActionQueueDrainSnapshot {
    let didReleaseExcessCapacity = clearBufferAfterDrain()
    let snapshot = StoreActionQueueDrainSnapshot(
      processedActionCount: processedActionCount,
      pendingActionHighWaterMark: pendingActionHighWaterMark,
      storageHighWaterMark: storageHighWaterMark,
      retainedCapacity: buffered.capacity,
      retainedByteEstimate: estimatedBytes(forCapacity: buffered.capacity),
      didReleaseExcessCapacity: didReleaseExcessCapacity
    )
    resetMetrics()
    return snapshot
  }

  package func finishDrainDiscardingMetrics() {
    _ = clearBufferAfterDrain()
    resetMetrics()
  }

  private func resetMetrics() {
    processedActionCount = 0
    pendingActionHighWaterMark = 0
    storageHighWaterMark = 0
  }

  private func clearBufferAfterDrain() -> Bool {
    isDraining = false
    let oversized =
      estimatedBytes(forCapacity: buffered.capacity) > storeActionQueueRetainedStorageBudget
    if oversized { buffered = [] } else { buffered.removeAll(keepingCapacity: true) }
    head = 0
    return oversized
  }

  private func compactBufferIfNeeded() {
    guard head >= 64, head * 2 >= buffered.count else { return }
    buffered.removeFirst(head)
    head = 0
  }

  private func estimatedBytes(forCapacity capacity: Int) -> Int {
    let result = capacity.multipliedReportingOverflow(
      by: actionStride
    )
    return result.overflow ? .max : result.partialValue
  }
}
