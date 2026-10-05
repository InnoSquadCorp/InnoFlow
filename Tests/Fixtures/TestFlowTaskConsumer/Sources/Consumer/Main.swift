import InnoFlowCore
import InnoFlowTesting

private struct LifetimeParentState: Sendable { var child: ConsumerFeature.State? = .init() }

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
    store.addInvariant(
      TestStoreInvariant(
        "nonnegative", fileID: "Consumer/Main.swift", filePath: "/Consumer/Main.swift",
        line: 10, column: 3
      ) { $0.value >= 0 })
    store.addInvariant(
      "named", fileID: "Consumer/Main.swift", filePath: "/Consumer/Main.swift",
      line: 11, column: 3
    ) { $0.value >= 0 }
    let steps: [TestStoreScenarioStep<ConsumerFeature>] = [
      .send(
        .output, fileID: "Consumer/Main.swift", filePath: "/Consumer/Main.swift", line: 12,
        column: 3),
      .receive(
        .response, fileID: "Consumer/Main.swift", filePath: "/Consumer/Main.swift", line: 13,
        column: 3),
      .receiveOutput(
        1, fileID: "Consumer/Main.swift", filePath: "/Consumer/Main.swift", line: 14, column: 3),
      .finish(fileID: "Consumer/Main.swift", filePath: "/Consumer/Main.swift", line: 15, column: 3),
    ]
    requireSendable(steps)
    let parent = Reduce<LifetimeParentState, ConsumerFeature.Action, Int> { _, _ in .none }
    let actionPath = CasePath<ConsumerFeature.Action, ConsumerFeature.Action>(
      embed: { $0 }, extract: { $0 })
    _ = parent.optionalChild(
      state: \.child, action: actionPath, instanceID: { $0.value }, reducer: ConsumerFeature())
    _ = OptionalChildLifetime(
      parent: parent, state: \.child, action: actionPath, instanceID: { $0.value },
      reducer: ConsumerFeature())
    let harness = ConsumerHarness(store: store)
    let send: @MainActor (ConsumerFeature.Action) async -> TestStoreDispatch = harness.dispatch
    let task = await send(.start)
    requireSendable(task)
    await store.receive(.response) { $0.value = 1 }
    await store.receiveOutput(1)
    await task.finish(
      timeout: .seconds(1), fileID: "Consumer/Main.swift", filePath: "/Consumer/Main.swift",
      line: 30, column: 3)
    precondition(task.isFinished)

    let child = store.scope(
      state: \.value,
      action: CasePath<ConsumerFeature.Action, ConsumerFeature.Action>(
        embed: { $0 }, extract: { $0 })
    )
    let scopedTask: TestStoreDispatch = await child.send(.output)
    await store.receiveOutput(1)
    await scopedTask.finish()

    let phaseTask: TestStoreDispatch = await store.send(
      .output, tracking: \.phase, through: PhaseTransitionGraph<Int>([:])
    )
    await store.receiveOutput(1)
    await phaseTask.finish()
    await withFlowScope { scope in
      let owned = await scope.track(
        await store.send(
          .output, fileID: "Consumer/Main.swift", filePath: "/Consumer/Main.swift", line: 100,
          column: 20))
      await child.receiveOutput(
        1, fileID: "Consumer/Main.swift", filePath: "/Consumer/Main.swift", line: 101, column: 20)
      await owned.finish()
    }
    let legacy: @MainActor (ConsumerFeature.Action) async -> Void = harness.legacyVoidAdapter
    await legacy(.output)
    await store.receiveOutput(1)
    let legacyTask = await store.send(.output, file: "Legacy.swift", line: 18)
    await store.receiveOutput(1)
    await legacyTask.finish()
    let legacyScoped = await child.send(.output, file: "Legacy.swift", line: 19)
    await child.receiveOutput(
      where: { $0 == 1 }, fileID: "Consumer/Main.swift", filePath: "/Consumer/Main.swift", line: 60,
      column: 3)
    await legacyScoped.finish()
    await store.send(
      .output, tracking: \.phase, through: PhaseTransitionGraph<Int>([:]), file: "Legacy.swift",
      line: 20)
    _ = await store.receiveOutput(
      CasePath<Int, Int>(embed: { $0 }, extract: { $0 }), fileID: "Consumer/Main.swift",
      filePath: "/Consumer/Main.swift", line: 62, column: 3)
    await store.finish(file: "Legacy.swift", line: 21)
    precondition(admissionCode(.started) == 0 && admissionCode(.superseded) == 4)
  }

  static func requireSendable<T: Sendable>(_ value: T) {}

  static func admissionCode(_ value: EffectAdmission) -> Int {
    switch value {
    case .started: 0
    case .queued: 1
    case .rejected: 2
    case .cancelledBeforeStart: 3
    case .superseded: 4
    }
  }
}
