// MARK: - EffectTaskTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import SwiftUI
import Testing
import os

@testable import InnoFlow
@testable import InnoFlowTesting

// MARK: - EffectTask Tests

@Suite("EffectTask Tests", .serialized)
@MainActor
struct EffectTaskTests {

  @Test("StaticEffectID supports string literals")
  func staticEffectIDStringLiteral() {
    let first: StaticEffectID = "load-user"
    let second = StaticEffectID("load-user")

    #expect(first == second)
    #expect(first.hashValue == second.hashValue)
    #expect(first.rawValue == "load-user")
  }

  @Test("EffectID supports dynamic and non-string raw values")
  func effectIDDynamicRawValues() {
    let dynamic = StaticEffectID("load-\(42)")
    let uuid = UUID()
    let first = EffectID(uuid)
    let second = EffectID(uuid)

    #expect(dynamic.rawValue == "load-42")
    #expect(first == second)
    #expect(AnyEffectID(first) != AnyEffectID(dynamic))
  }

  @Test("EffectTask.none does not emit follow-up actions")
  func effectNone() async {
    let store = TestStore(reducer: CounterFeature(), initialState: .init())

    await store.send(.increment) {
      $0.count = 1
    }

    await store.assertNoMoreActions()
  }

  @Test("EffectTask.send emits a follow-up action")
  func effectSend() async {
    let store = TestStore(reducer: ImmediateSendFeature(), initialState: .init())

    await store.send(.trigger)

    await store.receive(._logged("event")) {
      $0.logs = ["event"]
    }

    await store.assertNoMoreActions()
  }

  @Test("EffectTask.cancellable keeps only the latest in-flight effect")
  func effectCancellable() async {
    let store = TestStore(reducer: CancellableFeature(), initialState: .init())

    await store.send(.start(1)) {
      $0.requested = 1
    }
    await store.send(.start(2)) {
      $0.requested = 2
    }

    await store.receive(._completed(2)) {
      $0.completed = [2]
    }

    await store.assertNoMoreActions()
  }

  @Test("EffectTask.debounce keeps only the latest trigger")
  func effectDebounce() async {
    let clock = ManualTestClock()
    let store = TestStore(reducer: DebounceFeature(), initialState: .init(), clock: clock)

    await store.send(.trigger(1))
    await store.send(.trigger(2))

    for _ in 0..<200 {
      if await clock.sleeperCount == 1 {
        break
      }
      await Task.yield()
    }
    await clock.advance(by: .milliseconds(60))

    await store.receive(._emitted(2)) {
      $0.emitted = [2]
    }

    await store.assertNoMoreActions()
  }

  @Test("EffectTask.throttle uses leading-only semantics")
  func effectThrottleLeadingOnly() async {
    let clock = ManualTestClock()
    let store = TestStore(reducer: ThrottleFeature(), initialState: .init(), clock: clock)

    await store.send(.trigger(1))
    await store.send(.trigger(2))

    await store.receive(._emitted(1)) {
      $0.emitted = [1]
    }
    await store.assertNoMoreActions()

    await Task.yield()
    await clock.advance(by: .milliseconds(160))
    await store.send(.trigger(3))
    await store.receive(._emitted(3)) {
      $0.emitted = [1, 3]
    }
    await store.assertNoMoreActions()
  }

  @Test("EffectTask.throttle trailing-only executes latest at window end")
  func effectThrottleTrailingOnly() async {
    let clock = ManualTestClock()
    let store = TestStore(reducer: ThrottleTrailingFeature(), initialState: .init(), clock: clock)

    await store.send(.trigger(1))
    await store.send(.trigger(2))
    await Task.yield()
    await clock.advance(by: .milliseconds(80))

    await store.receive(._emitted(2)) {
      $0.emitted = [2]
    }
    await store.assertNoMoreActions()
  }

  @Test("EffectTask.throttle leading+trailing executes both when window has extra event")
  func effectThrottleLeadingAndTrailing() async {
    let clock = ManualTestClock()
    let store = TestStore(
      reducer: ThrottleLeadingTrailingFeature(), initialState: .init(), clock: clock)

    await store.send(.trigger(1))
    await store.send(.trigger(2))

    await store.receive(._emitted(1)) {
      $0.emitted = [1]
    }
    await Task.yield()
    await clock.advance(by: .milliseconds(80))
    await store.receive(._emitted(2)) {
      $0.emitted = [1, 2]
    }
    await store.assertNoMoreActions()
  }

  @Test("EffectTask.animation executes nested send and run effects")
  func effectAnimationExecutes() async {
    let store = TestStore(reducer: AnimationFeature(), initialState: .init())

    await store.send(.animate(1))
    await store.receive(._animated(1)) {
      $0.values = [1]
    }

    await store.send(.animateRun(2))
    await store.receive(._animated(2)) {
      $0.values = [1, 2]
    }

    await store.assertNoMoreActions()
  }

  @Test("EffectTask.animation composes with debounce")
  func effectAnimationComposedWithDebounce() async {
    let store = TestStore(reducer: ComposedAnimationFeature(), initialState: .init())

    await store.send(.trigger(1))
    await store.receive(._result(1)) {
      $0.value = 1
    }
    await store.assertNoMoreActions()
  }

