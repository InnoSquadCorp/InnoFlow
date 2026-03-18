// MARK: - ManualTestClock.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import InnoFlow

/// A manually-advanced clock for deterministic effect testing.
public actor ManualTestClock {
  public typealias Instant = ContinuousClock.Instant

  private struct SleepRequest {
    let deadline: Instant
    let insertionOrder: UInt64
    let continuation: CheckedContinuation<Void, Error>
  }

  private var current: Instant
  private var sleepers: [UUID: SleepRequest] = [:]
  private var nextInsertionOrder: UInt64 = 0

  public init(now: Instant = ContinuousClock().now) {
    self.current = now
  }

  public var now: Instant {
    current
  }

  public func advance(by duration: Duration) async {
    await Task.yield()
    current = current.advanced(by: duration)
    resumeReadySleepers()
    await Task.yield()
  }

  public func sleep(for duration: Duration) async throws {
    guard duration > .zero else {
      return
    }

    let deadline = current.advanced(by: duration)
    guard deadline > current else {
      return
    }

    let sleeperID = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let insertionOrder = nextInsertionOrder
        nextInsertionOrder += 1
        sleepers[sleeperID] = .init(
          deadline: deadline,
          insertionOrder: insertionOrder,
          continuation: continuation
        )
      }
    } onCancel: {
      Task {
        await self.cancelSleep(id: sleeperID)
      }
    }
  }

  private func resumeReadySleepers() {
    let ready = sleepers
      .filter { _, request in request.deadline <= current }
      .sorted { lhs, rhs in
        if lhs.value.deadline == rhs.value.deadline {
          return lhs.value.insertionOrder < rhs.value.insertionOrder
        }
        return lhs.value.deadline < rhs.value.deadline
      }

    for (id, request) in ready {
      sleepers.removeValue(forKey: id)
      request.continuation.resume()
    }
  }

  private func cancelSleep(id: UUID) {
    guard let request = sleepers.removeValue(forKey: id) else {
      return
    }
    request.continuation.resume(throwing: CancellationError())
  }
}

public extension StoreClock {
  static func manual(_ clock: ManualTestClock) -> Self {
    .init(
      now: {
        await clock.now
      },
      sleep: { duration in
        try await clock.sleep(for: duration)
      }
    )
  }
}
