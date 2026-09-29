import Foundation
import Testing

@testable import InnoFlowCore

@Suite("FlowScope lifetime")
@MainActor
struct FlowScopeTests {
  @Test("normal scope exit cancels and joins unfinished dispatches")
  func normalExitCancelsUnfinishedWork() async {
    let probe = CancellationAwareSleepProbe()
    let store = Store(reducer: FlowScopeFeature(probes: [1: probe]))
    var handle: FlowTask?

    await withFlowScope { scope in
      handle = await scope.track(store.send(.start(1)))
      #expect(await probe.started.wait())
    }

    #expect(await probe.cancelled.wait())
    #expect(handle?.isCancelled == true)
    #expect(handle?.isFinished == true)
    #expect(store.state.completed.isEmpty)
  }

  @Test("throwing scope exit performs the same cleanup")
  func throwingExitCancelsUnfinishedWork() async {
    enum Expected: Error { case stop }
    let probe = CancellationAwareSleepProbe()
    let store = Store(reducer: FlowScopeFeature(probes: [1: probe]))

    await #expect(throws: Expected.self) {
      try await withFlowScope { scope in
        _ = await scope.track(store.send(.start(1)))
        #expect(await probe.started.wait())
        throw Expected.stop
      }
    }

    #expect(await probe.cancelled.wait())
    #expect(store.state.completed.isEmpty)
  }

  @Test("caller cancellation closes the scope and joins owned dispatches")
  func callerCancellationClosesScope() async {
    let probe = CancellationAwareSleepProbe()
    let store = Store(reducer: FlowScopeFeature(probes: [1: probe]))
    var handle: FlowTask?
    let caller = Task { @MainActor in
      await withFlowScope { scope in
        handle = await scope.track(store.send(.start(1)))
        try? await Task.sleep(for: .seconds(60))
      }
    }

    #expect(await probe.started.wait())
    caller.cancel()
    await caller.value

    #expect(await probe.cancelled.wait())
    #expect(handle?.isCancelled == true)
    #expect(handle?.isFinished == true)
    #expect(store.state.completed.isEmpty)
  }

  @Test("caller cancellation reaches owned work before an unrelated body wait returns")
  func callerCancellationDoesNotWaitForBodyReturn() async {
    let probe = CancellationAwareSleepProbe()
    let bodyGate = RunStartGate()
    let bodyWaiting = AsyncTestSignal()
    let store = Store(reducer: FlowScopeFeature(probes: [1: probe]))
    var handle: FlowTask?
    let caller = Task { @MainActor in
      await withFlowScope { scope in
        handle = await scope.track(store.send(.start(1)))
        bodyWaiting.signal()
        await bodyGate.wait()
      }
    }

    #expect(await bodyWaiting.wait())
    #expect(await probe.started.wait())
    caller.cancel()

    #expect(await probe.cancelled.wait())
    #expect(await waitUntil { handle?.isFinished == true })
    #expect(handle?.isCancelled == true)

    await bodyGate.open()
    await caller.value
    #expect(store.state.completed.isEmpty)
  }

  @Test("a scope entered from an already-cancelled caller still cleans up owned work")
  func preCancelledCallerStillCleansUp() async {
    let probe = CancellationAwareSleepProbe()
    let store = Store(reducer: FlowScopeFeature(probes: [1: probe]))
    var bodyEntered = false
    var handle: FlowTask?
    let caller = Task { @MainActor in
      await withFlowScope { scope in
        bodyEntered = true
        handle = await scope.track(store.send(.start(1)))
        await Task.yield()
      }
    }

    caller.cancel()
    await caller.value

    #expect(bodyEntered)
    #expect(probe.isCancelled == false)
    #expect(handle?.isCancelled == true)
    #expect(handle?.isFinished == true)
    #expect(store.state.completed.isEmpty)
  }

  @Test("completed dispatches are removed without retroactive cancellation")
  func completedTaskIsNotCancelled() async {
    let store = Store(reducer: FlowScopeFeature(probes: [:]))
    var handle: FlowTask?

    await withFlowScope { scope in
      let completed = store.send(.completeImmediately(1))
      await completed.finish()
      handle = await scope.track(completed)
      #expect(scope.trackedTaskCount == 0)
    }

    #expect(handle?.isFinished == true)
    #expect(handle?.isCancelled == false)
    #expect(store.state.completed == [1])
  }

  @Test("closing one scope leaves sibling work alive")
  func siblingScopesAreIsolated() async {
    let firstProbe = CancellationAwareSleepProbe()
    let secondProbe = CancellationAwareSleepProbe()
    let store = Store(
      reducer: FlowScopeFeature(probes: [1: firstProbe, 2: secondProbe])
    )
    let firstScope = FlowScope()
    let secondScope = FlowScope()
    let first = await firstScope.track(store.send(.start(1)))
    let second = await secondScope.track(store.send(.start(2)))
    #expect(await firstProbe.started.wait())
    #expect(await secondProbe.started.wait())

    await firstScope.cancelAndFinish()
    #expect(await firstProbe.cancelled.wait())
    #expect(first.isCancelled)
    #expect(second.isCancelled == false)

    await secondProbe.release()
    await second.finish()
    await secondScope.cancelAndFinish()
    #expect(store.state.completed == [2])
    #expect(second.isCancelled == false)
  }

  @Test("closing a nested scope leaves its outer scope work alive")
  func nestedScopesAreIsolated() async {
    let outerProbe = CancellationAwareSleepProbe()
    let innerProbe = CancellationAwareSleepProbe()
    let store = Store(
      reducer: FlowScopeFeature(probes: [1: outerProbe, 2: innerProbe])
    )
    var outerHandle: FlowTask?
    var innerHandle: FlowTask?

    await withFlowScope { outerScope in
      outerHandle = await outerScope.track(store.send(.start(1)))
      #expect(await outerProbe.started.wait())

      await withFlowScope { innerScope in
        innerHandle = await innerScope.track(store.send(.start(2)))
        #expect(await innerProbe.started.wait())
      }

      #expect(await innerProbe.cancelled.wait())
      #expect(innerHandle?.isCancelled == true)
      #expect(outerHandle?.isCancelled == false)
      await outerProbe.release()
      await outerHandle?.finish()
    }

    #expect(outerHandle?.isCancelled == false)
    #expect(outerHandle?.isFinished == true)
    #expect(store.state.completed == [1])
  }

  @Test("registration after closure cancels and joins the late dispatch")
  func lateRegistrationIsRejected() async {
    let probe = CancellationAwareSleepProbe()
    let store = Store(reducer: FlowScopeFeature(probes: [1: probe]))
    let scope = FlowScope()
    await scope.cancelAndFinish()

    let late = store.send(.start(1))
    #expect(await probe.started.wait())
    _ = await scope.track(late)

    #expect(late.isCancelled)
    #expect(late.isFinished)
    #expect(await probe.cancelled.wait())
  }

  @Test("output tracking preserves the original buffered stream")
  func outputTaskKeepsItsStream() async {
    let store = Store(reducer: FlowScopeOutputFeature())
    let scope = FlowScope()
    let outputTask = await scope.track(
      store.send(.start, capturingOutputs: .bufferingNewest(1))
    )
    var values: [String] = []
    for await value in outputTask.outputs {
      values.append(value)
    }
    await scope.cancelAndFinish()

    #expect(values == ["finished"])
    #expect(outputTask.isCancelled == false)
  }

  @Test("leaving a captured output loop early cancels and joins remaining scoped work")
  func outputEarlyExitIsCleanedUp() async {
    let probe = CancellationAwareSleepProbe()
    let store = Store(
      reducer: FlowScopeStreamingOutputFeature(probe: probe),
      initialState: FlowScopeStreamingOutputFeature.State()
    )
    var outputTask: OutputFlowTask<String>?
    var values: [String] = []

    await withFlowScope { scope in
      let tracked = await scope.track(
        store.send(.start, capturingOutputs: .unbounded)
      )
      outputTask = tracked
      for await value in tracked.outputs {
        values.append(value)
        break
      }
      #expect(await probe.started.wait())
    }

    #expect(values == ["started"])
    #expect(await probe.cancelled.wait())
    #expect(outputTask?.isCancelled == true)
    #expect(outputTask?.isFinished == true)
  }

  @Test("many completed registrations do not accumulate")
  func completedRegistrationsAreReleased() async {
    let store = Store(reducer: FlowScopeFeature(probes: [:]))
    let scope = FlowScope()

    for value in 0..<256 {
      let task = store.send(.completeImmediately(value))
      await task.finish()
      _ = await scope.track(task)
    }

    #expect(scope.trackedTaskCount == 0)
    await scope.cancelAndFinish()
    #expect(store.state.completed.count == 256)
  }

  @Test("completion observation does not retain the scope")
  func completedTaskDoesNotRetainScope() async {
    let store = Store(reducer: FlowScopeFeature(probes: [:]))
    weak var releasedScope: FlowScope?

    do {
      var scope: FlowScope? = FlowScope()
      releasedScope = scope
      let task = store.send(.completeImmediately(1))
      _ = await scope?.track(task)
      await task.finish()
      scope = nil
    }

    await drainAsyncWork()
    #expect(releasedScope == nil)
  }

  @Test("concurrent close callers all wait for physical task termination")
  func concurrentCloseCallersJoinTheSameCleanup() async {
    let probe = FlowScopeUncooperativeProbe()
    let store = Store(reducer: ConcurrentFlowScopeFeature(probe: probe))
    let scope = FlowScope()
    let handle = await scope.track(store.send(.start))
    #expect(await probe.started.wait())

    var firstReturned = false
    var secondReturned = false
    let first = Task { @MainActor in
      await scope.cancelAndFinish()
      firstReturned = true
    }
    #expect(await probe.cancelled.wait())
    let second = Task { @MainActor in
      await scope.cancelAndFinish()
      secondReturned = true
    }
    await Task.yield()

    #expect(firstReturned == false)
    #expect(secondReturned == false)
    await probe.release()
    await first.value
    await second.value

    #expect(firstReturned)
    #expect(secondReturned)
    #expect(handle.isFinished)
  }
}

