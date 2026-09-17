// MARK: - StoreOutputHub.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

package enum StoreOutputYieldDisposition: Sendable, Equatable {
  case enqueued
  case dropped
  case terminated
}

package struct StoreOutputDeliverySummary: Sendable, Equatable {
  package var subscriberCount = 0
  package var enqueuedCount = 0
  package var droppedCount = 0
  package var terminatedCount = 0

  package mutating func record(_ disposition: StoreOutputYieldDisposition) {
    subscriberCount += 1
    switch disposition {
    case .enqueued:
      enqueuedCount += 1
    case .dropped:
      droppedCount += 1
    case .terminated:
      terminatedCount += 1
    }
  }
}

package func storeOutputYieldDisposition<Output: Sendable>(
  _ result: AsyncStream<Output>.Continuation.YieldResult
) -> StoreOutputYieldDisposition {
  switch result {
  case .enqueued:
    return .enqueued
  case .dropped:
    return .dropped
  case .terminated:
    return .terminated
  @unknown default:
    return .terminated
  }
}

/// Broadcasts ephemeral reducer outputs to live subscribers without replay.
@MainActor
package final class StoreOutputHub<Output: Sendable> {
  private var continuations: [UUID: AsyncStream<Output>.Continuation] = [:]

  package init() {}

  package func stream(
    bufferingPolicy: AsyncStream<Output>.Continuation.BufferingPolicy
  ) -> AsyncStream<Output> {
    let id = UUID()
    let pair = AsyncStream<Output>.makeStream(bufferingPolicy: bufferingPolicy)
    continuations[id] = pair.continuation
    pair.continuation.onTermination = { @Sendable [weak self] _ in
      Task { @MainActor [weak self] in
        self?.continuations.removeValue(forKey: id)
      }
    }
    return pair.stream
  }

  package func yield(_ output: Output) -> StoreOutputDeliverySummary {
    var summary = StoreOutputDeliverySummary()
    for continuation in continuations.values {
      summary.record(storeOutputYieldDisposition(continuation.yield(output)))
    }
    return summary
  }

  isolated deinit {
    for continuation in continuations.values {
      continuation.finish()
    }
  }
}