  @Test("EffectTask.concatenate preserves declared send order")
  func effectConcatenatePreservesSendOrder() async {
    let store = TestStore(
      reducer: QueueDispatchFeature(probe: ReducerDepthProbe()),
      initialState: .init()
    )

    await store.send(.start) {
      $0.logs = ["start"]
    }

    await store.receive(.first) {
      $0.logs = ["start", "first"]
    }
    await store.receive(.second) {
      $0.logs = ["start", "first", "second"]
    }

    await store.assertNoMoreActions()
  }

  @Test("EffectTask.run emits follow-up actions after the async boundary")
  func effectRunEmitsAfterAsyncBoundary() async {
    let store = TestStore(
      reducer: QueueDispatchFeature(probe: ReducerDepthProbe()),
      initialState: .init()
    )

    await store.send(.loadAsync) {
      $0.logs = ["loadAsync"]
    }

    await store.receive(._loadedAsync) {
      $0.logs = ["loadAsync", "loadedAsync"]
    }

    await store.assertNoMoreActions()
  }

  @Test("EffectTask.merge emits in child completion order rather than declaration order")
  func effectMergeUsesCompletionOrder() async throws {
    let clock = ManualTestClock()
    let store = TestStore(reducer: MergeOrderingFeature(), initialState: .init(), clock: clock)

    await store.send(.start)

    try #require(
      await waitUntilAsync(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
        await clock.sleeperCount == 2
      }
    )
    await clock.advance(by: .milliseconds(5))
    await store.receive(._emitted("fast")) {
      $0.emitted = ["fast"]
    }

    await clock.advance(by: .milliseconds(25))
    await store.receive(._emitted("slow")) {
      $0.emitted = ["fast", "slow"]
    }

