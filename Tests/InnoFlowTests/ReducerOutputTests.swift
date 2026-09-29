import InnoFlow
import InnoFlowCore
import InnoFlowTesting
import Testing
import os

@Suite("Reducer output")
@MainActor
struct ReducerOutputTests {
  @Test("Store publishes typed output after state mutation")
  func storePublishesTypedOutput() async {
    let store = Store(reducer: OutputFeature())
    var outputs = store.outputs(bufferingPolicy: .unbounded).makeAsyncIterator()

    let task = store.send(.selected(7))
    await task.finish()

    #expect(store.state.selection == 7)
    #expect(await outputs.next() == .openDetail(7))
  }

  @Test("dispatch capture buffers synchronous output before send returns")
  func dispatchCaptureBuffersSynchronousOutput() async {
    let probe = OutputDeliveryProbe<OutputFeature.Action>()
    let store = Store(
      reducer: OutputFeature(),
      instrumentation: .init(didDeliverOutput: probe.record)
    )

    let task = store.send(.selected(17), capturingOutputs: .unbounded)
    var outputs = task.outputs.makeAsyncIterator()
    await task.finish()

    #expect(await outputs.next() == .openDetail(17))
    #expect(await outputs.next() == nil)
    #expect(!task.isCancelled)
    #expect(probe.events.count == 1)
    #expect(probe.events[0].subscriberCount == 0)
    #expect(probe.events[0].dispatchCaptureDisposition == .enqueued)
  }

  @Test("dispatch capture isolates concurrent action trees")
  func dispatchCaptureIsolatesConcurrentActionTrees() async throws {
    let clock = ManualTestClock()
    let store = Store(
      reducer: DelayedOutputFeature(),
      clock: .manual(clock)
    )

    let delayed = store.send(.start, capturingOutputs: .unbounded)
    try await clock.waitForSleepers(atLeast: 1)
    let immediate = store.send(.emit(2), capturingOutputs: .unbounded)
    var delayedOutputs = delayed.outputs.makeAsyncIterator()
    var immediateOutputs = immediate.outputs.makeAsyncIterator()

    await immediate.finish()
    #expect(await immediateOutputs.next() == 2)
    #expect(await immediateOutputs.next() == nil)

    await clock.advance(by: .seconds(1))
    await delayed.finish()
    #expect(await delayedOutputs.next() == 1)
    #expect(await delayedOutputs.next() == nil)
  }

  @Test("dispatch capture exposes its bounded-buffer drop result")
  func dispatchCaptureReportsBoundedDrop() async {
    let probe = OutputDeliveryProbe<BurstOutputFeature.Action>()
    let store = Store(
      reducer: BurstOutputFeature(),
      instrumentation: .init(didDeliverOutput: probe.record)
    )

    let task = store.send(.burst, capturingOutputs: .bufferingNewest(1))
    var outputs = task.outputs.makeAsyncIterator()
    await task.finish()

    #expect(await outputs.next() == 2)
    #expect(await outputs.next() == nil)
    #expect(probe.events.map(\.dispatchCaptureDisposition) == [.enqueued, .dropped])
  }

  @Test("cancelling the captured-output consumer cancels its dispatch")
  func cancellingCapturedOutputConsumerCancelsDispatch() async throws {
    let clock = ManualTestClock()
    let store = Store(reducer: DelayedOutputFeature(), clock: .manual(clock))
    let flow = store.send(.start, capturingOutputs: .unbounded)
    let independent = store.send(.start, capturingOutputs: .unbounded)
    try await clock.waitForSleepers(atLeast: 2)
    let ready = AsyncStream<Void>.makeStream()
    let consumer = Task {
      ready.continuation.yield(())
      for await _ in flow.outputs {}
    }
    var started = ready.stream.makeAsyncIterator()
    _ = await started.next()

    consumer.cancel()
    await consumer.value

    #expect(flow.isCancelled)
    // Keep a regression failure from leaving its sleeping effect alive.
    flow.cancel()
    await flow.finish()

    #expect(!independent.isCancelled)
    await clock.advance(by: .seconds(1))
    await independent.finish()
    var independentOutputs = independent.outputs.makeAsyncIterator()
    #expect(await independentOutputs.next() == 1)
    #expect(await independentOutputs.next() == nil)
  }

  @Test("a consumer cancelled before iteration still cancels its captured dispatch")
  func consumerCancelledBeforeIteration() async throws {
    let clock = ManualTestClock()
    let store = Store(reducer: DelayedOutputFeature(), clock: .manual(clock))
    let flow = store.send(.start, capturingOutputs: .unbounded)
    try await clock.waitForSleepers(atLeast: 1)
    // This main-actor task cannot start before the synchronous cancel below.
    let consumer = Task {
      for await _ in flow.outputs {}
    }
    consumer.cancel()
    await consumer.value

    #expect(flow.isCancelled)
    flow.cancel()
    await flow.finish()
  }

