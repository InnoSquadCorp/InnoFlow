import InnoFlowCore
import InnoFlowTesting
import Testing

private struct OnChangeHostState: Equatable, Sendable {
  var trigger = 0
  var received: [String] = []
}
private enum OnChangeHostAction: Equatable, Sendable { case start, base, changed }

@MainActor
private func onChangeHostReducer(baseFirst: Bool) -> some Reducer<
  OnChangeHostState, OnChangeHostAction, String
> {
  Reduce<OnChangeHostState, OnChangeHostAction, String> { state, action in
    switch action {
    case .start:
      state.trigger += 1
      return .run { send, context in
        try? await context.sleep(for: .seconds(baseFirst ? 1 : 2))
        await send(.base)
      }
    case .base:
      state.received.append("base")
      return .output("base")
    case .changed:
      state.received.append("changed")
      return .output("changed")
    }
  }.onChange(of: \.trigger) { _, _ in
    .run { send, context in
      try? await context.sleep(for: .seconds(baseFirst ? 2 : 1))
      await send(.changed)
    }
  }
}

@MainActor
@Suite("OnChange concurrent host parity")
struct OnChangeHostConsistencyTests {
  @Test(arguments: [true, false])
  func effectsFollowCompletionInBothHosts(baseFirst: Bool) async throws {
    let expected = baseFirst ? ["base", "changed"] : ["changed", "base"]
    let clock = ManualTestClock()
    let store = Store(
      reducer: onChangeHostReducer(baseFirst: baseFirst), initialState: .init(),
      clock: .manual(clock))
    let dispatch = store.send(.start, capturingOutputs: .unbounded)
    var output = dispatch.outputs.makeAsyncIterator()
    try await clock.advance(by: .seconds(1), onceSleepersReach: 2)
    #expect(await output.next() == expected[0])
    try await clock.advance(by: .seconds(1), onceSleepersReach: 1)
    #expect(await output.next() == expected[1])
    await dispatch.finish()
    #expect(await output.next() == nil)
    #expect(store.state.received == expected)

    let testClock = ManualTestClock()
    let test = TestStore(
      reducer: onChangeHostReducer(baseFirst: baseFirst), initialState: .init(), clock: testClock)
    let task = await test.send(.start) { $0.trigger = 1 }
    try await testClock.advance(by: .seconds(1), onceSleepersReach: 2)
    await test.receive(baseFirst ? .base : .changed) { $0.received = [expected[0]] }
    await test.receiveOutput(expected[0])
    try await testClock.advance(by: .seconds(1), onceSleepersReach: 1)
    await test.receive(baseFirst ? .changed : .base) { $0.received = expected }
    await test.receiveOutput(expected[1])
    await task.finish()
    await test.finish()
    #expect(test.state.received == expected)
  }
}
