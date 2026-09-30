// MARK: - ManualTestClockTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import InnoFlowTesting
import Testing

@Suite("ManualTestClock deterministic waits")
struct ManualTestClockTests {

  @Test("Pre-cancelled sleep throws for negative, zero and positive durations")
  func preCancelledSleepMatchesContinuous() async {
    for duration in [Duration.nanoseconds(-1), .zero, .nanoseconds(1)] {
      let clock = ManualTestClock()
      let sleeps: [@Sendable (Duration) async throws -> Void] = [
        { try await clock.sleep(for: $0) },
        StoreClock.manual(clock).sleep,
        StoreClock.continuous.sleep,
      ]
      for sleep in sleeps {
        let task = Task {
          // Cancel this task itself so cancellation precedes the call without a race.
          withUnsafeCurrentTask { $0?.cancel() }
          try await sleep(duration)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
      }
      #expect(await clock.sleeperCount == 0)
      #expect(await clock.sleepRegistrationCount == 0)
    }
  }

  @Test("Uncancelled nonpositive sleep returns without parking or advancing time")
  func nonPositiveSleepMatchesContinuous() async throws {
    let clock = ManualTestClock()
    let initial = await clock.now
    for duration in [Duration.nanoseconds(-1), .zero] {
      try await clock.sleep(for: duration)
      try await StoreClock.manual(clock).sleep(duration)
      try await StoreClock.continuous.sleep(duration)
    }
    #expect(await clock.now == initial)
    #expect(await clock.sleeperCount == 0)
    #expect(await clock.sleepRegistrationCount == 0)
  }

  @Test("Cancelling a registered sleep cleans up and leaves the clock reusable")
  func registeredSleepCancellationCleansUp() async throws {
    let clock = ManualTestClock()
    let sleeper = Task { try await StoreClock.manual(clock).sleep(.seconds(1)) }
    try await clock.waitForSleepers(atLeast: 1)
    sleeper.cancel()
    await #expect(throws: CancellationError.self) { try await sleeper.value }
    #expect(await clock.sleeperCount == 0)
    #expect(await clock.sleepRegistrationCount == 1)

    let next = Task { try await clock.sleep(for: .seconds(1)) }
    try await clock.advance(by: .seconds(1), onceSleepersReach: 1)
    try await next.value
    #expect(await clock.sleeperCount == 0)
    #expect(await clock.sleepRegistrationCount == 2)
  }

  @Test("waitForSleepers resumes when the sleeper threshold is reached")
  func waitForSleepersResumesOnRegistration() async throws {
    let clock = ManualTestClock()

    let sleeper = Task {
      try await clock.sleep(for: .milliseconds(100))
    }

    // Deterministic: suspends until the sleeper task actually registers,
    // regardless of how many yields that takes.
    try await clock.waitForSleepers(atLeast: 1)
    #expect(await clock.sleeperCount == 1)

    await clock.advance(by: .milliseconds(100))
    try await sleeper.value
    #expect(await clock.sleeperCount == 0)
  }

  @Test("waitForSleepers returns immediately when the threshold is already met")
  func waitForSleepersImmediateWhenSatisfied() async throws {
    let clock = ManualTestClock()

    let sleeper = Task {
      try await clock.sleep(for: .milliseconds(50))
    }
    try await clock.waitForSleepers(atLeast: 1)

    // Threshold already met — must not suspend.
    try await clock.waitForSleepers(atLeast: 1)

    await clock.advance(by: .milliseconds(50))
    try await sleeper.value
  }

  @Test("advance(by:onceSleepersReach:) gates time movement on registration")
  func advanceOnceSleepersReach() async throws {
    let clock = ManualTestClock()

    let sleeper = Task {
      try await clock.sleep(for: .milliseconds(20))
      return true
    }

    try await clock.advance(by: .milliseconds(20), onceSleepersReach: 1)
    #expect(try await sleeper.value)
  }

  @Test("waitForSleepRegistrations observes latest-wins replacement")
  func waitForSleepRegistrationsCountsReplacements() async throws {
    let clock = ManualTestClock()

    let first = Task {
      try await clock.sleep(for: .milliseconds(100))
    }
    try await clock.waitForSleepRegistrations(toReach: 1)

    // Latest-wins replacement: cancel the pending sleeper, then register a
    // new one. sleeperCount returns to its previous level while the
    // registration count keeps growing — the shape waitForSleepers(atLeast:)
    // cannot observe and this API exists for.
    first.cancel()
    await #expect(throws: CancellationError.self) {
      try await first.value
    }
    #expect(await clock.sleeperCount == 0)

    let second = Task {
      try await clock.sleep(for: .milliseconds(100))
    }
    try await clock.waitForSleepRegistrations(toReach: 2)
    #expect(await clock.sleepRegistrationCount == 2)
    #expect(await clock.sleeperCount == 1)

    await clock.advance(by: .milliseconds(100))
    try await second.value
  }

  @Test("waitForNowReads observes scheduling reads without counting direct inspection")
  func waitForNowReadsObservesStoreClockAdapter() async throws {
    let clock = ManualTestClock()
    let storeClock = StoreClock.manual(clock)

    _ = await clock.now
    #expect(await clock.nowReadCount == 0)

    let waiter = Task {
      try await clock.waitForNowReads(toReach: 1)
    }
    _ = await storeClock.now()
    try await waiter.value

    #expect(await clock.nowReadCount == 1)
  }

  @Test("waiting task cancellation propagates as CancellationError")
  func waiterCancellationThrows() async throws {
    let clock = ManualTestClock()

    let waiter = Task {
      try await clock.waitForSleepers(atLeast: 1)
    }
    waiter.cancel()

    await #expect(throws: CancellationError.self) {
      try await waiter.value
    }
  }
}
