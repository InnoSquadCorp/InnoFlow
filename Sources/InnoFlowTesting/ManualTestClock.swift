// MARK: - ManualTestClock.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
public import InnoFlow

/// A manually-advanced clock for deterministic effect testing.
public actor ManualTestClock {
  public typealias Instant = ContinuousClock.Instant

  private struct SleepRequest {
    let deadline: Instant
    let insertionOrder: UInt64
    let continuation: CheckedContinuation<Void, any Error>
  }

  private var current: Instant
  private var sleepers: [UUID: SleepRequest] = [:]
  private var nextInsertionOrder: UInt64 = 0

  deinit {
    for request in sleepers.values {
      request.continuation.resume(throwing: CancellationError())
    }
    sleepers.removeAll()
    nextInsertionOrder = 0
  }

  /// Creates a deterministic test clock starting from the supplied instant.
  public init(now: Instant = ContinuousClock().now) {
    self.current = now
  }

  /// Returns the current instant tracked by this manual clock.
  public var now: Instant {
    current
  }

  /// The number of sleepers currently suspended on this clock.
  ///
  /// Test harnesses can poll this to wait for `Task { try await clock.sleep(...) }`
  /// sleepers to reach the registration point before calling `advance(by:)` —
  /// release optimization and parallel test load make a fixed yield count
  /// between spawning a sleeper and advancing unreliable.
  public var sleeperCount: Int {
    sleepers.count
  }

  /// Advances the clock and resumes any sleepers whose deadlines have passed.
  ///
  /// - Precondition: `duration` must be non-negative.
  public func advance(by duration: Duration) async {
    precondition(duration >= .zero, "ManualTestClock cannot move backwards.")
    await Task.yield()
    current = current.advanced(by: duration)
    resumeReadySleepers()
    await Task.yield()
  }

  /// Suspends until the clock has been advanced by at least `duration`.
  public func sleep(for duration: Duration) async throws {
    guard duration > .zero else {
      return
    }

    let deadline = current.advanced(by: duration)
    guard deadline > current else {
      return
    }

    let sleeperID = UUID()
    try Task.checkCancellation()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard registerSleep(id: sleeperID, deadline: deadline, continuation: continuation) else {
          continuation.resume(throwing: CancellationError())
          return
        }

        if Task.isCancelled, let request = sleepers.removeValue(forKey: sleeperID) {
          request.continuation.resume(throwing: CancellationError())
        }
      }
    } onCancel: {
      Task {
        await self.cancelSleep(id: sleeperID)
      }
    }
  }

  private func resumeReadySleepers() {
    let ready =
      sleepers
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

  private func registerSleep(
    id: UUID,
    deadline: Instant,
    continuation: CheckedContinuation<Void, any Error>
  ) -> Bool {
    guard Task.isCancelled == false else { return false }
    let insertionOrder = nextInsertionOrder
    nextInsertionOrder += 1
    sleepers[id] = .init(
      deadline: deadline,
      insertionOrder: insertionOrder,
      continuation: continuation
    )
    return true
  }

  private func cancelSleep(id: UUID) {
    guard let request = sleepers.removeValue(forKey: id) else {
      return
    }
    request.continuation.resume(throwing: CancellationError())
  }
}

extension StoreClock {
  /// Creates a `StoreClock` backed by a `ManualTestClock`.
  public static func manual(_ clock: ManualTestClock) -> Self {
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
