import Foundation
import InnoFlowCore
import InnoFlowTesting
import Testing

@Suite("TestStore dispatch consistency", .serialized)
@MainActor
struct TestStoreDispatchConsistencyTests {
  @Test("receiving a descendant registers follow-up work before releasing its queue lease")
  func descendantsKeepOneDispatchAlive() async {
    let store = TestStore(reducer: DispatchConsistencyFeature())
    let task = await store.send(.start(7))
    #expect(!task.isFinished)
    let firstID = store.unverifiedSnapshot().actionCount
    #expect(firstID == 1)
    await store.receive(.step(7, 1)) { $0.events = [71] }
    #expect(!task.isFinished)
    await store.receive(.step(7, 2)) { $0.events = [71, 72] }
    #expect(task.isFinished)
    await store.receiveOutput(7)
    await task.finish(timeout: .zero)
    await store.finish(timeout: .zero)
  }

  @Test("task finish is non-consuming in both exhaustivity modes", arguments: [false, true])
  func taskFinishDoesNotDrain(exhaustive: Bool) async {
    let store = TestStore(reducer: DispatchConsistencyFeature())
    store.exhaustivity = exhaustive ? .on : .off
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }
    let task = await store.send(.start(3))
    await task.finish(timeout: .zero)
    #expect(failures.count == 1)
    #expect(failures[0].contains("unhandled effect action"))
    #expect(store.state.events.isEmpty)
    #expect(!task.isCancelled)
    #expect(!task.isFinished)
    await store.receive(.step(3, 1)) { $0.events = [31] }
    await store.receive(.step(3, 2)) { $0.events = [31, 32] }
    await store.receiveOutput(3)
    await task.finish(timeout: .zero)
    #expect(failures.count == 1)
    await store.finish(timeout: .zero)
  }

  @Test("runtime-complete output remains an assertion obligation")
  func runtimeCompletionDoesNotHideOutput() async {
    let store = TestStore(reducer: DispatchConsistencyFeature())
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }
    let task = await store.send(.output(9))
    #expect(task.isFinished)
    await task.finish(timeout: .zero)
    #expect(failures.count == 1)
    #expect(failures[0].contains("1 unhandled output"))
    await store.receiveOutput(9, timeout: .zero)
    await task.finish(timeout: .zero)
    #expect(failures.count == 1)
    await store.finish(timeout: .zero)
  }

  @Test("one task's finish ignores another dispatch's unverified output")
  func finishIgnoresSiblingDispatch() async {
    let store = TestStore(reducer: DispatchConsistencyFeature())
    let first = await store.send(.output(1))
    let second = await store.send(.output(2))
    await store.receiveOutput(1, timeout: .zero)
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }
    await first.finish(timeout: .zero)
    #expect(failures.isEmpty)
    await second.finish(timeout: .zero)
    #expect(failures.count == 1)
    await store.receiveOutput(2, timeout: .zero)
    await store.finish(timeout: .zero)
  }

  @Test("cancellation suppresses queued descendants without cancelling a sibling")
  func selectiveCancellation() async throws {
    let firstGate = DispatchConsistencyGate()
    let secondGate = DispatchConsistencyGate()
    let store = TestStore(
      reducer: DispatchConsistencyFeature(gates: [1: firstGate, 2: secondGate]))
    let first = await store.send(.wait(1))
    let firstRun = try #require(store.runningTasks.values.first?.task)
    let second = await store.send(.wait(2))
    let allRuns = store.runningTasks.values.map(\.task)
    await firstGate.open()
    _ = await firstRun.result
    #expect(store.unverifiedSnapshot().actionCount == 1)
    first.cancel()
    await secondGate.open()
    for run in allRuns { _ = await run.result }
    await store.receive(.step(2, 2)) { $0.events = [22] }
    await store.receiveOutput(2)
    await first.finish()
    await second.finish()
    #expect(first.isCancelled)
    #expect(!second.isCancelled)
    #expect(first.isFinished)
    #expect(store.state.events == [22])
    await store.finish()
  }

  @Test("cancelled noncooperative work remains physically unfinished until its gate opens")
  func physicalCompletionAfterCancellation() async throws {
    let gate = DispatchConsistencyGate()
    let started = AsyncStream<Void>.makeStream()
    let store = TestStore(
      reducer: DispatchConsistencyFeature(gates: [1: gate], started: started.continuation))
    let task = await store.send(.wait(1))
    let run = try #require(store.runningTasks.values.first?.task)
    var starts = started.stream.makeAsyncIterator()
    _ = await starts.next()
    task.cancel()
    #expect(task.isCancelled)
    #expect(!task.isFinished)
    await gate.open()
    _ = await run.result
    await task.finish()
    #expect(task.isFinished)
    #expect(store.unverifiedSnapshot().isEmpty)
    #expect(store.state.events.isEmpty)
    await store.finish()
  }

  @Test("timeout cancels only the selected dispatch and does not fake completion")
  func taskTimeoutIsSelective() async throws {
    let gate = DispatchConsistencyGate()
    let started = AsyncStream<Void>.makeStream()
    let store = TestStore(
      reducer: DispatchConsistencyFeature(gates: [1: gate], started: started.continuation))
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }
    let task = await store.send(.wait(1))
    let run = try #require(store.runningTasks.values.first?.task)
    var starts = started.stream.makeAsyncIterator()
    _ = await starts.next()
    let sibling = await store.send(.output(8))
    await task.finish(timeout: .zero)
    #expect(task.isCancelled)
    #expect(!task.isFinished)
    #expect(!sibling.isCancelled)
    #expect(failures.count == 1)
    #expect(failures[0].contains("Timed out"))
    await store.receiveOutput(8)
    await gate.open()
    _ = await run.result
    await task.finish()
    await sibling.finish()
    await store.finish()
  }

  @Test("caller cancellation cleans task finish waiters and suppresses false timeout")
  func callerCancellation() async throws {
    let gate = DispatchConsistencyGate()
    let started = AsyncStream<Void>.makeStream()
    let waiting = AsyncStream<Void>.makeStream()
    let store = TestStore(
      reducer: DispatchConsistencyFeature(gates: [1: gate], started: started.continuation))
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }
    let task = await store.send(.wait(1))
    let run = try #require(store.runningTasks.values.first?.task)
    var starts = started.stream.makeAsyncIterator()
    _ = await starts.next()
    store.finishActivity.waitTimeoutObserver = { _ in waiting.continuation.yield(()) }
    let finishing = Task { await task.finish(timeout: .seconds(60)) }
    var waits = waiting.stream.makeAsyncIterator()
    _ = await waits.next()
    finishing.cancel()
    await finishing.value
    #expect(task.isCancelled)
    #expect(!task.isFinished)
    #expect(failures.isEmpty)
    #expect(store.finishActivity.pendingWaiterCount == 0)
    await gate.open()
    _ = await run.result
    await task.finish()
    await store.finish()
  }

  @Test("handles and a pending finish do not retain their test store")
  func storeReleaseWithStaleHandle() async throws {
    let gate = DispatchConsistencyGate()
    let started = AsyncStream<Void>.makeStream()
    let waiting = AsyncStream<Void>.makeStream()
    var store: TestStore<DispatchConsistencyFeature>? = TestStore(
      reducer: DispatchConsistencyFeature(gates: [1: gate], started: started.continuation)
    )
    store?.exhaustivity = .off
    weak var weakStore = store
    let task = await store!.send(.wait(1))
    let run = try #require(store?.runningTasks.values.first?.task)
    var starts = started.stream.makeAsyncIterator()
    _ = await starts.next()
    store?.finishActivity.waitTimeoutObserver = { _ in waiting.continuation.yield(()) }
    let finishing = Task { await task.finish(timeout: .seconds(60)) }
    var waits = waiting.stream.makeAsyncIterator()
    _ = await waits.next()
    store = nil
    #expect(weakStore == nil)
    weakStore = nil
    #expect(!task.isFinished)
    // Store teardown cancels the physical operation but cannot force its gate.
    await gate.open()
    _ = await run.result
    await finishing.value
    #expect(task.isFinished)
    await task.finish(timeout: .zero)
  }

  @Test(
    "non-exhaustive output reception advances the complete FIFO action chain",
    arguments: [false, true])
  func outputAdvancesActions(showWarnings: Bool) async {
    let store = TestStore(reducer: DispatchConsistencyFeature())
    store.exhaustivity = .off(showSkippedAssertions: showWarnings)
    var warnings: [String] = []
    store.skippedAssertionReporter = { message, _, _ in warnings.append(message) }
    let task = await store.send(.start(4))
    await store.receiveOutput(4)
    #expect(store.state.events == [41, 42])
    #expect(warnings.count == (showWarnings ? 2 : 0))
    await task.finish(timeout: .zero)
    await store.finish(timeout: .zero)
  }

  @Test("exhaustive output reception never silently reduces a queued action")
  func exhaustiveOutputDoesNotAdvance() async {
    let store = TestStore(reducer: DispatchConsistencyFeature())
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }
    let task = await store.send(.start(5))
    await store.receiveOutput(5, timeout: .zero)
    #expect(failures.count == 1)
    #expect(store.state.events.isEmpty)
    await store.receive(.step(5, 1)) { $0.events = [51] }
    await store.receive(.step(5, 2)) { $0.events = [51, 52] }
    await store.receiveOutput(5)
    await task.finish(timeout: .zero)
    await store.finish(timeout: .zero)
  }

  @Test("a ready output wins over a simultaneously buffered action without losing either")
  func outputPriorityPreservesAction() async {
    let store = TestStore(reducer: DispatchConsistencyFeature())
    store.exhaustivity = .off
    store.deliverAction(.step(8, 2), context: nil)
    store.deliverOutput(7, context: nil)
    await store.receiveOutput(7, timeout: .zero)
    #expect(store.state.events.isEmpty)
    #expect(store.unverifiedSnapshot().actionCount == 1)
    await store.receiveOutput(8)
    #expect(store.state.events == [82])
    await store.finish(timeout: .zero)
  }

  @Test("the shared non-consuming output wakeup cannot lose the action or output side")
  func outputWaitObservesBothQueues() async {
    let store = TestStore(reducer: DispatchConsistencyFeature())
    store.exhaustivity = .off
    let waiting = AsyncStream<Void>.makeStream()
    store.finishActivity.waitTimeoutObserver = { _ in waiting.continuation.yield(()) }
    let receiving = Task { await store.receiveOutput(6) }
    var waits = waiting.stream.makeAsyncIterator()
    _ = await waits.next()
    store.deliverAction(.step(7, 2), context: nil)
    store.deliverOutput(6, context: nil)
    await receiving.value
    #expect(store.state.events.isEmpty)
    #expect(store.finishActivity.pendingWaiterCount == 0)
    await store.receiveOutput(7)
    await store.finish()
  }

  @Test("cancelling an output wait removes only the shared waiter")
  func outputWaitCancellation() async {
    let store = TestStore(reducer: DispatchConsistencyFeature())
    store.exhaustivity = .off
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }
    let waiting = AsyncStream<Void>.makeStream()
    store.finishActivity.waitTimeoutObserver = { _ in waiting.continuation.yield(()) }
    let receiving = Task { await store.receiveOutput(6, timeout: .seconds(60)) }
    var waits = waiting.stream.makeAsyncIterator()
    _ = await waits.next()
    receiving.cancel()
    await receiving.value
    #expect(failures.isEmpty)
    #expect(store.finishActivity.pendingWaiterCount == 0)
    store.deliverOutput(6, context: nil)
    await store.receiveOutput(6, timeout: .zero)
    await store.finish()
  }

  @Test("zero output budget permits one intermediate action and preserves its produced value")
  func outputDeadlineDoesNotReset() async {
    let store = TestStore(reducer: DispatchConsistencyFeature())
    store.exhaustivity = .off
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }
    store.deliverAction(.step(2, 2), context: nil)
    await store.receiveOutput(2, timeout: .zero)
    #expect(failures.count == 1)
    #expect(store.state.events == [22])
    #expect(store.unverifiedSnapshot().outputCount == 1)
    await store.receiveOutput(2, timeout: .zero)
    await store.finish(timeout: .zero)
  }

  @Test("non-exhaustive output reception follows an asynchronous descendant effect")
  func outputFollowsAsynchronousDescendant() async throws {
    let gate = DispatchConsistencyGate()
    let waiting = AsyncStream<Void>.makeStream()
    let store = TestStore(reducer: DispatchConsistencyFeature(gates: [4: gate]))
    store.exhaustivity = .off
    let task = await store.send(.chain(4))
    store.finishActivity.waitTimeoutObserver = { _ in waiting.continuation.yield(()) }
    let receiving = Task { await store.receiveOutput(4) }
    var waits = waiting.stream.makeAsyncIterator()
    _ = await waits.next()
    #expect(store.unverifiedSnapshot().isEmpty)
    #expect(!task.isFinished)
    await gate.open()
    await receiving.value
    #expect(store.state.events == [42])
    await task.finish()
    await store.finish()
  }

  @Test("skipped outputs and shared wakeups consume one remaining budget")
  func outputWaitBudgetsOnlyDecrease() async {
    let store = TestStore(reducer: DispatchConsistencyFeature())
    store.exhaustivity = .off
    let waiting = AsyncStream<Void>.makeStream()
    var budgets: [Duration] = []
    store.finishActivity.waitTimeoutObserver = {
      budgets.append($0)
      waiting.continuation.yield(())
    }
    let receiving = Task { await store.receiveOutput(9, timeout: .seconds(10)) }
    var waits = waiting.stream.makeAsyncIterator()
    _ = await waits.next()
    store.deliverOutput(1, context: nil)
    _ = await waits.next()
    store.deliverAction(.step(2, 2), context: nil)
    _ = await waits.next()
    store.deliverOutput(9, context: nil)
    await receiving.value
    #expect(budgets.count == 3)
    #expect(budgets.allSatisfy { $0 <= .seconds(10) })
    #expect(zip(budgets, budgets.dropFirst()).allSatisfy { $1 <= $0 })
    #expect(store.finishActivity.pendingWaiterCount == 0)
    await store.finish()
  }

  @Test("dispatch lease and waiter registrations return to baseline over repeated chains")
  func repeatedDispatchesReleaseRegistrations() async {
    let store = TestStore(reducer: DispatchConsistencyFeature())
    store.exhaustivity = .off
    for value in 0..<1_000 {
      let task = await store.send(.start(value))
      await store.receiveOutput(value)
      await task.finish(timeout: .zero)
      #expect(task.isFinished)
    }
    await store.finish()
    #expect(store.runningTasks.isEmpty)
    #expect(store.cancelledTaskTokens.isEmpty)
    #expect(store.finishActivity.pendingWaiterCount == 0)
    #expect(store.finishActivity.snapshot.activeCount == 0)
    #expect(store.cancellationScopeMetrics.liveScopes == 0)
    #expect(store.cancellationScopeMetrics.liveInterpreters == 0)
    #expect(store.unverifiedSnapshot().isEmpty)
  }

  @Test(
    "terminal verification snapshots both queue types with exact counts", arguments: [0, 1], [0, 1])
  func combinedTerminalSnapshot(actionCount: Int, outputCount: Int) async {
    let store = TestStore(reducer: DispatchConsistencyFeature())
    if actionCount > 0 { store.deliverAction(.step(1, 2), context: nil) }
    if outputCount > 0 { store.deliverOutput(1, context: nil) }
    let result = await store.finishResult(timeout: .zero)
    if actionCount + outputCount == 0 {
      #expect(result == .success)
    } else if case .unhandledWork(let pending) = result {
      #expect(pending.actionCount == actionCount)
      #expect(pending.outputCount == outputCount)
    } else {
      Issue.record("Expected a combined terminal snapshot")
    }
    #expect(store.makeTerminalVerificationDiagnostic() == nil)
    #expect(store.unverifiedSnapshot().isEmpty)
  }

  @Test("terminal value previews are bounded, new work reopens verification")
  func boundedTerminalSnapshotAndRevision() async {
    let store = TestStore(reducer: DispatchConsistencyFeature())
    for value in 0..<100 {
      store.deliverAction(.step(value, 2), context: nil)
      store.deliverOutput(value, context: nil)
    }
    guard case .unhandledWork(let pending) = await store.finishResult(timeout: .zero) else {
      Issue.record("Expected terminal work")
      return
    }
    #expect(pending.actionCount == 100)
    #expect(pending.outputCount == 100)
    #expect(pending.actions.count == 20)
    #expect(pending.outputs.count == 20)
    #expect(store.makeTerminalVerificationDiagnostic() == nil)
    store.deliverOutput(200, context: nil)
    #expect(store.makeTerminalVerificationDiagnostic() != nil)
    await store.receiveOutput(200, timeout: .zero)
    await store.finish(timeout: .zero)
  }

  @Test("scoped sends return the root dispatch and scoped receive preserves descendants")
  func scopedDispatch() async {
    let store = TestStore(reducer: DispatchConsistencyFeature())
    let scoped = store.scope(
      state: \.events, action: DispatchConsistencyFeature.Action.identityPath)
    let task: TestFlowTask = await scoped.send(.start(6))
    await scoped.receive(.step(6, 1)) { $0 = [61] }
    #expect(!task.isFinished)
    await scoped.receive(.step(6, 2)) { $0 = [61, 62] }
    let output = await scoped.receiveOutput(CasePath<Int, Int>(embed: { $0 }, extract: { $0 }))
    #expect(output == 6)
    await task.finish(timeout: .zero)
    await store.finish(timeout: .zero)
  }

  @Test("phase helpers return the original dispatch handle")
  func phaseSendHandle() async {
    let store = TestStore(reducer: DispatchConsistencyFeature())
    let graph = PhaseTransitionGraph<Int>([:])
    let task: TestStoreDispatch = await store.send(.start(2), tracking: \.phase, through: graph)
    store.exhaustivity = .off
    await store.receiveOutput(2)
    await task.finish(timeout: .zero)
    await store.finish(timeout: .zero)
  }

  @Test("FlowScope can own a testing dispatch without a Core-to-Testing dependency")
  func flowScopeAdapter() async throws {
    let gate = DispatchConsistencyGate()
    let store = TestStore(reducer: DispatchConsistencyFeature(gates: [1: gate]))
    try await withFlowScope { scope in
      let task = await scope.track(await store.send(.wait(1)))
      let run = try #require(store.runningTasks.values.first?.task)
      task.cancel()
      await gate.open()
      _ = await run.result
      await scope.cancelAndFinish()
      await task.finish()
    }
    await store.finish()
  }
}

private actor DispatchConsistencyGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func open() {
    isOpen = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
}

private struct DispatchConsistencyFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var events: [Int] = []
    var phase = 0
  }
  enum Action: Equatable, Sendable {
    case start(Int)
    case step(Int, Int)
    case output(Int)
    case wait(Int)
    case chain(Int)
    static let identityPath = CasePath<Action, Action>(embed: { $0 }, extract: { $0 })
  }
  typealias Output = Int
  var gates: [Int: DispatchConsistencyGate] = [:]
  var started: AsyncStream<Void>.Continuation?
  func reduce(into state: inout State, action: Action) -> ReducerEffect<Action, Output> {
    switch action {
    case .start(let value):
      return .send(.step(value, 1))
    case .step(let value, let step):
      state.events.append(value * 10 + step)
      if step == 1 { return .send(.step(value, 2)) }
      return Self.output(value)
    case .output(let value):
      return Self.output(value)
    case .chain(let value):
      return .send(.wait(value))
    case .wait(let value):
      let gate = gates[value]
      let started = started
      return .run { send in
        started?.yield(())
        await gate?.wait()
        await send(.step(value, 2))
      }
    }
  }
}
