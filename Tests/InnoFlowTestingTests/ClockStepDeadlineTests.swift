// MARK: - ClockStepDeadlineTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import InnoFlowCore
import InnoFlowTesting
import Testing

// A scenario or explorer clock step waits for sleepers to park before it moves
// time. That wait belongs to the store's one deadline budget (`effectTimeout`),
// and a threshold that is never met is a reported failure — never a silently
// completed step, and never a fabricated reducer reproduction.
//
// Each fixture gives the clock its own, much shorter wait deadline. A step
// that fell back to the clock's deadline, or raced it against the store's,
// would observably end on the wrong one without any long wait.

private struct NeverSleeps: Reducer {
  struct State: Equatable, Sendable {
    var started = false
  }

  enum Action: Equatable, Sendable {
    case start
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    state.started = true
    return .none
  }
}

private struct ReportedFailure {
  let message: String
  let fileID: String
  let line: UInt
}

@MainActor
@Suite("Scenario and explorer clock steps use the store deadline", .timeLimit(.minutes(5)))
struct ClockStepDeadlineTests {
  private static let clockDeadline = Duration.milliseconds(20)
  private static let storeDeadline = Duration.milliseconds(250)

  @Test("A scenario advance whose sleepers never park fails the test and leaves time alone")
  func scenarioAdvanceReportsUnmetThreshold() async {
    let clock = ManualTestClock(waitTimeout: Self.clockDeadline)
    let start = await clock.now
    let store = TestStore(
      reducer: NeverSleeps(), initialState: .init(),
      clock: clock, effectTimeout: Self.storeDeadline)
    var failures: [ReportedFailure] = []
    store.issueReporter = { message, location in
      failures.append(
        .init(message: message, fileID: location.fileID.description, line: location.line))
    }
    let scenario = TestStoreScenario<NeverSleeps>(
      steps: [
        .send(
          .start,
          fileID: "ScenarioFixture/Steps.swift",
          filePath: "/fixtures/Steps.swift",
          line: 41,
          column: 9
        ) { $0.started = true },
        .advance(clock, by: .seconds(1), onceSleepersReach: 1),
        .finish(),
      ]
    )

    let result = await scenario.run(on: store)

    #expect(failures.count == 1)
    let message = failures.first?.message ?? ""
    #expect(message.contains("Scenario step 2/3: advance"))
    #expect(message.contains("at least 1 suspended sleeper(s)"))
    // The wait lasted the store's budget, not the clock's own deadline.
    #expect(message.contains("waited \(Self.storeDeadline) for"))
    // Reported at the scenario's latest user call site, not inside the framework.
    #expect(failures.first?.fileID == "ScenarioFixture/Steps.swift")
    #expect(failures.first?.line == 41)
    #expect(await clock.now == start)
    // Like any failed assertion step, the scenario goes on to its next step.
    #expect(!result.wasCancelled)
    #expect(result.completedStepCount == 3)
  }

  @Test("A scenario advance whose threshold is already met ignores a zero store deadline")
  func scenarioAdvanceWithMetThresholdNeedsNoBudget() async throws {
    let clock = ManualTestClock(waitTimeout: Self.clockDeadline)
    let start = await clock.now
    let sleeper = Task { try await clock.sleep(for: .seconds(1)) }
    defer { sleeper.cancel() }
    try await clock.waitForSleepers(atLeast: 1, timeout: .seconds(60))
    let store = TestStore(
      reducer: NeverSleeps(), initialState: .init(), clock: clock, effectTimeout: .zero)
    var failures: [String] = []
    store.issueReporter = { message, _ in failures.append(message) }
    let scenario = TestStoreScenario<NeverSleeps>(
      steps: [.advance(clock, by: .seconds(1), onceSleepersReach: 1)]
    )

    let result = await scenario.run(on: store)

    #expect(failures.isEmpty)
    #expect(result.completedStepCount == 1)
    #expect(await clock.now == start.advanced(by: .seconds(1)))
    #expect(await clock.sleeperCount == 0)
  }

  @Test("An unmet explorer threshold is a configuration failure decided by the store deadline")
  func explorerClassifiesUnmetThresholdAsConfiguration() async {
    var factories = 0
    let explorer = TestStoreExplorer(
      seed: 1,
      makeStore: {
        factories += 1
        return TestStore(
          reducer: NeverSleeps(), initialState: .init(),
          clock: ManualTestClock(waitTimeout: Self.clockDeadline),
          effectTimeout: Self.storeDeadline)
      },
      choices: { _ in [.advance(by: .seconds(1), onceSleepersReach: 1)] })
    let wallClock = ContinuousClock()
    let started = wallClock.now

    let result = await explorer.run(maxSteps: 1)

    let elapsed = wallClock.now - started
    #expect(result.failure?.kind == .configuration)
    #expect(result.failure?.signature == "exploration precondition: sleeperRegistrationTimedOut")
    // A configuration failure is not a reproduction: nothing is replayed.
    #expect(!result.replayValidated)
    #expect(factories == 1)
    #expect(result.cleanupCompleted)
    // One deadline: the registration wait lasted the store's whole budget.
    #expect(elapsed >= Self.storeDeadline)
  }
}
