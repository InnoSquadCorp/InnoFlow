import InnoFlowCore
import InnoFlowTesting

@MainActor
private protocol DispatchingHarness {
  associatedtype Action
  func dispatch(_ action: Action) async -> TestStoreDispatch
}

@MainActor
private struct ConsumerHarness<R: Reducer>: DispatchingHarness where R.State: Equatable {
  let store: TestStore<R>
  func dispatch(_ action: R.Action) async -> TestStoreDispatch { await store.send(action) }
  func legacyVoidAdapter(_ action: R.Action) async { _ = await store.send(action) }
}

@main
struct Consumer {
  @MainActor
  static func main() async {
    let store = TestStore(reducer: ConsumerFeature())
    let harness = ConsumerHarness(store: store)
    let send: @MainActor (ConsumerFeature.Action) async -> TestStoreDispatch = harness.dispatch
    let task = await send(.start)
    let compatibilityName: TestFlowTask = task
    requireSendable(compatibilityName)
    requireSendable(task)
    await store.receive(.response) { $0.value = 1 }
    await store.receiveOutput(1)
    await task.finish(timeout: .seconds(1))
    precondition(task.isFinished)

    let child = store.scope(
      state: \.value,
      action: CasePath<ConsumerFeature.Action, ConsumerFeature.Action>(
        embed: { $0 }, extract: { $0 })
    )
    let scopedTask: TestFlowTask = await child.send(.output)
    await store.receiveOutput(1)
    await scopedTask.finish()

    let phaseTask: TestStoreDispatch = await store.send(
      .output, tracking: \.phase, through: PhaseTransitionGraph<Int>([:])
    )
    await store.receiveOutput(1)
    await phaseTask.finish()
    let legacy: @MainActor (ConsumerFeature.Action) async -> Void = harness.legacyVoidAdapter
    await legacy(.output)
    await store.receiveOutput(1)
    await store.finish()
  }

  static func requireSendable<T: Sendable>(_ value: T) {}
}
