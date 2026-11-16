// MARK: - ManualTestClockDeadlineTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import InnoFlowTesting
import Testing

@testable import InnoFlowCoreTestSupport

// A clock wait that can never be satisfied must fail with a diagnostic
// instead of suspending the test until its job is killed, and periodic work
// needs a deterministic way to receive every tick.
//
// The tests are written so that a regression is reported instead of parking
// the suite: a wait that must end on its own deadline runs under `bounded`,
// and a task that is expected to have been resumed is awaited through `join`.
// Both backstops are failure reports, never pacing — they only elapse when the
// behavior under test is broken.

private struct BackstopExceeded: Error {}

/// A wait deadline that must not elapse inside a test: far beyond every
/// backstop below, whatever the wait scale.
private let farDeadline = scaledTestDeadline(.seconds(120))

/// Runs a cancellation-cooperative `operation` that is expected to end by
/// itself, and throws `BackstopExceeded` if it would suspend the test instead.
private func bounded<T: Sendable>(
  _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    defer { group.cancelAll() }
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: scaledTestDeadline(.seconds(5)))
      throw BackstopExceeded()
    }
    guard let first = try await group.next() else { throw BackstopExceeded() }
    return first
  }
}

/// Awaits a task that is expected to finish by itself. If it is still
/// suspended at the backstop — or the test is cancelled by its time limit —
/// the task is cancelled, so a regression fails the test instead of parking it.
@discardableResult
private func join<T: Sendable>(_ task: Task<T, any Error>) async throws -> T {
  let watchdog = Task {
    try await Task.sleep(for: scaledTestDeadline(.seconds(5)))
    task.cancel()
  }
  defer { watchdog.cancel() }
  return try await withTaskCancellationHandler {
    try await task.value
  } onCancel: {
    task.cancel()
  }
}

/// Returns once `count` waits are parked on `clock`. It resumes on the
/// registration itself; the deadline inside `waitUntilAsync` is a backstop.
private func waitsParked(on clock: ManualTestClock, count: Int = 1) async -> Bool {
  await waitUntilAsync(pollInterval: .milliseconds(1)) {
    await clock.pendingWaiterCount == count
  }
}

/// Returns once every wait deadline task on `clock` has ended. A cancelled
/// deadline ends at once; one that was left running stays counted until its
/// own timeout, which the callers set to `farDeadline`.
private func waitDeadlinesEnded(on clock: ManualTestClock) async -> Bool {
  await waitUntilAsync(pollInterval: .milliseconds(1)) {
    await clock.pendingWaitDeadlineCount == 0
  }
}

private struct PeriodicFeature: Reducer {
  struct State: Equatable, Sendable {
    var ticks = 0
  }

  enum Action: Equatable, Sendable {
    case start
    case tick
    case idle
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start:
      return .run { send, context in
        for _ in 0..<3 {
          do {
            try await context.sleep(for: .seconds(1))
          } catch {
            return
          }
          await send(.tick)
        }
      }

    case .tick:
      state.ticks += 1
      return .none

    case .idle:
      return .none
    }
  }
}

@Suite("ManualTestClock waits are bounded and periodic work is steppable", .timeLimit(.minutes(5)))
struct ManualTestClockDeadlineTests {
  // MARK: - Explicit deadlines

  @Test("waitForSleepers reports what it awaited when no sleeper ever parks")
  func waitForSleepersTimesOutWithDiagnostic() async throws {
    let clock = ManualTestClock()

    let error = await #expect(throws: ManualTestClock.WaitTimeout.self) {
      try await clock.waitForSleepers(atLeast: 2, timeout: .milliseconds(50))
    }

