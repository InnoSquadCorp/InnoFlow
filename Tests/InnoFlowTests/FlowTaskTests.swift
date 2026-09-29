import Foundation
import InnoFlowCore
import InnoFlowTesting
import Testing

@Suite("FlowTask dispatch lifetime")
@MainActor
struct FlowTaskTests {
  @Test("finish waits for descendant effects and their follow-up actions")
  func finishWaitsForDescendants() async {
    let store = Store(reducer: FlowTaskFeature())

    let task = store.send(.start)
    await task.finish()

    #expect(store.state.steps == [1, 2])
    #expect(task.isCancelled == false)
  }

  @Test("cancel drops work from only the selected dispatch tree")
  func cancelIsScopedToOneDispatch() async {
    let store = Store(reducer: FlowTaskFeature())

    let cancelled = store.send(.delayed(1))
    let surviving = store.send(.delayed(2))
    cancelled.cancel()

    await cancelled.finish()
    await surviving.finish()

    #expect(cancelled.isCancelled)
    #expect(store.state.steps == [2])
  }

  @Test("synchronous actions return an already-finishable handle")
  func synchronousActionFinishes() async {
    let store = Store(reducer: FlowTaskFeature())

    let task = store.send(.append(42))
    await task.finish()

    #expect(store.state.steps == [42])
  }

  @Test("cancelling the finish caller cancels the dispatch tree")
  func finishPropagatesCallerCancellation() async {
    let clock = ManualTestClock()
    let store = Store(
      reducer: FlowTaskFeature(),
      clock: .manual(clock)
    )

    let flowTask = store.send(.delayed(1))
    try? await clock.waitForSleepers(atLeast: 1)

    let waiter = Task {
      await flowTask.finish()
    }
    await Task.yield()
    waiter.cancel()
    await waiter.value

    #expect(flowTask.isCancelled)
    await clock.advance(by: .seconds(1))
    #expect(store.state.steps.isEmpty)
  }

  @Test("cancelling an older dispatch preserves newer trailing throttle work")
  func olderCancellationPreservesNewerThrottleWork() async {
    let clock = ManualTestClock()
    let store = Store(
      reducer: FlowTaskThrottleFeature(),
      clock: .manual(clock)
    )

    let first = store.send(.request(1))
    try? await clock.waitForSleepers(atLeast: 1)

    let second = store.send(.request(2))
    for _ in 0..<200 {
      await Task.yield()
    }

    first.cancel()
    await clock.advance(by: .seconds(1))
    await first.finish()
    await second.finish()

    #expect(first.isCancelled)
    #expect(store.state.values == [2])
  }

  @Test("completed descendant cancellation scopes do not accumulate")
  func completedCancellationScopesStayBounded() async {
    let pulseCount = 256
    let store = Store(reducer: FlowTaskScopeRetentionFeature())
    let root = store.send(.start(pulseCount))

    for _ in 0..<10_000 {
      let runtime = await store.effectRuntimeMetrics
      if store.state.received == pulseCount,
        runtime.finishedRuns >= UInt64(pulseCount + 1)
      {
        break
      }
      await Task.yield()
    }

    let retained = store.effectBridge.cancellationScopeMetrics
    #expect(store.state.received == pulseCount)
    #expect(retained.liveInterpreters == 0)
    #expect(retained.liveScopes <= 2)

    root.cancel()
    await root.finish()
    #expect(store.effectBridge.cancellationScopeMetrics.liveScopes == 0)
  }
}

private struct FlowTaskThrottleFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var values: [Int] = []

    init() {}
  }

  enum Action: Equatable, Sendable {
    case request(Int)
    case commit(Int)
  }

  private let throttleID: StaticEffectID = "flow-task-throttle"

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .request(let value):
      return .send(.commit(value)).throttle(
        throttleID,
        for: .seconds(1),
        leading: false,
        trailing: true
      )

    case .commit(let value):
      state.values.append(value)
      return .none
    }
  }
}

private struct FlowTaskFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var steps: [Int] = []

    init() {}
  }

  enum Action: Equatable, Sendable {
    case start
    case firstFinished
    case append(Int)
    case delayed(Int)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start:
      return .run { send in
        await send(.firstFinished)
      }

    case .firstFinished:
      state.steps.append(1)
      return .run { send in
        await Task.yield()
        await send(.append(2))
      }

    case .append(let value):
      state.steps.append(value)
      return .none

    case .delayed(let value):
      return .run { send, context in
        do {
          try await context.sleep(for: .milliseconds(value == 1 ? 100 : 20))
          try await context.checkCancellation()
          await send(.append(value))
        } catch is CancellationError {
          return
        } catch {
          return
        }
      }
    }
  }
}

private struct FlowTaskScopeRetentionFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var received = 0

    init() {}
  }

  enum Action: Equatable, Sendable {
    case start(Int)
    case pulse(Int)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start(let count):
      return .merge(
        .run { _, context in
          do {
            try await context.sleep(for: .seconds(3_600))
          } catch {
            return
          }
        },
        .run { send in
          for index in 0..<count {
            await send(.pulse(index))
          }
        }
      )

    case .pulse:
      state.received += 1
      return .run { _, _ in
        await Task.yield()
      }
    }
  }
}
