import Foundation
import InnoFlowCore
import InnoFlowTesting
import Testing
import os

@Suite("TestStore invariants")
@MainActor
struct TestStoreInvariantTests {
  @Test("direct send and received effect actions each check once")
  func sendAndReceiveCheckExactlyOnce() async {
    let count = OSAllocatedUnfairLock<Int>(initialState: 0)
    let store = TestStore(reducer: InvariantFeature())
    store.addInvariant("count is non-negative") { state in
      count.withLock { $0 += 1 }
      return state.count >= 0
    }

    await store.send(.start)
    #expect(count.withLock { $0 } == 1)
    await store.receive(.increment) {
      $0.count = 1
    }
    #expect(count.withLock { $0 } == 2)
    await store.finish()
  }

  @Test("scoped send and receive use the same invariant boundary")
  func scopedPathsCheckExactlyOnce() async {
    let count = OSAllocatedUnfairLock<Int>(initialState: 0)
    let store = TestStore(reducer: InvariantParentFeature())
    store.addInvariant("child is non-negative") { state in
      count.withLock { $0 += 1 }
      return state.child.count >= 0
    }
    let child = store.scope(
      state: \InvariantParentFeature.State.child,
      action: InvariantParentFeature.childPath
    )

    await child.send(.increment) {
      $0.count = 1
    }
    #expect(count.withLock { $0 } == 1)

    await store.send(.startChildEffect)
    #expect(count.withLock { $0 } == 2)
    await child.receive(.increment) {
      $0.count = 2
    }
    #expect(count.withLock { $0 } == 3)
    await store.finish()
  }

  @Test("automatic non-exhaustive draining still checks invariants")
  func automaticDrainChecksInvariant() async {
    let count = OSAllocatedUnfairLock<Int>(initialState: 0)
    let store = TestStore(reducer: InvariantFeature())
    store.exhaustivity = .off(showSkippedAssertions: false)
    store.addInvariant("count is non-negative") { state in
      count.withLock { $0 += 1 }
      return state.count >= 0
    }

    await store.send(.start)
    await store.send(.noop)

    #expect(store.state.count == 1)
    #expect(count.withLock { $0 } == 3)
    await store.finish()
  }

  @Test("failure identifies invariant, action, source, and bounded change")
  func failureMessageIsActionable() async {
    let messages = OSAllocatedUnfairLock<[String]>(initialState: [])
    let store = TestStore(reducer: InvariantFeature(), diffLineLimit: 4)
    store.assertionFailureReporter = { message, _, _ in
      messages.withLock { $0.append(message) }
    }
    store.addInvariant("count is non-negative") { $0.count >= 0 }

    await store.send(.set(-1)) {
      $0.count = -1
    }

    let message = messages.withLock { $0.first ?? "" }
    #expect(message.contains("count is non-negative"))
    #expect(message.contains("Reduction source: send"))
    #expect(message.contains("set(-1)"))
    #expect(message.contains("Final state"))
    await store.finish()
  }
}

@Suite("TestStore scenarios")
@MainActor
struct TestStoreScenarioTests {
  @Test("same seed and typed steps reproduce the same semantic result")
  func scenarioIsReproducible() async {
    let firstClock = ManualTestClock()
    let secondClock = ManualTestClock()
    let firstStore = TestStore(reducer: ScenarioFeature(), clock: firstClock)
    let secondStore = TestStore(reducer: ScenarioFeature(), clock: secondClock)

    let firstResult = await makeScenario(clock: firstClock).run(on: firstStore)
    let secondResult = await makeScenario(clock: secondClock).run(on: secondStore)

    #expect(firstResult == secondResult)
    #expect(firstResult.seed == 0x600)
    #expect(firstResult.completedStepCount == 4)
    #expect(firstStore.state == secondStore.state)
    #expect(firstStore.state.value == 42)
  }

  @Test("scenario prefixes invariant failures with the exact step")
  func scenarioFailureCarriesStep() async {
    let messages = OSAllocatedUnfairLock<[String]>(initialState: [])
    let store = TestStore(reducer: InvariantFeature())
    store.assertionFailureReporter = { message, _, _ in
      messages.withLock { $0.append(message) }
    }
    store.addInvariant("non-negative") { $0.count >= 0 }
    let scenario = TestStoreScenario<InvariantFeature>(
      steps: [
        .send(.set(-1), label: "make invalid") { $0.count = -1 }
      ]
    )

    _ = await scenario.run(on: store)

    let message = messages.withLock { $0.first ?? "" }
    #expect(message.contains("Scenario step 1/1: make invalid"))
    #expect(message.contains("TestStore invariant failed: non-negative"))
    await store.finish()
  }

  @Test("cancelling a blocked advance stops the scenario without running later steps")
  func cancelledAdvanceStopsScenario() async {
    let clock = ManualTestClock()
    let store = TestStore(reducer: InvariantFeature(), clock: clock)
    let scenario = TestStoreScenario<InvariantFeature>(
      steps: [
        .advance(
          clock,
          by: .seconds(1),
          onceSleepersReach: 1,
          label: "wait for missing sleeper"
        ),
        .send(.set(99), label: "must not run") { $0.count = 99 },
        .finish(),
      ]
    )

    let runner = Task { @MainActor in
      await scenario.run(on: store)
    }
    await Task.yield()
    runner.cancel()
    let result = await runner.value

    #expect(result.wasCancelled)
    #expect(result.completedStepCount == 0)
    #expect(result.cancelledStepIndex == 0)
    #expect(result.cancelledStepLabel == "wait for missing sleeper")
    #expect(store.state.count == 0)
    await store.finish()
  }

  private func makeScenario(clock: ManualTestClock) -> TestStoreScenario<ScenarioFeature> {
    TestStoreScenario(
      seed: 0x600,
      steps: [
        .send(.start),
        .advance(clock, by: .seconds(1), onceSleepersReach: 1),
        .receive(.finished(42)) { $0.value = 42 },
        .finish(),
      ]
    )
  }
}

private struct InvariantFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var count = 0
    init() {}
  }
  enum Action: Equatable, Sendable {
    case start
    case increment
    case set(Int)
    case noop
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start:
      return .send(.increment)
    case .increment:
      state.count += 1
      return .none
    case .set(let value):
      state.count = value
      return .none
    case .noop:
      return .none
    }
  }
}

private struct InvariantChildState: Equatable, Sendable {
  var count = 0
}

private enum InvariantChildAction: Equatable, Sendable {
  case increment
}

private struct InvariantParentFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var child = InvariantChildState()
    init() {}
  }
  enum Action: Equatable, Sendable {
    case child(InvariantChildAction)
    case startChildEffect
  }

  static let childPath = CasePath<Action, InvariantChildAction>(
    embed: Action.child,
    extract: {
      guard case .child(let action) = $0 else { return nil }
      return action
    }
  )

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .child(.increment):
      state.child.count += 1
      return .none
    case .startChildEffect:
      return .send(.child(.increment))
    }
  }
}

private struct ScenarioFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var value = 0
    init() {}
  }
  enum Action: Equatable, Sendable {
    case start
    case finished(Int)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start:
      return .run { send, context in
        do {
          try await context.sleep(for: .seconds(1))
          await send(.finished(42))
        } catch {
          return
        }
      }
    case .finished(let value):
      state.value = value
      return .none
    }
  }
}
