import Testing

@testable import InnoFlowCore

private actor ViewLifetimeGate {
  private var entered = false
  private var isOpen = false
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    entered = true
    for waiter in entryWaiters { waiter.resume() }
    entryWaiters.removeAll()
    if isOpen { return }
    await withCheckedContinuation { releaseWaiters.append($0) }
  }
  func waitForEntry() async {
    if entered { return }
    await withCheckedContinuation { entryWaiters.append($0) }
  }
  func release() {
    isOpen = true
    for waiter in releaseWaiters { waiter.resume() }
    releaseWaiters.removeAll()
  }
}
private struct ViewLifetimeFeature: Reducer {
  struct State: Equatable, Sendable {
    var results: [Int] = []
    var starts = 0
  }
  enum Action: Sendable {
    case start(Int)
    case result(Int)
  }
  let gates: [ViewLifetimeGate]
  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start(let id):
      state.starts += 1
      return .run { send in
        await gates[id].wait()
        await send(.result(id))
      }
    case .result(let id):
      state.results.append(id)
      return .none
    }
  }
}
@MainActor @Suite("View dispatch lifetime bridge")
struct ViewDispatchLifetimeConsistencyTests {
  @Test func disappearanceCancelsOnlyOwnedDispatch() async {
    let gates = [ViewLifetimeGate(), ViewLifetimeGate()]
    let store = Store(reducer: ViewLifetimeFeature(gates: gates), initialState: .init())
    let view = Task { await runStoreDispatchLifetime(store: store, action: .start(0)) }
    let sibling = store.send(.start(1))
    await gates[0].waitForEntry()
    await gates[1].waitForEntry()
    view.cancel()
    await gates[0].release()
    await view.value
    #expect(!sibling.isCancelled && !sibling.isFinished)
    await gates[1].release()
    await sibling.finish()
    #expect(store.state.results == [1])
  }
  @Test func replacementRejectsOldResponses() async {
    let gates = [ViewLifetimeGate(), ViewLifetimeGate()]
    let store = Store(reducer: ViewLifetimeFeature(gates: gates), initialState: .init())
    let first = Task { await runStoreDispatchLifetime(store: store, action: .start(0)) }
    await gates[0].waitForEntry()
    first.cancel()
    let second = Task { await runStoreDispatchLifetime(store: store, action: .start(1)) }
    await gates[1].waitForEntry()
    await gates[0].release()
    await first.value
    await gates[1].release()
    await second.value
    #expect(store.state.results == [1])
  }
  @Test func preCancelledTaskDoesNotReduce() async {
    let store = Store(reducer: ViewLifetimeFeature(gates: []), initialState: .init())
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      await runStoreDispatchLifetime(store: store, action: .start(0))
    }
    await task.value
    #expect(store.state.starts == 0)
  }
}
