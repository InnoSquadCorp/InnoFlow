// MARK: - TestStoreOwnerFrameworkReportingTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Testing

@testable import InnoFlowCore
@testable import InnoFlowTesting

// The deinit safety net reports from an isolated deinitializer, where
// task-local values — including `Test.current` — are cleared. Without the
// owning framework recorded at initialization, the default reporter falls
// through to XCTest and Swift Testing silently drops the failure.
//
// The last step (an unattributed Swift Testing issue that fails the run)
// cannot be asserted from inside a passing test. Everything before it can:
// the owner recorded at initialization, the channel decision made from it,
// and — by intercepting the report of a store that really deinitializes with
// unconsumed work — that the deinitializer restores the recorded owner around
// its report.

private struct OwnerFeature: Reducer {
  struct State: Equatable, Sendable {}
  enum Action: Equatable, Sendable {
    case noop
    case emit
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .noop:
      return .none
    case .emit:
      return .send(.noop)
    }
  }
}

/// What the reporting context looked like while one diagnostic was reported.
private struct ObservedReport: Sendable {
  let message: String
  let isSwiftTestingCurrent: Bool
  let reportsThroughSwiftTesting: Bool
}

private struct AbandonedStoreObservation: Sendable {
  let ownerUsesSwiftTesting: Bool
  let reportCountBeforeRelease: Int
  let reports: [ObservedReport]
}

/// The reports one store made, shared between the store's reporter and the
/// test that waits for them.
@MainActor
private final class ReportLog {
  var reports: [ObservedReport] = []
}

/// Creates an exhaustive store and leaves one effect action unreceived.
///
/// The store lives in this frame only, so it is released when the function
/// returns. An optimized build does not promise that assigning `nil` to a
/// local releases the object at that statement; leaving a frame does.
@MainActor
@inline(never)
private func leaveUnreceivedAction(
  recordingInto log: ReportLog
) async -> (ownerUsesSwiftTesting: Bool, reportCountBeforeRelease: Int) {
  let store = TestStore(reducer: OwnerFeature(), initialState: .init())
  store.issueReporter = { message, _ in
    log.reports.append(
      ObservedReport(
        message: message,
        isSwiftTestingCurrent: TestStoreReportingContext.isSwiftTestingCurrent,
        reportsThroughSwiftTesting: TestStoreReportingContext.reportsThroughSwiftTesting
      )
    )
  }

  await store.send(.emit)
  // Pin the store until the count that must precede its release is read.
  return withExtendedLifetime(store) {
    (store.ownerUsesSwiftTesting, log.reports.count)
  }
}

/// Lets a store deinitialize without `finish()` while one effect action is
/// unreceived, and returns what its reporter saw.
@MainActor
private func abandonStoreWithUnreceivedAction() async -> AbandonedStoreObservation {
  let log = ReportLog()
  let beforeRelease = await leaveUnreceivedAction(recordingInto: log)
  // The isolated deinitializer normally runs inline on the MainActor; allow
  // for it being scheduled instead.
  for _ in 0..<10_000 where log.reports.isEmpty {
    await Task.yield()
  }
  return AbandonedStoreObservation(
    ownerUsesSwiftTesting: beforeRelease.ownerUsesSwiftTesting,
    reportCountBeforeRelease: beforeRelease.reportCountBeforeRelease,
    reports: log.reports
  )
}

@Suite("TestStore reports through the framework that created it", .timeLimit(.minutes(5)))
struct TestStoreOwnerFrameworkReportingTests {
  @MainActor
  @Test("A store created inside a Swift Testing test records its owner")
  func storeRecordsSwiftTestingOwner() {
    let store = TestStore(reducer: OwnerFeature(), initialState: .init())
    #expect(store.ownerUsesSwiftTesting)
  }

  @Test("A store created outside any test records no Swift Testing owner")
  func storeCreatedOutsideATestRecordsNoOwner() async {
    let ownerUsesSwiftTesting = await Task.detached { @MainActor in
      TestStore(reducer: OwnerFeature(), initialState: .init()).ownerUsesSwiftTesting
    }.value

    #expect(!ownerUsesSwiftTesting)
  }

  @Test("A report made for a Swift Testing owner without a current test still uses Swift Testing")
  func ownerFrameworkDecidesTheChannelWithoutCurrentTest() async {
    // Same situation as an isolated deinitializer: no current test. The
    // decision is asserted directly; actually recording here would post an
    // unattributed issue to every test running in parallel.
    let decision = await Task.detached {
      let isCurrent = TestStoreReportingContext.isSwiftTestingCurrent
      let withoutOwner = TestStoreReportingContext.reportsThroughSwiftTesting
      let withOwner = TestStoreReportingContext.$ownerUsesSwiftTesting.withValue(true) {
        TestStoreReportingContext.reportsThroughSwiftTesting
      }
      return (isCurrent: isCurrent, withoutOwner: withoutOwner, withOwner: withOwner)
    }.value

    #expect(!decision.isCurrent)
    #expect(!decision.withoutOwner)
    #expect(decision.withOwner)
  }

  @MainActor
  @Test("Inside a test the current test decides the channel regardless of the owner")
  func currentTestDecidesTheChannel() {
    #expect(TestStoreReportingContext.isSwiftTestingCurrent)
    #expect(TestStoreReportingContext.reportsThroughSwiftTesting)
  }

  @MainActor
  @Test("The deinit safety net of a Swift Testing store reports through Swift Testing")
  func deinitReportRestoresTheSwiftTestingOwner() async {
    let observation = await abandonStoreWithUnreceivedAction()

    #expect(observation.ownerUsesSwiftTesting)
    // The only report is the one made while the store deinitializes.
    #expect(observation.reportCountBeforeRelease == 0)
    #expect(observation.reports.count == 1)
    #expect(observation.reports.first?.message.contains("noop") == true)
    // The isolated deinitializer cannot see the test that is running, so only
    // the owner it restores around the report selects the channel.
    #expect(observation.reports.first?.isSwiftTestingCurrent == false)
    #expect(observation.reports.first?.reportsThroughSwiftTesting == true)
  }

  @Test("The deinit safety net of a store created outside any test keeps the XCTest channel")
  func deinitReportKeepsTheRecordedNonSwiftTestingOwner() async {
    // The restored value is the recorded owner, not a constant.
    let observation = await Task.detached {
      await abandonStoreWithUnreceivedAction()
    }.value

    #expect(!observation.ownerUsesSwiftTesting)
    #expect(observation.reportCountBeforeRelease == 0)
    #expect(observation.reports.count == 1)
    #expect(observation.reports.first?.isSwiftTestingCurrent == false)
    #expect(observation.reports.first?.reportsThroughSwiftTesting == false)
  }
}
