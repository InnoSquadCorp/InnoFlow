// MARK: - ManualTestClock.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
@_exported public import InnoFlowCore

/// A manually-advanced clock for deterministic effect testing.
public actor ManualTestClock {
  public typealias Instant = ContinuousClock.Instant

  private struct SleepRequest {
    let deadline: Instant
    let insertionOrder: UInt64
    let continuation: CheckedContinuation<Void, any Error>
  }

  private struct SleeperWaiter {
    /// Evaluated against `(sleeperCount, sleepRegistrationCount)` after every
    /// successful sleep registration.
    let condition: @Sendable (Int, UInt64) -> Bool
    let continuation: CheckedContinuation<Void, any Error>
  }

  private var current: Instant
  private var sleepers: [UUID: SleepRequest] = [:]
  private var sleeperWaiters: [UUID: SleeperWaiter] = [:]
  private var nextInsertionOrder: UInt64 = 0
  private var successfulSleepRegistrationCount: UInt64 = 0

  deinit {
    for request in sleepers.values {
      request.continuation.resume(throwing: CancellationError())
    }
    sleepers.removeAll()
    for waiter in sleeperWaiters.values {
      waiter.continuation.resume(throwing: CancellationError())
    }
    sleeperWaiters.removeAll()
    nextInsertionOrder = 0
    successfulSleepRegistrationCount = 0
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
  /// Prefer ``waitForSleepers(atLeast:)`` or ``advance(by:onceSleepersReach:)``
  /// over polling this value — they suspend on the registration event itself,
  /// so no poll interval or yield-count heuristic is involved.
  public var sleeperCount: Int {
    sleepers.count
  }

  /// The number of sleep requests successfully registered since initialization.
  ///
  /// Unlike ``sleeperCount``, this value changes when one pending sleeper is
  /// replaced by another. Combine it with
  /// ``waitForSleepRegistrations(toReach:)`` to wait for latest-wins timing
  /// effects without relying on a fixed number of executor yields.
  public var sleepRegistrationCount: UInt64 {
    successfulSleepRegistrationCount
  }

  /// Advances the clock and resumes any sleepers whose deadlines have passed.
  ///
  /// The two `Task.yield()` calls give recently-spawned sleeper tasks a
  /// chance to reach their registration point, but a fixed yield count is
  /// not reliable under release optimization or parallel test load. When the
  /// test knows how many sleepers must be suspended before time moves, use
  /// ``advance(by:onceSleepersReach:)`` or ``waitForSleepers(atLeast:)`` —
  /// those suspend deterministically on the registration event itself
  /// instead of guessing with yields.
  ///
  /// - Precondition: `duration` must be non-negative.
  public func advance(by duration: Duration) async {
    precondition(duration >= .zero, "ManualTestClock cannot move backwards.")
    await Task.yield()
    current = current.advanced(by: duration)
    resumeReadySleepers()
    await Task.yield()
  }

  /// Suspends until at least `count` sleepers are suspended on this clock,
  /// then advances it by `duration`.
  ///
  /// This is the deterministic variant of ``advance(by:)`` for the common
  /// "trigger an effect, then move time" test shape: it resumes on the sleep
  /// registration event itself, so no yield-count or wall-clock polling is
  /// involved.
  ///
  /// - Precondition: `duration` must be non-negative.
  /// - Throws: `CancellationError` if the waiting task is cancelled before
  ///   the sleeper threshold is reached.
  public func advance(by duration: Duration, onceSleepersReach count: Int) async throws {
    try await waitForSleepers(atLeast: count)
    await advance(by: duration)
  }

  /// Suspends until at least `count` sleepers are suspended on this clock.
  ///
  /// Returns immediately when the threshold is already met. Deterministic:
  /// the waiter resumes on the sleep registration that satisfies the
  /// threshold, not on a poll or yield heuristic.
  ///
  /// - Throws: `CancellationError` if the waiting task is cancelled first.
  public func waitForSleepers(atLeast count: Int) async throws {
    guard sleepers.count < count else { return }
    try await suspendWaiter { sleeperCount, _ in
      sleeperCount >= count
    }
  }

  /// Suspends until the total number of successful sleep registrations since
  /// initialization reaches `threshold`.
  ///
  /// Unlike ``waitForSleepers(atLeast:)`` this also observes registrations
  /// that replace a pending sleeper (latest-wins debounce/throttle shapes,
  /// where ``sleeperCount`` stays flat while registrations keep growing).
  /// Capture ``sleepRegistrationCount`` before the trigger and wait for
  /// `previous + 1`.
  ///
  /// - Throws: `CancellationError` if the waiting task is cancelled first.
  public func waitForSleepRegistrations(toReach threshold: UInt64) async throws {
    guard successfulSleepRegistrationCount < threshold else { return }
    try await suspendWaiter { _, registrations in
      registrations >= threshold
    }
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
    successfulSleepRegistrationCount += 1
    resumeSatisfiedSleeperWaiters()
    return true
  }

  private func cancelSleep(id: UUID) {
    guard let request = sleepers.removeValue(forKey: id) else {
      return
    }
    request.continuation.resume(throwing: CancellationError())
  }

  /// Suspends the caller until `condition` holds for
  /// `(sleeperCount, sleepRegistrationCount)`. The condition is re-evaluated
  /// after every successful sleep registration — the only event that can
  /// raise either value.
  private func suspendWaiter(
    until condition: @escaping @Sendable (Int, UInt64) -> Bool
  ) async throws {
    let waiterID = UUID()
    try Task.checkCancellation()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        guard Task.isCancelled == false else {
          continuation.resume(throwing: CancellationError())
          return
        }
        sleeperWaiters[waiterID] = .init(condition: condition, continuation: continuation)

        if Task.isCancelled, let waiter = sleeperWaiters.removeValue(forKey: waiterID) {
          waiter.continuation.resume(throwing: CancellationError())
        }
      }
    } onCancel: {
      Task {
        await self.cancelWaiter(id: waiterID)
      }
    }
  }

  private func resumeSatisfiedSleeperWaiters() {
    guard sleeperWaiters.isEmpty == false else { return }
    let satisfied = sleeperWaiters.filter { _, waiter in
      waiter.condition(sleepers.count, successfulSleepRegistrationCount)
    }
    for (id, waiter) in satisfied {
      sleeperWaiters.removeValue(forKey: id)
      waiter.continuation.resume()
    }
  }

  private func cancelWaiter(id: UUID) {
    guard let waiter = sleeperWaiters.removeValue(forKey: id) else {
      return
    }
    waiter.continuation.resume(throwing: CancellationError())
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