    #expect(error?.awaited == "at least 2 suspended sleeper(s)")
    #expect(error?.timeout == .milliseconds(50))
    #expect(error?.sleeperCount == 0)
    #expect(error?.sleepRegistrationCount == 0)
    #expect(error?.description.contains("at least 2 suspended sleeper(s)") == true)
    // The message is one sentence flow, not source indentation.
    #expect(error?.description.contains("  ") == false)
  }

  @Test("advance(by:onceSleepersReach:) fails without moving time when no sleeper parks")
  func gatedAdvanceTimesOutWithoutMovingTime() async throws {
    let clock = ManualTestClock()
    let start = await clock.now

    await #expect(throws: ManualTestClock.WaitTimeout.self) {
      try await clock.advance(
        by: .seconds(1),
        onceSleepersReach: 1,
        timeout: .milliseconds(50)
      )
    }

    #expect(await clock.now == start)
  }

  @Test("Registration and scheduling-read waits are bounded too")
  func registrationAndNowReadWaitsTimeOut() async throws {
    let clock = ManualTestClock()

    let registrations = await #expect(throws: ManualTestClock.WaitTimeout.self) {
      try await clock.waitForSleepRegistrations(toReach: 1, timeout: .milliseconds(50))
    }
    let nowReads = await #expect(throws: ManualTestClock.WaitTimeout.self) {
      try await clock.waitForNowReads(toReach: 1, timeout: .milliseconds(50))
    }

    #expect(registrations?.awaited == "1 sleep registration(s)")
    #expect(nowReads?.awaited == "1 scheduling read(s)")
  }

  // MARK: - Per-clock deadline

  @Test("A clock applies the default wait deadline unless it is created with its own")
  func clockCarriesItsWaitDeadline() {
    #expect(ManualTestClock().waitTimeout == ManualTestClock.defaultWaitTimeout)
    #expect(ManualTestClock(waitTimeout: .milliseconds(40)).waitTimeout == .milliseconds(40))
  }

  @Test("Every wait without timeout: is bounded by the clock's own deadline")
  func waitsWithoutTimeoutUseTheClockDeadline() async throws {
    let clock = ManualTestClock(waitTimeout: .milliseconds(50))
    let start = await clock.now
    let waits: [(name: String, wait: @Sendable (ManualTestClock) async throws -> Void)] = [
      ("waitForSleepers(atLeast:)", { try await $0.waitForSleepers(atLeast: 1) }),
      (
        "waitForSleepRegistrations(toReach:)",
        { try await $0.waitForSleepRegistrations(toReach: 1) }
      ),
      ("waitForNowReads(toReach:)", { try await $0.waitForNowReads(toReach: 1) }),
      (
        "advance(by:onceSleepersReach:)",
        { try await $0.advance(by: .seconds(1), onceSleepersReach: 1) }
      ),
      (
        "advance(by:inStepsOf:onceSleepersReach:)",
        { try await $0.advance(by: .seconds(2), inStepsOf: .seconds(1), onceSleepersReach: 1) }
      ),
    ]

    for (name, wait) in waits {
      // An unbounded wait ends in `BackstopExceeded`, not `WaitTimeout`.
      let error = await #expect(throws: ManualTestClock.WaitTimeout.self, "\(name)") {
        try await bounded { try await wait(clock) }
      }
      #expect(error?.timeout == .milliseconds(50), "\(name)")
    }

    #expect(await clock.now == start)
    #expect(await clock.pendingWaiterCount == 0)
  }

  @Test("An explicit timeout overrides the clock's own deadline")
  func explicitTimeoutOverridesTheClockDeadline() async throws {
    let clock = ManualTestClock(waitTimeout: farDeadline)

    let error = await #expect(throws: ManualTestClock.WaitTimeout.self) {
      try await bounded { try await clock.waitForSleepers(atLeast: 1, timeout: .milliseconds(50)) }
    }

    #expect(error?.timeout == .milliseconds(50))
  }

  // MARK: - Registration lifetime

  @Test("A timed-out wait releases its registration and the clock stays reusable")
  func timedOutWaitReleasesItsRegistration() async throws {
    let clock = ManualTestClock(waitTimeout: .milliseconds(50))
    let start = await clock.now

    await #expect(throws: ManualTestClock.WaitTimeout.self) {
      try await bounded { try await clock.waitForSleepers(atLeast: 1) }
    }
    #expect(await clock.pendingWaiterCount == 0)
    #expect(await clock.pendingWaitDeadlineCount == 0)

    let sleeper = Task { try await clock.sleep(for: .seconds(1)) }
    defer { sleeper.cancel() }
    try await clock.advance(by: .seconds(1), onceSleepersReach: 1, timeout: farDeadline)
    #expect(await clock.now == start.advanced(by: .seconds(1)))
    #expect(await clock.sleeperCount == 0)
    try await join(sleeper)
  }

  @Test("A satisfied wait releases its registration, cancels its deadline and stays reusable")
  func satisfiedWaitLeavesNothingBehind() async throws {
    let clock = ManualTestClock()
    let start = await clock.now
    let waiter = Task { try await clock.waitForSleepers(atLeast: 1, timeout: farDeadline) }
    defer { waiter.cancel() }
    // Park the wait before the sleeper exists, so the registration — not the
    // already-satisfied fast path — is what resumes it.
    try #require(await waitsParked(on: clock))
    #expect(await clock.pendingWaitDeadlineCount == 1)

    let sleeper = Task { try await clock.sleep(for: .seconds(1)) }
    defer { sleeper.cancel() }
    try await join(waiter)

    #expect(await clock.pendingWaiterCount == 0)
    #expect(await waitDeadlinesEnded(on: clock))

    try await clock.advance(by: .seconds(1), onceSleepersReach: 1)
    #expect(await clock.now == start.advanced(by: .seconds(1)))
    #expect(await clock.sleeperCount == 0)
    try await join(sleeper)
  }

  @Test("Cancelling a parked wait reports cancellation, not a timeout, and releases it")
  func cancelledParkedWaitThrowsCancellation() async throws {
    let clock = ManualTestClock()
    let waiter = Task { try await clock.waitForSleepers(atLeast: 1, timeout: farDeadline) }
    defer { waiter.cancel() }
    // Cancel only once the wait is parked; cancelling earlier ends in the
    // entry check and never exercises a registered waiter.
    try #require(await waitsParked(on: clock))

    waiter.cancel()
    let result = await waiter.result

    #expect(throws: CancellationError.self) {
      try result.get()
    }
    #expect(await clock.pendingWaiterCount == 0)
    #expect(await waitDeadlinesEnded(on: clock))
  }

  // MARK: - Periodic work

  @MainActor
  @Test("Control: a single advance delivers one tick of a periodic effect")
  func singleAdvanceDeliversOneTick() async throws {
    let clock = ManualTestClock()
    let store = TestStore(reducer: PeriodicFeature(), initialState: .init(), clock: clock)

    await store.send(.start)
    try await clock.advance(by: .seconds(3), onceSleepersReach: 1)
    await store.receive(.tick) { $0.ticks = 1 }
    // The effect computed its second deadline from the advanced instant.
    try await clock.waitForSleepers(atLeast: 1)
    #expect(store.state.ticks == 1)

    await store.cancelAllEffects()
    await store.finish()
  }

  @MainActor
  @Test("A stepped advance delivers every tick of a periodic effect")
  func steppedAdvanceDeliversEveryTick() async throws {
    let clock = ManualTestClock()
    let store = TestStore(reducer: PeriodicFeature(), initialState: .init(), clock: clock)

    await store.send(.start)
    try await clock.advance(by: .seconds(3), inStepsOf: .seconds(1), onceSleepersReach: 1)
    await store.receive(.tick) { $0.ticks = 1 }
    await store.receive(.tick) { $0.ticks = 2 }
    await store.receive(.tick) { $0.ticks = 3 }

    await store.finish()
  }

  @Test("A stepped advance covers a duration that is not a multiple of its step")
  func steppedAdvanceCoversPartialFinalStep() async throws {
    let clock = ManualTestClock()
    let start = await clock.now
    let sleeper = Task {
      try await clock.sleep(for: .milliseconds(2_500))
    }
    defer { sleeper.cancel() }

    try await clock.advance(
      by: .milliseconds(2_500),
      inStepsOf: .seconds(1),
      onceSleepersReach: 1
    )

    // Exactly the requested duration: two full steps and one half step. A
    // dropped final step leaves the sleeper parked at two seconds.
    #expect(await clock.now == start.advanced(by: .milliseconds(2_500)))
    #expect(await clock.sleeperCount == 0)
    try await join(sleeper)
  }

  @Test("A zero stepped advance waits for the sleeper threshold like a zero gated advance")
  func zeroSteppedAdvanceWaitsForTheThreshold() async throws {
    let clock = ManualTestClock(waitTimeout: .milliseconds(50))
    let start = await clock.now

    await #expect(throws: ManualTestClock.WaitTimeout.self) {
      try await bounded { try await clock.advance(by: .zero, onceSleepersReach: 1) }
    }
    await #expect(throws: ManualTestClock.WaitTimeout.self) {
      try await bounded {
        try await clock.advance(by: .zero, inStepsOf: .seconds(1), onceSleepersReach: 1)
      }
    }

    let sleeper = Task { try await clock.sleep(for: .seconds(1)) }
    defer { sleeper.cancel() }
    try await clock.advance(
      by: .zero, inStepsOf: .seconds(1), onceSleepersReach: 1, timeout: farDeadline)

    // The threshold was met, and a zero advance neither moves time nor
    // resumes a sleeper that is not due.
    #expect(await clock.now == start)
    #expect(await clock.sleeperCount == 1)
  }

  @Test("A stepped advance that times out keeps the time of its completed steps")
  func steppedAdvanceTimeoutKeepsCompletedSteps() async throws {
    let clock = ManualTestClock()
    let start = await clock.now
    // Sleeps once, so only the first increment finds a suspended sleeper.
    let sleeper = Task { try await clock.sleep(for: .seconds(1)) }
    defer { sleeper.cancel() }
    // Park it first: the short deadline below must only ever expire in the
    // second increment, however slowly the sleeper task starts.
    try await clock.waitForSleepers(atLeast: 1, timeout: farDeadline)

    let error = await #expect(throws: ManualTestClock.WaitTimeout.self) {
      try await bounded {
        try await clock.advance(
          by: .seconds(3),
          inStepsOf: .seconds(1),
          onceSleepersReach: 1,
          timeout: .milliseconds(50)
        )
      }
    }

    #expect(error?.sleepRegistrationCount == 1)
    #expect(error?.sleeperCount == 0)
    #expect(await clock.now == start.advanced(by: .seconds(1)))
    #expect(await clock.pendingWaiterCount == 0)
    try await join(sleeper)
  }

  @Test("A stepped advance counts every sleeper that must park before time moves")
  func steppedAdvanceWithLongLivedAndPeriodicSleepers() async throws {
    let clock = ManualTestClock()
    let start = await clock.now
    let longLived = Task { try await clock.sleep(for: .seconds(60)) }
    defer { longLived.cancel() }
    let periodic = Task {
      var tickOffsets: [Duration] = []
      for _ in 0..<3 {
        try await clock.sleep(for: .seconds(1))
        tickOffsets.append(await clock.now - start)
      }
      return tickOffsets
    }
    defer { periodic.cancel() }

    // Two sleepers must be suspended before each increment. With a count of
    // one the long-lived sleeper alone meets the threshold, so an increment
    // could start while the periodic sleeper is still running and its next
    // deadline would be computed from a later instant.
    try await clock.advance(by: .seconds(3), inStepsOf: .seconds(1), onceSleepersReach: 2)

    #expect(await clock.now == start.advanced(by: .seconds(3)))
    // Only the long-lived sleeper is left: the periodic one was resumed for
    // its third tick and does not sleep again.
    #expect(await clock.sleeperCount == 1)
    #expect(await clock.sleepRegistrationCount == 4)
    #expect(try await join(periodic) == [.seconds(1), .seconds(2), .seconds(3)])
  }
}