private final class FlowScopeUncooperativeProbe: Sendable {
  let started = AsyncTestSignal()
  let cancelled = AsyncTestSignal()
  private let releaseGate = RunStartGate()

  func run() async {
    started.signal()
    await withTaskCancellationHandler {
      await releaseGate.wait()
    } onCancel: {
      cancelled.signal()
    }
  }

  func release() async {
    await releaseGate.open()
  }
}

private struct ConcurrentFlowScopeFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {}

  enum Action: Equatable, Sendable {
    case start
    case completed
  }

  let probe: FlowScopeUncooperativeProbe

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start:
      return .run { send, _ in
        await probe.run()
        await send(.completed)
      }
    case .completed:
      return .none
    }
  }
}

private struct FlowScopeFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var completed: [Int] = []
    init() {}
  }

  enum Action: Equatable, Sendable {
    case start(Int)
    case completeImmediately(Int)
    case completed(Int)
  }

  let probes: [Int: CancellationAwareSleepProbe]

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start(let value):
      guard let probe = probes[value] else { return .none }
      return .run { send in
        do {
          try await probe.sleep()
          await send(.completed(value))
        } catch is CancellationError {
          return
        } catch {
          return
        }
      }

    case .completeImmediately(let value), .completed(let value):
      state.completed.append(value)
      return .none
    }
  }
}

private struct FlowScopeOutputFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
  }

  enum Action: Equatable, Sendable {
    case start
  }

  typealias Output = String

  func reduce(into state: inout State, action: Action) -> ReducerEffect<Action, String> {
    .output("finished")
  }
}

private struct FlowScopeStreamingOutputFeature: Reducer {
  struct State: Equatable, Sendable {}

  enum Action: Equatable, Sendable {
    case start
    case emitFinished
  }

  typealias Output = String

  let probe: CancellationAwareSleepProbe

  func reduce(into state: inout State, action: Action) -> ReducerEffect<Action, String> {
    switch action {
    case .start:
      return .concatenate(
        .output("started"),
        .run { send in
          do {
            try await probe.sleep()
            await send(.emitFinished)
          } catch is CancellationError {
            return
          } catch {
            return
          }
        }
      )

    case .emitFinished:
      return .output("finished")
    }
  }
}
