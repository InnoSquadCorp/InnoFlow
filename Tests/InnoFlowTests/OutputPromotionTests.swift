import InnoFlow
import InnoFlowTesting
import Testing

@Suite("Output promotion")
@MainActor
struct OutputPromotionTests {
  @Test("output-free children and effect helpers compose into typed-output parents")
  func promotesChildAndEffect() async throws {
    let clock = ManualTestClock()
    let store = TestStore(reducer: PromotionParent(), clock: clock)

    await store.send(.child(.start))
    try await clock.waitForSleepers(atLeast: 1)
    await clock.advance(by: .seconds(1))
    await store.receive(.child(.finished)) { $0.child.count = 1 }
    await store.send(.notify)
    await store.receive(.done)
    await store.receiveOutput(1)
    await store.finish()
  }

  @Test("promotion preserves scoped child cancellation")
  func preservesChildCancellation() async throws {
    let clock = ManualTestClock()
    let store = TestStore(reducer: PromotionParent(), clock: clock)

    await store.send(.child(.start))
    try await clock.waitForSleepers(atLeast: 1)
    await store.send(.child(.stop))
    await clock.advance(by: .seconds(1))
    await store.finish()

    #expect(store.state.child.count == 0)
  }
}

@InnoFlow
private struct PromotionChild {
  struct State: Equatable, Sendable, DefaultInitializable {
    var count = 0
  }

  enum Action: Equatable, Sendable {
    case start, finished, stop
  }

  private static let workID = StaticEffectID("promotion-child")

  var body: some Reducer<State, Action, Never> {
    Reduce { state, action in
      switch action {
      case .start:
        return .run { send, context in
          do {
            try await context.sleep(for: .seconds(1))
            try await context.checkCancellation()
            await send(.finished)
          } catch is CancellationError {
            return
          } catch {
            return
          }
        }
        .cancellable(Self.workID)
      case .finished:
        state.count += 1
        return .none
      case .stop:
        return .cancel(Self.workID)
      }
    }
  }
}

@InnoFlow
private struct PromotionParent {
  struct State: Equatable, Sendable, DefaultInitializable {
    var child = PromotionChild.State()
  }

  enum Action: Equatable, Sendable {
    case child(PromotionChild.Action)
    case notify, done
  }

  typealias Output = Int

  var body: some Reducer<State, Action, Output> {
    CombineReducers {
      Scope(
        state: \.child,
        action: Action.childCasePath,
        reducer: PromotionChild().promoteOutput(to: Output.self)
      )
      Reduce { state, action in
        switch action {
        case .child:
          return .none
        case .notify:
          return EffectTask<Action>.send(.done).promoteOutput(to: Output.self)
        case .done:
          return Self.output(state.child.count)
        }
      }
    }
  }
}
