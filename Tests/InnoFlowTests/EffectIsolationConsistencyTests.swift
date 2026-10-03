import Dispatch
import Foundation
import InnoFlowCore
import InnoFlowTesting
import Testing

private struct IsolationConsistencyState: Equatable, Sendable { var values: [Int] = [] }
private enum IsolationConsistencyAction: Equatable, Sendable { case start, received(Int) }

private func verifyEffectExecutor() {
  dispatchPrecondition(condition: .notOnQueue(.main))
}


private struct IsolationSequence: AsyncSequence, Sendable {
  typealias Element = Int
  struct AsyncIterator: AsyncIteratorProtocol, Sendable {
    var value: Int? = 4
    mutating func next() async -> Int? {
      verifyEffectExecutor()
      defer { value = nil }
      return value
    }
  }
  func makeAsyncIterator() -> AsyncIterator { AsyncIterator() }
}

private func isolationConsistencyReducer()
  -> some Reducer<IsolationConsistencyState, IsolationConsistencyAction, Never>
{
  Reduce<IsolationConsistencyState, IsolationConsistencyAction, Never> { state, action in
    switch action {
    case .start:
      return .merge(
        .run { send in
          verifyEffectExecutor()
          await send(.received(1))
        },
        .perform(operation: { _ in
          verifyEffectExecutor()
          return 2
        }, success: { .received($0) }, failure: { _ in .received(-1) }),
        .run(id: EffectID("executor"), policy: .latest) { send, _ in
          verifyEffectExecutor()
          await send(.received(3))
        },
        EffectTask<Int>.run { (_: EffectContext) in
          verifyEffectExecutor()
          return IsolationSequence()
        }.map { .received($0) }
      )
    case .received(let value):
      state.values.append(value)
      return .none
    }
  }
}

@MainActor
@Suite("Explicit effect operation isolation")
struct EffectIsolationConsistencyTests {
  @Test(arguments: [false, true])
  func operationFactoriesExecuteOffMainQueue(useTestStore: Bool) async {
    if useTestStore {
      let store = TestStore(reducer: isolationConsistencyReducer(), initialState: .init())
      store.exhaustivity = .off
      await store.send(.start)
      await store.finish()
      #expect(store.state.values.sorted() == [1, 2, 3, 4])
    } else {
      let store = Store(reducer: isolationConsistencyReducer(), initialState: .init())
      await store.send(.start).finish()
      #expect(store.state.values.sorted() == [1, 2, 3, 4])
    }
  }
}
