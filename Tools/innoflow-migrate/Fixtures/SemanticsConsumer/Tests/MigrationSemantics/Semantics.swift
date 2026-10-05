import InnoFlow
import InnoFlowTesting
import Testing

@InnoFlow
private struct TypedFeature {
  struct State: Equatable, Sendable, DefaultInitializable { var count = 0 }
  enum Action: Equatable, Sendable { case increment }
  enum Output: Equatable, Sendable { case counted(Int) }
  var body: some Reducer<State, Action> {
    CombineReducers<State, Action> {
      Reduce<State, Action> { state, _ in
        state.count += 1
        return Self.output(.counted(state.count))
      }
    }
  }
}

@InnoFlow
private struct LegacyFeature {
  struct State: Equatable, Sendable, DefaultInitializable { var count = 0 }
  enum Action: Equatable, Sendable { case increment }
  enum Output: Equatable, Sendable { case unused }
  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    let message = """
      source indentation must not change
      """
    precondition(message == "source indentation must not change")
    state.count += 1
    return EffectTask<Action>.none
  }
}

@Suite("Codemod consumer semantics")
@MainActor
struct MigrationSemantics {
  @Test func typedOutputAndTerminalFinish() async {
    let store = TestStore(reducer: TypedFeature())
    await store.send(.increment) { $0.count = 1 }
    await store.receiveOutput(.counted(1))
    await store.assertNoMoreActions(file: #filePath, line: #line)
  }

  @Test func concreteLegacyEffectIsPromoted() async {
    let store = TestStore(reducer: LegacyFeature())
    await store.send(.increment) { $0.count = 1 }
    store.assertNoMoreActions()
  }
}