    await store.assertNoMoreActions()
  }

  @Test("Parent-child orchestration can be modeled as ordered child actions")
  func parentChildOrchestration() async {
    let store = TestStore(reducer: ParentChildOrchestrationFeature(), initialState: .init())

    await store.send(.refresh) {
      $0.isRefreshing = true
      $0.log = ["refresh"]
    }

    await store.receive(.child(.profileLoaded)) {
      $0.profileLoaded = true
      $0.log = ["refresh", "profile"]
    }
    await store.receive(.child(.permissionsLoaded)) {
      $0.permissionsLoaded = true
      $0.log = ["refresh", "profile", "permissions"]
    }
    await store.receive(._finished) {
      $0.isRefreshing = false
      $0.log = ["refresh", "profile", "permissions", "finished"]
    }

    await store.assertNoMoreActions()
  }

  @Test("Long-running orchestration can mix immediate and awaited progress actions")
  func longRunningOrchestration() async {
    let store = TestStore(reducer: LongRunningOrchestrationFeature(), initialState: .init())

    await store.send(.start)
    await store.receive(._progress(0)) {
      $0.progress = [0]
    }
    await store.receive(._progress(50)) {
      $0.progress = [0, 50]
    }
    await store.receive(._finished) {
      $0.finished = true
    }

    await store.assertNoMoreActions()
  }

  @Test("EffectTask.run consumes AsyncSequence actions")
  func effectRunConsumesAsyncSequenceActions() async throws {
    let clock = ManualTestClock()
    let store = TestStore(
      reducer: AsyncSequenceConsumerFeature(),
      initialState: .init(),
      clock: clock
    )

    await store.send(.startActions([1, 2]))
    try #require(await waitForSleeperCount(clock, atLeast: 1))
    await clock.advance(by: .milliseconds(10))
    await store.receive(.value(1)) {
      $0.values = [1]
    }

    try #require(await waitForSleeperCount(clock, atLeast: 1))
    await clock.advance(by: .milliseconds(10))
    await store.receive(.value(2)) {
      $0.values = [1, 2]
    }

    await store.assertNoMoreActions()
  }

  @Test("EffectTask.run AsyncSequence helper works with dynamic cancellation IDs")
  func effectRunAsyncSequenceUsesDynamicCancellationID() async throws {
    let id = UUID()
    let clock = ManualTestClock()
    let store = TestStore(
      reducer: AsyncSequenceConsumerFeature(),
      initialState: .init(),
      clock: clock,
      effectTimeout: .milliseconds(50)
    )

    await store.send(.startTransformed(id: id, values: [1, 2, 3]))
    try #require(await waitForSleeperCount(clock, atLeast: 1))
    await clock.advance(by: .milliseconds(10))
    await store.receive(.value(1)) {
      $0.values = [1]
    }

    try #require(await waitForSleeperCount(clock, atLeast: 1))
    await store.send(.cancel(id))
    await clock.advance(by: .milliseconds(30))

    await store.assertNoMoreActions()
  }

  @Test(
    "EffectTask.cancellable latest-wins semantics hold across random trigger streams",
    arguments: Array(0..<50)
  )
  func effectCancellableLatestWinsProperty(seed: Int) async throws {
    let store = TestStore(reducer: CancellableFeature(), initialState: .init())
    var rng = SeededGenerator(seed: UInt64(seed + 1))
    let count = rng.nextInt(upperBound: 6) + 2
    let values = (0..<count).map { _ in rng.nextInt(upperBound: 10_000) }

    for (index, value) in values.enumerated() {
      await store.send(.start(value)) {
        $0.requested = index + 1
      }
    }

    let winner = try #require(values.last)
    await store.receive(._completed(winner)) {
      $0.completed = [winner]
    }
    await store.assertNoMoreActions()
  }

  @Test(
    "EffectTask.debounce latest-wins semantics hold across random timing streams",
    arguments: Array(0..<50)
  )
  func effectDebounceLatestWinsProperty(seed: Int) async {
    let steps = makeTimingScenario(seed: UInt64(seed + 101))
    let expected = expectedDebounceOutputs(for: steps, intervalMilliseconds: 60)
    let actual = await runTimingScenario(
      reducer: DebounceFeature(),
      steps: steps,
      trigger: DebounceFeature.Action.trigger,
      emitted: \.emitted,
      expectedCount: expected.count
    )

    #expect(actual == expected)
  }

  @Test(
    "EffectTask.throttle leading-only semantics hold across random timing streams",
    arguments: Array(0..<50)
  )
  func effectThrottleLeadingOnlyProperty(seed: Int) async {
    let steps = makeTimingScenario(seed: UInt64(seed + 201))
    let expected = expectedThrottleOutputs(
      for: steps,
      intervalMilliseconds: 80,
      leading: true,
      trailing: false
    )
    let actual = await runTimingScenario(
      reducer: ThrottleFeature(),
      steps: steps,
      trigger: ThrottleFeature.Action.trigger,
      emitted: \.emitted,
      expectedCount: expected.count
    )

    #expect(actual == expected)
  }

  @Test(
    "EffectTask.throttle trailing-only semantics hold across random timing streams",
    arguments: Array(0..<50)
  )
  func effectThrottleTrailingOnlyProperty(seed: Int) async {
    let steps = makeTimingScenario(seed: UInt64(seed + 301))
    let expected = expectedThrottleOutputs(
      for: steps,
      intervalMilliseconds: 80,
      leading: false,
      trailing: true
    )
    let actual = await runTimingScenario(
      reducer: ThrottleTrailingFeature(),
      steps: steps,
      trigger: ThrottleTrailingFeature.Action.trigger,
      emitted: \.emitted,
      expectedCount: expected.count
    )

    #expect(actual == expected)
  }

  @Test(
    "EffectTask.throttle leading+trailing semantics hold across random timing streams",
    arguments: Array(0..<50)
  )
  func effectThrottleLeadingTrailingProperty(seed: Int) async {
    let steps = makeTimingScenario(seed: UInt64(seed + 401))
    let expected = expectedThrottleOutputs(
      for: steps,
      intervalMilliseconds: 80,
      leading: true,
      trailing: true
    )
    let actual = await runTimingScenario(
      reducer: ThrottleLeadingTrailingFeature(),
      steps: steps,
      trigger: ThrottleLeadingTrailingFeature.Action.trigger,
      emitted: \.emitted,
      expectedCount: expected.count
    )

    #expect(actual == expected)
  }
}

private struct DelayedAsyncSequence<Element: Sendable>: AsyncSequence, Sendable {
  let values: [Element]
  let interval: Duration
  let context: EffectContext

  func makeAsyncIterator() -> Iterator {
    .init(values: values, interval: interval, context: context)
  }

  struct Iterator: AsyncIteratorProtocol, Sendable {
    let values: [Element]
    let interval: Duration
    let context: EffectContext
    var index = 0

    mutating func next() async -> Element? {
      guard index < values.count else { return nil }
      let value = values[index]
      index += 1

      do {
        try await context.sleep(for: interval)
        try await context.checkCancellation()
        return value
      } catch {
        return nil
      }
    }
  }
}

private struct AsyncSequenceConsumerFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var values: [Int] = []
  }

  enum Action: Equatable, Sendable {
    case startActions([Int])
    case startTransformed(id: UUID, values: [Int])
    case cancel(UUID)
    case value(Int)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .startActions(let values):
      return .run { context in
        DelayedAsyncSequence(
          values: values.map(Action.value),
          interval: .milliseconds(10),
          context: context
        )
      }

    case .startTransformed(let id, let values):
      let cancellationID = EffectID(id)
      return EffectTask.run(
        sequence: { context in
          DelayedAsyncSequence(
            values: values,
            interval: .milliseconds(10),
            context: context
          )
        },
        transform: { value in
          value >= 0 ? .value(value) : nil
        }
      )
      .cancellable(cancellationID, cancelInFlight: true)

    case .cancel(let id):
      return .cancel(EffectID(id))

    case .value(let value):
      state.values.append(value)
      return .none
    }
  }
}

private func waitForSleeperCount(_ clock: ManualTestClock, atLeast count: Int) async -> Bool {
  await waitUntilAsync(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
    await clock.sleeperCount >= count
  }
}
