import InnoFlowCore
import InnoFlowTesting
import Testing

private struct ExplorerClockSafety: Reducer {
  struct State: Equatable, Sendable { var count = 0 }
  enum Action: Equatable, Sendable { case noop }
  func reduce(into state: inout State, action: Action) -> EffectTask<Action> { .none }
}
private actor ExplorerCleanupGate {
  private var opened = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var finished = false
  private var finishWaiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if opened { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func release() {
    opened = true
    for waiter in waiters { waiter.resume() }
    waiters.removeAll()
  }
  func markFinished() {
    finished = true
    for waiter in finishWaiters { waiter.resume() }
    finishWaiters.removeAll()
  }
  func waitUntilFinished() async {
    if finished { return }
    await withCheckedContinuation { finishWaiters.append($0) }
  }
}
private struct ExplorerUncooperative: Reducer {
  struct State: Equatable, Sendable { var step = 0 }
  enum Action: Equatable, Sendable { case start, started, ended }
  let gate: ExplorerCleanupGate
  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start:
      state.step = 1
      return .run { send in
        await send(.started)
        await gate.wait()
        await send(.ended)
        await gate.markFinished()
      }
    case .started:
      state.step = 2
      return .none
    case .ended:
      state.step = 3
      return .none
    }
  }
}
@MainActor @Suite("Explorer replay safety")
struct ExplorerSafetyConsistencyTests {
  @Test func missingClockIsConfigurationFailure() async {
    var factories = 0
    let explorer = TestStoreExplorer(
      seed: 1,
      makeStore: {
        factories += 1
        return TestStore(reducer: ExplorerClockSafety(), initialState: .init())
      },
      choices: { _ in [.advance(by: .seconds(1), onceSleepersReach: 0)] })
    let result = await explorer.run(maxSteps: 1)
    #expect(result.failure?.kind == .configuration)
    #expect(!result.replayValidated && factories == 1)
    #expect(result.cleanupCompleted)
  }
  @Test func invalidAdvanceDoesNotBecomeReducerReproduction() async {
    let explorer = TestStoreExplorer(
      seed: 1,
      makeStore: {
        TestStore(reducer: ExplorerClockSafety(), initialState: .init(), clock: ManualTestClock())
      },
      choices: { _ in [.advance(by: .seconds(-1), onceSleepersReach: 0)] })
    let result = await explorer.run(maxSteps: 1)
    #expect(result.failure?.kind == .configuration && !result.replayValidated)
  }
  @Test func incompletePhysicalCleanupStopsFurtherReplays() async {
    let gate = ExplorerCleanupGate()
    var factories = 0
    let explorer = TestStoreExplorer<ExplorerUncooperative>(
      seed: 1,
      makeStore: {
        factories += 1
        let store = TestStore(
          reducer: ExplorerUncooperative(gate: gate), initialState: .init(),
          // The receive barrier and cleanup share this budget. Ten milliseconds
          // can cancel before physical work starts under parallel test load.
          effectTimeout: .seconds(1))
        store.addInvariant("stop at started") { $0.step != 2 }
        return store
      },
      choices: { state in
        state.step == 0
          ? [.send(.start, source: ".start")] : [.receive(.started, source: ".started")]
      })
    let result = await explorer.run(maxSteps: 2)
    #expect(result.failure?.kind == .diagnostic)
    #expect(result.failure?.message.contains("stop at started") == true)
    #expect(!result.cleanupCompleted && !result.replayValidated)
    #expect(factories == 1)
    await gate.release()
    await gate.waitUntilFinished()
  }
}
