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

  /// Thrown when a clock wait reaches its deadline before the awaited event.
  ///
  /// A wait that can never be satisfied — the effect under test never slept,
  /// slept on a different clock, or was already cancelled — would otherwise
  /// suspend the test until the surrounding job is killed. The error names
  /// what was awaited and what the clock had actually observed.
  public struct WaitTimeout: Error, Sendable, Equatable, CustomStringConvertible {
    /// What the wait was for, for example `"at least 1 suspended sleeper"`.
    public let awaited: String
    public let timeout: Duration
    public let sleeperCount: Int
    public let sleepRegistrationCount: UInt64
    public let nowReadCount: UInt64

    public var description: String {
      """
      ManualTestClock waited \(timeout) for \(awaited), but the clock only observed \
      \(sleeperCount) suspended sleeper(s), \(sleepRegistrationCount) sleep registration(s) \
      and \(nowReadCount) scheduling read(s). Check that the effect sleeps through \
      this clock and was not cancelled before it could.
      """
    }
  }

  /// The deadline a clock applies to its waits unless it was created with its
  /// own (``init(now:waitTimeout:)``) or a call passes `timeout:`.
  ///
  /// Waits resume on the awaited event itself, so this is a failure backstop
  /// rather than a polling interval: it only elapses when the event never
  /// happens.
  public static let defaultWaitTimeout: Duration = .seconds(10)

  /// The deadline this clock applies to a wait whose call does not pass
  /// `timeout:` — ``defaultWaitTimeout`` unless the clock was created with
  /// ``init(now:waitTimeout:)``.
  public nonisolated let waitTimeout: Duration

  private struct SleeperWaiter {
    /// Evaluated against
    /// `(sleeperCount, sleepRegistrationCount, nowReadCount)` after every
    /// observable clock event.
    let condition: @Sendable (Int, UInt64, UInt64) -> Bool
    let awaited: String
    let timeout: Duration
    let continuation: CheckedContinuation<Void, any Error>
  }

  private var current: Instant
  private var sleepers: [UUID: SleepRequest] = [:]
  private var sleeperWaiters: [UUID: SleeperWaiter] = [:]
  /// Wait deadlines whose task has not ended yet. A deadline task ends when
  /// its time elapses or when its wait cancels it, so this returns to zero
  /// promptly only if every finished wait cancelled its deadline.
  private var activeWaitDeadlineCount = 0
  private var nextInsertionOrder: UInt64 = 0
  private var successfulSleepRegistrationCount: UInt64 = 0
  private var successfulNowReadCount: UInt64 = 0

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
    successfulNowReadCount = 0
  }

  /// Creates a deterministic test clock starting from the supplied instant.
  ///
  /// Waits that do not pass `timeout:` use ``defaultWaitTimeout``.
  public init(now: Instant = ContinuousClock().now) {
    self.current = now
    self.waitTimeout = Self.defaultWaitTimeout
  }

  /// Creates a deterministic test clock whose waits use `waitTimeout` unless
  /// a call passes its own `timeout:`.
  ///
  /// The deadline is a failure backstop on wall-clock time, never pacing: a
  /// wait resumes on its event, and the deadline only elapses when that event
  /// never happens. Shorten it to make a test that is expected to time out
  /// fail fast; lengthen it for a saturated machine.
  public init(now: Instant = ContinuousClock().now, waitTimeout: Duration) {
    self.current = now
    self.waitTimeout = waitTimeout
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

  /// The number of scheduling-time reads made through `StoreClock.manual(_:)`.
  ///
  /// Capture this value before sending a throttle action and wait for
  /// ``waitForNowReads(toReach:)`` to ensure the effect has observed the
  /// intended logical instant before advancing manual time. Reading ``now``
  /// directly does not increment this counter.
  public var nowReadCount: UInt64 {
    successfulNowReadCount
  }

  /// The number of waits currently suspended on this clock.
  ///
  /// A wait is registered while it is parked and leaves when it is satisfied,
  /// times out or is cancelled. Package-level observation for the framework's
  /// own tests; a test of a feature never needs it.
  package var pendingWaiterCount: Int {
    sleeperWaiters.count
  }

  /// The number of wait deadlines whose task has not ended.
  ///
  /// A finished wait cancels its deadline, which ends that task at once. A
  /// value that stays above ``pendingWaiterCount`` therefore means a wait left
  /// its deadline running. Package-level observation for the framework's own
  /// tests.
  package var pendingWaitDeadlineCount: Int {
    activeWaitDeadlineCount
  }

  /// Advances the clock once and resumes any sleepers whose deadlines have passed.
  ///
  /// Time moves in a single jump. A sleeper that resumes and sleeps again —
  /// a periodic effect — computes its next deadline from the new instant, so
  /// one `advance(by: .seconds(3))` delivers one tick of a one-second timer,
  /// not three. Use ``advance(by:inStepsOf:onceSleepersReach:)`` to
  /// drive periodic work.
  ///
  /// The two `Task.yield()` calls give recently-spawned sleeper tasks a
  /// chance to reach their registration point, but a fixed yield count is
  /// not reliable under release optimization or parallel test load. When the
  /// test knows how many sleepers must be suspended before time moves, use
  /// ``advance(by:onceSleepersReach:)`` or
  /// ``waitForSleepers(atLeast:)`` — those suspend deterministically
  /// on the registration event itself instead of guessing with yields.
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
  /// - Throws: ``WaitTimeout`` if the sleeper threshold is not reached within
  ///   this clock's ``waitTimeout``; `CancellationError` if the waiting task
  ///   is cancelled first.
  public func advance(by duration: Duration, onceSleepersReach count: Int) async throws {
    try await advance(
      by: duration,
      onceSleepersReach: count,
      timeout: waitTimeout
    )
  }

  /// ``advance(by:onceSleepersReach:)`` with an explicit wait deadline.
  ///
  /// - Throws: ``WaitTimeout`` if the sleeper threshold is not reached within
  ///   `timeout`; `CancellationError` if the waiting task is cancelled first.
  public func advance(
    by duration: Duration,
    onceSleepersReach count: Int,
    timeout: Duration
  ) async throws {
    try await waitForSleepers(atLeast: count, timeout: timeout)
    await advance(by: duration)
  }

  /// Advances the clock by `duration` in increments of `step`, waiting before
  /// every increment until at least `count` sleepers are suspended.
  ///
  /// This drives periodic effects deterministically: each increment resumes
  /// the sleepers that are due, and the next increment starts only after the
  /// sleeper threshold is met again. A final partial increment covers a
  /// `duration` that is not a multiple of `step`, and a zero `duration` still
  /// waits for the threshold once, like ``advance(by:onceSleepersReach:)``.
  ///
  /// ```swift
  /// // A timer that sleeps one second per tick emits three ticks.
  /// try await clock.advance(by: .seconds(3), inStepsOf: .seconds(1), onceSleepersReach: 1)
  /// ```
  ///
  /// The threshold is "at least `count` suspended sleepers", not "the sleeper
  /// that just resumed has parked again". Pass the total number of sleepers
  /// that must be suspended before time may move. With one long-lived sleeper
  /// and one periodic sleeper, `count: 1` is already met by the long-lived
  /// sleeper while the periodic one is still running, so an increment can
  /// start before it parks and that tick is lost; `count: 2` waits for both.
  ///
  /// Every increment's wait has its own deadline. When one is missed — the
  /// periodic work ended, or `count` was too high — the clock keeps the time
  /// of the increments that completed.
  ///
  /// - Precondition: `duration` must be non-negative and `step` positive.
  /// - Throws: ``WaitTimeout`` if the sleeper threshold is not reached within
  ///   this clock's ``waitTimeout`` before an increment; `CancellationError`
  ///   if the waiting task is cancelled first.
  public func advance(
    by duration: Duration,
    inStepsOf step: Duration,
    onceSleepersReach count: Int
  ) async throws {
    try await advance(
      by: duration,
      inStepsOf: step,
      onceSleepersReach: count,
      timeout: waitTimeout
    )
  }

  /// ``advance(by:inStepsOf:onceSleepersReach:)`` with an explicit deadline
  /// for the wait before each increment.
  ///
  /// - Precondition: `duration` must be non-negative and `step` positive.
  /// - Throws: ``WaitTimeout`` if the sleeper threshold is not reached within
  ///   `timeout` before an increment; `CancellationError` if the waiting task
  ///   is cancelled first.
  public func advance(
    by duration: Duration,
    inStepsOf step: Duration,
    onceSleepersReach count: Int,
    timeout: Duration
  ) async throws {
    precondition(duration >= .zero, "ManualTestClock cannot move backwards.")
    precondition(step > .zero, "ManualTestClock steps must be positive.")
    var remaining = duration
    // At least one increment runs, so a zero duration still waits for the
    // threshold exactly like `advance(by: .zero, onceSleepersReach:)`.
    repeat {
      let increment = min(step, remaining)
      try await advance(by: increment, onceSleepersReach: count, timeout: timeout)
      remaining -= increment
    } while remaining > .zero
  }

  /// Suspends until at least `count` sleepers are suspended on this clock.
  ///
  /// Returns immediately when the threshold is already met. Deterministic:
  /// the waiter resumes on the sleep registration that satisfies the
  /// threshold, not on a poll or yield heuristic.
  ///
  /// - Throws: ``WaitTimeout`` if the threshold is not reached within this
  ///   clock's ``waitTimeout``; `CancellationError` if the waiting task is
  ///   cancelled first.
  public func waitForSleepers(atLeast count: Int) async throws {
    try await waitForSleepers(atLeast: count, timeout: waitTimeout)
  }

  /// ``waitForSleepers(atLeast:)`` with an explicit wait deadline.
  ///
  /// - Throws: ``WaitTimeout`` if the threshold is not reached within
  ///   `timeout`; `CancellationError` if the waiting task is cancelled first.
  public func waitForSleepers(atLeast count: Int, timeout: Duration) async throws {
    guard sleepers.count < count else { return }
    try await suspendWaiter(
      for: "at least \(count) suspended sleeper(s)",
      timeout: timeout
    ) { sleeperCount, _, _ in
      sleeperCount >= count
    }
  }

  /// Suspends until the total number of successful sleep registrations since
  /// initialization reaches `threshold`.
  ///
  /// Unlike ``waitForSleepers(atLeast:)`` this also observes
  /// registrations that replace a pending sleeper (latest-wins
  /// debounce/throttle shapes, where ``sleeperCount`` stays flat while
  /// registrations keep growing). Capture ``sleepRegistrationCount`` before
  /// the trigger and wait for `previous + 1`.
  ///
  /// - Throws: ``WaitTimeout`` if the threshold is not reached within this
  ///   clock's ``waitTimeout``; `CancellationError` if the waiting task is
  ///   cancelled first.
  public func waitForSleepRegistrations(toReach threshold: UInt64) async throws {
    try await waitForSleepRegistrations(toReach: threshold, timeout: waitTimeout)
  }

  /// ``waitForSleepRegistrations(toReach:)`` with an explicit wait deadline.
  ///
  /// - Throws: ``WaitTimeout`` if the threshold is not reached within
  ///   `timeout`; `CancellationError` if the waiting task is cancelled first.
  public func waitForSleepRegistrations(
    toReach threshold: UInt64,
    timeout: Duration
  ) async throws {
    guard successfulSleepRegistrationCount < threshold else { return }
    try await suspendWaiter(
      for: "\(threshold) sleep registration(s)",
      timeout: timeout
    ) { _, registrations, _ in
      registrations >= threshold
    }
  }

  /// Suspends until scheduling code has read this clock at least `threshold`
  /// times through the `StoreClock.manual(_:)` adapter.
  ///
  /// This is useful for throttle tests whose active-window updates do not
  /// register a new sleeper. It prevents a test from advancing manual time
  /// before the effect has captured the trigger's logical instant.
  ///
  /// - Throws: ``WaitTimeout`` if the threshold is not reached within this
  ///   clock's ``waitTimeout``; `CancellationError` if the waiting task is
  ///   cancelled first.
  public func waitForNowReads(toReach threshold: UInt64) async throws {
    try await waitForNowReads(toReach: threshold, timeout: waitTimeout)
  }

  /// ``waitForNowReads(toReach:)`` with an explicit wait deadline.
  ///
  /// - Throws: ``WaitTimeout`` if the threshold is not reached within
  ///   `timeout`; `CancellationError` if the waiting task is cancelled first.
  public func waitForNowReads(toReach threshold: UInt64, timeout: Duration) async throws {
    guard successfulNowReadCount < threshold else { return }
    try await suspendWaiter(
      for: "\(threshold) scheduling read(s)",
      timeout: timeout
    ) { _, _, nowReads in
      nowReads >= threshold
    }
  }

  /// Suspends until the clock has been advanced by at least `duration`.
  /// Nonpositive durations return immediately unless the task is cancelled.
  ///
  /// - Throws: `CancellationError` if the task is already cancelled, including
  ///   for zero or negative durations, or is cancelled while suspended.
  public func sleep(for duration: Duration) async throws {
    try Task.checkCancellation()
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
        guard registerSleep(id: sleeperID, deadline: deadline, continuation: continuation) else {
          continuation.resume(throwing: CancellationError())
          return
        }

        if Task.isCancelled, let request = sleepers.removeValue(forKey: sleeperID) {
          request.continuation.resume(throwing: CancellationError())
          return
        }

        // Count the registration and wake waiters only after the inline
        // cancellation check confirms the sleeper actually parked. This
        // whole closure runs synchronously on the actor, so outside
        // observers never see the transient registration of a sleeper that
        // was cancelled before it ever suspended — otherwise
        // waitForSleepers(atLeast:) could wake for a sleeper that is
        // already gone by the time the waiter advances the clock.
        commitSleepRegistration()
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

  /// Inserts the sleep request without publishing it. `sleep` calls
  /// `commitSleepRegistration()` after its inline cancellation check so
  /// counters and waiters only ever observe sleepers that actually parked.
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

  private func commitSleepRegistration() {
    successfulSleepRegistrationCount += 1
    resumeSatisfiedSleeperWaiters()
  }

  fileprivate func readNowForScheduling() -> Instant {
    successfulNowReadCount += 1
    resumeSatisfiedSleeperWaiters()
    return current
  }

  private func cancelSleep(id: UUID) {
    guard let request = sleepers.removeValue(forKey: id) else {
      return
    }
    request.continuation.resume(throwing: CancellationError())
  }

  /// Suspends the caller until `condition` holds for
  /// `(sleeperCount, sleepRegistrationCount, nowReadCount)` or `timeout`
  /// elapses. The condition is re-evaluated after every successful sleep
  /// registration or scheduling-time read — the only events that can raise
  /// those values.
  private func suspendWaiter(
    for awaited: String,
    timeout: Duration,
    until condition: @escaping @Sendable (Int, UInt64, UInt64) -> Bool
  ) async throws {
    let waiterID = UUID()
    try Task.checkCancellation()
    // The deadline runs on wall-clock time: it bounds how long a test may
    // hang, which manual time cannot express. The wait cancels it on every
    // exit, so a satisfied or cancelled wait leaves no sleeping task behind.
    activeWaitDeadlineCount += 1
    let deadline = Task { [weak self] in
      let elapsed: Bool
      do {
        try await Task.sleep(for: timeout)
        elapsed = true
      } catch {
        elapsed = false
      }
      await self?.waitDeadlineEnded(waiterID: waiterID, elapsed: elapsed)
    }
    defer { deadline.cancel() }

    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        guard Task.isCancelled == false else {
          continuation.resume(throwing: CancellationError())
          return
        }
        sleeperWaiters[waiterID] = .init(
          condition: condition,
          awaited: awaited,
          timeout: timeout,
          continuation: continuation
        )

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

  private func waitDeadlineEnded(waiterID: UUID, elapsed: Bool) {
    activeWaitDeadlineCount -= 1
    if elapsed {
      timeOutWaiter(id: waiterID)
    }
  }

  private func timeOutWaiter(id: UUID) {
    guard let waiter = sleeperWaiters.removeValue(forKey: id) else {
      return
    }
    waiter.continuation.resume(
      throwing: WaitTimeout(
        awaited: waiter.awaited,
        timeout: waiter.timeout,
        sleeperCount: sleepers.count,
        sleepRegistrationCount: successfulSleepRegistrationCount,
        nowReadCount: successfulNowReadCount
      )
    )
  }

  private func resumeSatisfiedSleeperWaiters() {
    guard sleeperWaiters.isEmpty == false else { return }
    let satisfied = sleeperWaiters.filter { _, waiter in
      waiter.condition(
        sleepers.count,
        successfulSleepRegistrationCount,
        successfulNowReadCount
      )
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
        await clock.readNowForScheduling()
      },
      sleep: { duration in
        try await clock.sleep(for: duration)
      }
    )
  }
}