  @Test("cancelling a broadcast subscriber does not cancel a dispatch")
  func broadcastCancellationDoesNotCancelDispatch() async throws {
    let clock = ManualTestClock()
    let store = Store(reducer: DelayedOutputFeature(), clock: .manual(clock))
    let broadcast = store.outputs()
    let consumer = Task {
      for await _ in broadcast {}
    }
    let flow = store.send(.start, capturingOutputs: .unbounded)
    try await clock.waitForSleepers(atLeast: 1)

    consumer.cancel()
    await consumer.value

    #expect(!flow.isCancelled)
    await clock.advance(by: .seconds(1))
    await flow.finish()
    var outputs = flow.outputs.makeAsyncIterator()
    #expect(await outputs.next() == 1)
    #expect(await outputs.next() == nil)
  }

  @Test("early loop exit requires explicit dispatch cancellation")
  func earlyLoopExitRequiresExplicitCancellation() async throws {
    let clock = ManualTestClock()
    let store = Store(reducer: DelayedOutputFeature(), clock: .manual(clock))
    let flow = store.send(.startWithInitialOutput, capturingOutputs: .unbounded)
    try await clock.waitForSleepers(atLeast: 1)

    for await value in flow.outputs {
      #expect(value == 0)
      break
    }

    #expect(!flow.isCancelled)
    flow.cancel()
    await flow.finish()
    #expect(flow.isCancelled)
  }

  @Test("a retained capture does not retain a completed dispatch tracker")
  func captureDoesNotRetainCompletedTracker() {
    let capture = TypedFlowTaskOutputCapture<Int>(bufferingPolicy: .unbounded)
    var tracker: FlowTaskTracker? = FlowTaskTracker(outputCapture: capture)
    weak let weakTracker = tracker
    capture.cancelDispatchOnConsumerTermination(tracker!)
    let activity = tracker!.beginActivity()
    tracker!.endActivity(activity)

    tracker = nil

    #expect(weakTracker == nil)
  }

  @Test("output streams broadcast to every live subscriber")
  func broadcastsToLiveSubscribers() async {
    let store = Store(reducer: OutputFeature())
    var first = store.outputs().makeAsyncIterator()
    var second = store.outputs().makeAsyncIterator()

    await store.send(.selected(3)).finish()

    #expect(await first.next() == .openDetail(3))
    #expect(await second.next() == .openDetail(3))
  }

  @Test("default output buffering preserves ordered bursts")
  func defaultBufferingPreservesOrderedBursts() async {
    let store = Store(reducer: OutputFeature())
    var outputs = store.outputs().makeAsyncIterator()

    await store.send(.selected(1)).finish()
    await store.send(.selected(2)).finish()

    #expect(await outputs.next() == .openDetail(1))
    #expect(await outputs.next() == .openDetail(2))
  }

  @Test("output instrumentation reports missing subscribers and bounded drops")
  func outputInstrumentationReportsDeliveryResults() async {
    let probe = OutputDeliveryProbe<OutputFeature.Action>()
    let store = Store(
      reducer: OutputFeature(),
      instrumentation: .init(didDeliverOutput: probe.record)
    )

    await store.send(.selected(1)).finish()

    var outputs = store.outputs(bufferingPolicy: .bufferingNewest(1)).makeAsyncIterator()
    await store.send(.selected(2)).finish()
    await store.send(.selected(3)).finish()

    #expect(await outputs.next() == .openDetail(3))
    #expect(probe.events.count == 3)
    #expect(probe.events[0].subscriberCount == 0)
    #expect(probe.events[0].enqueuedCount == 0)
    #expect(probe.events[1].subscriberCount == 1)
    #expect(probe.events[1].enqueuedCount == 1)
    #expect(probe.events[2].subscriberCount == 1)
    #expect(probe.events[2].droppedCount == 1)
  }

  @Test("output streams do not replay values emitted before subscription")
  func streamsDoNotReplayEarlierValues() async {
    let store = Store(reducer: OutputFeature())
    await store.send(.selected(1)).finish()

    var outputs = store.outputs().makeAsyncIterator()
    await store.send(.selected(2)).finish()

    #expect(await outputs.next() == .openDetail(2))
  }

  @Test("releasing the store finishes live output streams")
  func releasingStoreFinishesStreams() async {
    var store: Store<OutputFeature>? = Store(reducer: OutputFeature())
    var outputs = store!.outputs().makeAsyncIterator()

    store = nil

    #expect(await outputs.next() == nil)
  }

  @Test("mapped child output reaches the parent output channel")
  func mapsChildOutput() async {
    let store = Store(reducer: OutputParentFeature())
    var outputs = store.outputs().makeAsyncIterator()

    await store.send(.child(.finished("done"))).finish()

    #expect(await outputs.next() == .childFinished("done"))
  }

  @Test("cancelling a dispatch tree suppresses descendant outputs")
  func cancellationSuppressesDescendantOutputs() async {
    let clock = ManualTestClock()
    let store = Store(
      reducer: DelayedOutputFeature(),
      clock: .manual(clock)
    )
    var outputs = store.outputs().makeAsyncIterator()

    let flow = store.send(.start)
    try? await clock.waitForSleepers(atLeast: 1)
    flow.cancel()
    await flow.finish()
    await clock.advance(by: .seconds(1))

    await store.send(.emit(2)).finish()
    #expect(await outputs.next() == 2)
  }

