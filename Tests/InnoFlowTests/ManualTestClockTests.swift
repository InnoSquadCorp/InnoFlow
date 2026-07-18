// MARK: - ManualTestClockTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import InnoFlowTesting
import Testing

@Suite("ManualTestClock deterministic waits")
struct ManualTestClockTests {

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

    // A second sleeper raises the registration count even while the first
    // is still suspended.
    let second = Task {
      try await clock.sleep(for: .milliseconds(100))
    }
    try await clock.waitForSleepRegistrations(toReach: 2)
    #expect(await clock.sleepRegistrationCount == 2)

    await clock.advance(by: .milliseconds(100))
    try await first.value
    try await second.value
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
