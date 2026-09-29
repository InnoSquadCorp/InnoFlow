import InnoFlow
import InnoFlowTesting
import Testing

@InnoFlow
private struct TimedFeature {
  struct State: Equatable, Sendable, DefaultInitializable {
    var completed = 0
  }

  enum Action: Equatable, Sendable {
    case start, done, cancel
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .start:
        return .run { send, context in
          do {
            try await context.sleep(for: .seconds(1))
            try await context.checkCancellation()
            await send(.done)
          } catch {
            return
          }
        }
        .cancellable("migration-work")
      case .done:
        state.completed += 1
        return .none
      case .cancel:
        return .cancel("migration-work")
      }
    }
  }
}

@Suite("5.1.1 migration effect semantics")
@MainActor
struct V5Semantics {
  @Test("effect completion produces one follow-up action")
  func completion() async throws {
    let clock = ManualTestClock()
    let store = TestStore(reducer: TimedFeature(), clock: clock)
    await store.send(.start)
    try await clock.waitForSleepers(atLeast: 1)
    await clock.advance(by: .seconds(1))
    await store.receive(.done) { $0.completed = 1 }
    await store.finish()
    #expect(store.state.completed == 1)
  }

  @Test("effect cancellation suppresses the follow-up action")
  func cancellation() async throws {
    let clock = ManualTestClock()
    let store = TestStore(reducer: TimedFeature(), clock: clock)
    await store.send(.start)
    try await clock.waitForSleepers(atLeast: 1)
    await store.send(.cancel)
    await clock.advance(by: .seconds(1))
    await store.finish()
    #expect(store.state.completed == 0)
  }
}