  @Test("TestStore receives outputs exhaustively")
  func testStoreReceivesOutput() async {
    let store = TestStore(reducer: OutputFeature())

    await store.send(.selected(11)) {
      $0.selection = 11
    }
    await store.receiveOutput(.openDetail(11))
    await store.finish()
  }

  @Test("TestStore finish reports an unhandled output")
  func testStoreFinishReportsUnhandledOutput() async {
    let store = TestStore(reducer: OutputFeature())

    await store.send(.selected(19)) {
      $0.selection = 19
    }

    guard case .unhandledOutputs(let outputs) = await store.finishResult(timeout: .zero) else {
      Issue.record("Expected an unhandled output result")
      return
    }
    #expect(outputs == ["openDetail(19)"])
  }

  @Test("TestStore non-exhaustive output draining honors the total deadline")
  func testStoreOutputDrainHonorsDeadline() async {
    let store = TestStore(reducer: BurstOutputFeature())
    store.exhaustivity = .off

    await store.send(.burst)

    guard case .timedOut = await store.finishResult(timeout: .zero) else {
      Issue.record("Expected the total deadline to stop buffered output draining")
      return
    }
  }

  @Test("@InnoFlow features can declare and emit typed outputs")
  func macroFeatureEmitsOutput() async {
    let store = Store(reducer: MacroOutputFeature())
    var outputs = store.outputs().makeAsyncIterator()

    await store.send(.increment).finish()

    #expect(store.state.count == 1)
    #expect(await outputs.next() == .didIncrement(1))
  }
}

private final class OutputDeliveryProbe<Action: Sendable>: Sendable {
  private let storage = OSAllocatedUnfairLock<[StoreInstrumentation<Action>.OutputDeliveryEvent]>(
    initialState: []
  )

  var events: [StoreInstrumentation<Action>.OutputDeliveryEvent] {
    storage.withLock { $0 }
  }

  func record(_ event: StoreInstrumentation<Action>.OutputDeliveryEvent) {
    storage.withLock { $0.append(event) }
  }
}

@InnoFlow
private struct MacroOutputFeature {
  struct State: Equatable, Sendable, DefaultInitializable {
    var count = 0

    init() {}
  }

  enum Action: Equatable, Sendable {
    case increment
  }

  enum Output: Equatable, Sendable {
    case didIncrement(Int)
  }

  var body: some Reducer<State, Action, Output> {
    Reduce { state, action in
      switch action {
      case .increment:
        state.count += 1
        return Self.output(.didIncrement(state.count))
      }
    }
  }
}

private struct OutputFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var selection: Int?

    init() {}
  }

  enum Action: Equatable, Sendable {
    case selected(Int)
  }

  enum Output: Equatable, Sendable {
    case openDetail(Int)
  }

  func reduce(into state: inout State, action: Action) -> ReducerEffect<Action, Output> {
    switch action {
    case .selected(let id):
      state.selection = id
      return Self.output(.openDetail(id))
    }
  }
}

private struct OutputChildFeature: Reducer {
  struct State: Equatable, Sendable {
    var value = ""
  }

  enum Action: Equatable, Sendable {
    case finished(String)
  }

  typealias Output = String

  func reduce(into state: inout State, action: Action) -> ReducerEffect<Action, Output> {
    switch action {
    case .finished(let value):
      state.value = value
      return Self.output(value)
    }
  }
}

private struct OutputParentFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var child = OutputChildFeature.State()

    init() {}
  }

  enum Action: Equatable, Sendable {
    case child(OutputChildFeature.Action)
  }

  enum Output: Equatable, Sendable {
    case childFinished(String)
  }

  private static let childAction = CasePath<Action, OutputChildFeature.Action>(
    embed: Action.child,
    extract: {
      guard case .child(let action) = $0 else { return nil }
      return action
    }
  )

  func reduce(into state: inout State, action: Action) -> ReducerEffect<Action, Output> {
    Scope(
      state: \.child,
      action: Self.childAction,
      reducer: OutputChildFeature()
    )
    .mapOutput(Output.childFinished)
    .reduce(into: &state, action: action)
  }
}

private struct DelayedOutputFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {}

  enum Action: Equatable, Sendable {
    case start
    case startWithInitialOutput
    case emit(Int)
  }

  typealias Output = Int

  func reduce(into state: inout State, action: Action) -> ReducerEffect<Action, Output> {
    switch action {
    case .startWithInitialOutput:
      return .concatenate(Self.output(0), reduce(into: &state, action: .start))
    case .start:
      return .run { send, context in
        do {
          try await context.sleep(for: .seconds(1))
          try await context.checkCancellation()
          await send(.emit(1))
        } catch is CancellationError {
          return
        } catch {
          return
        }
      }

    case .emit(let value):
      return Self.output(value)
    }
  }
}

private struct BurstOutputFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {}

  enum Action: Equatable, Sendable {
    case burst
  }

  typealias Output = Int

  func reduce(into state: inout State, action: Action) -> ReducerEffect<Action, Output> {
    switch action {
    case .burst:
      return .concatenate(Self.output(1), Self.output(2))
    }
  }
}
