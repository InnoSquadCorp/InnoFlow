import InnoFlowCore
import InnoFlowTesting
import Testing

private actor PriorityGate {
  private var open = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if open { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func release() {
    open = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
}
private struct PriorityFailure: Error, CustomStringConvertible {
  var description: String { "first diagnostic must survive" }
}
private struct PriorityReducer: Reducer {
  struct State: Sendable, Equatable { var step = 0 }
  enum Action: Sendable, Equatable { case start, started }
  let gate: PriorityGate
  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start:
      state.step = 1
      return .run { send, context in
        await send(.started)
        await gate.wait()
        await context.reportError(PriorityFailure())
      }
    case .started:
      state.step = 2
      return .none
    }
  }
}
private struct IdleCleanupReducer: Reducer {
  struct State: Sendable, Equatable {}
  enum Action: Sendable, Equatable { case noop }
  func reduce(into state: inout State, action: Action) -> EffectTask<Action> { .none }
}
@MainActor
@Suite("Explorer first-diagnostic and cancelled cleanup")
struct ExplorerFirstDiagnosticConsistencyTests {
  @Test("a later clock timeout does not erase the runtime diagnostic already observed")
  func firstDiagnosticSurvivesClockTimeout() async {
    var currentGate: PriorityGate?
    var store: TestStore<PriorityReducer>?
    var sawRuntimeDiagnostic = false
    let explorer = TestStoreExplorer(
      seed: 1,
      makeStore: {
        let gate = PriorityGate()
        currentGate = gate
        let fresh = TestStore(
          reducer: PriorityReducer(gate: gate), initialState: .init(),
          clock: ManualTestClock(), effectTimeout: .seconds(1))
        store = fresh
        return fresh
      },
      choices: { state in
        switch state.step {
        case 0: return [.send(.start, source: ".start")]
        case 1: return [.receive(.started, source: ".started")]
        default:
          // Instrument only reporting; preserve the explorer's original callback.
          // The gate opens after this synchronous generator yields to the clock
          // interaction, so the effect reports while registration is pending.
          if let store {
            let original = store.issueReporter
            store.issueReporter = { message, location in
              if message.contains("first diagnostic must survive") { sawRuntimeDiagnostic = true }
              original(message, location)
            }
          }
          if let gate = currentGate { Task { await gate.release() } }
          return [.advance(by: .seconds(1), onceSleepersReach: 1)]
        }
      })
    let result = await explorer.run(maxSteps: 3, minimize: false)
    #expect(
      sawRuntimeDiagnostic, "Probe setup must observe the runtime diagnostic before classification")
    #expect(result.failure?.kind == .diagnostic)
    #expect(result.failure?.message.contains("first diagnostic must survive") == true)
    #expect(result.failure?.sourceLocation != nil)
    #expect(result.cleanupCompleted)
  }

  @Test("a pre-cancelled no-effect run has physically completed cleanup")
  func cancelledIdleStoreHasCompleteCleanup() async {
    let explorer = TestStoreExplorer(
      seed: 1,
      makeStore: {
        TestStore(reducer: IdleCleanupReducer(), initialState: .init())
      }, choices: { _ in [.send(.noop, source: ".noop")] })
    let run = Task { @MainActor in await explorer.run() }
    run.cancel()
    let result = await run.value
    #expect(result.wasCancelled)
    #expect(result.steps.isEmpty)
    #expect(result.failure == nil)
    #expect(result.cleanupCompleted)
    #expect(!result.replayValidated)
  }
}

extension ExplorerFirstDiagnosticConsistencyTests {
  @Test("an advance with no registration wait does not race a zero timeout")
  func immediateClockAdvanceHasNoRegistrationTimeout() async {
    let clock = ManualTestClock()
    let initial = await clock.now
    let explorer = TestStoreExplorer(
      seed: 1,
      makeStore: {
        TestStore(
          reducer: IdleCleanupReducer(), initialState: .init(),
          clock: clock, effectTimeout: .zero)
      }, choices: { _ in [.advance(by: .seconds(1), onceSleepersReach: 0)] })
    let result = await explorer.run(maxSteps: 1, minimize: false)
    #expect(result.failure == nil)
    #expect(result.cleanupCompleted)
    #expect(await clock.now == initial.advanced(by: .seconds(1)))
  }
}

extension ExplorerFirstDiagnosticConsistencyTests {
  @Test("an already registered positive threshold wins over a zero timeout")
  func registeredClockAdvanceHasNoRegistrationTimeout() async throws {
    let clock = ManualTestClock()
    let initial = await clock.now
    let sleeper = Task { try await clock.sleep(for: .seconds(1)) }
    try await clock.waitForSleepers(atLeast: 1)
    let explorer = TestStoreExplorer(
      seed: 1,
      makeStore: {
        TestStore(
          reducer: IdleCleanupReducer(), initialState: .init(),
          clock: clock, effectTimeout: .zero)
      }, choices: { _ in [.advance(by: .seconds(1), onceSleepersReach: 1)] })
    let result = await explorer.run(maxSteps: 1, minimize: false)
    // Always release the fixture even when a defective implementation times
    // out before advancing; failure evidence must not leave a parked sleeper.
    sleeper.cancel()
    _ = try? await sleeper.value
    #expect(result.failure == nil)
    #expect(result.cleanupCompleted)
    #expect(await clock.now == initial.advanced(by: .seconds(1)))
    #expect(await clock.sleeperCount == 0)
  }
}
