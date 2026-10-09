import Foundation
import InnoFlowCore
import InnoFlowTesting
import Testing

/// Public-host regressions intentionally also compile against the pre-fix revision.
@Suite("Runtime completion and result consistency")
@MainActor
struct RuntimeConsistencyTests {
  @Test(
    "trailing dispatch completion is independent of handle retention", arguments: [false, true],
    [1, 1_000])
  func trailingCompletion(retainsHandle: Bool, count: Int) async throws {
    let clock = ManualTestClock()
    let diagnostics = StoreDiagnostics(capacity: 32)
    let store = Store(
      reducer: CompletionConsistencyFeature(), clock: .manual(clock), diagnostics: diagnostics)

    for value in 0..<count {
      var handle: FlowTask? = store.send(.request(value, .throttle))
      if !retainsHandle { handle = nil }
      // The interpreter serializes root effects. Finishing this sentinel proves
      // that the preceding throttle admission has installed its runtime timer.
      await store.send(.barrier).finish()
      let physicalTask = try #require(
        store.throttleState.trailingTask(for: CompletionConsistencyFeature.timingID))
      try await clock.waitForSleepers(atLeast: 1)
      await clock.advance(by: .seconds(1))
      await physicalTask.value
      await handle?.finish()
      #expect(store.state.values.last == value)
      #expect(diagnostics.snapshot().activeDispatches.isEmpty)
    }
    #expect(store.state.values.count == count)
    #expect(diagnostics.snapshot().records.count <= 32)
    #expect(store.effectBridge.cancellationScopeMetrics.liveScopes == 0)
  }

  @Test(
    "discarded run and debounce handles complete as controls",
    arguments: [CompletionConsistencyFeature.Mode.run, .debounce])
  func discardedControls(mode: CompletionConsistencyFeature.Mode) async throws {
    let clock = ManualTestClock()
    let diagnostics = StoreDiagnostics()
    let store = Store(
      reducer: CompletionConsistencyFeature(), clock: .manual(clock), diagnostics: diagnostics)
    let finished = ConsistencySignal()
    discardControlDispatch(store, mode: mode, finished: finished)
    await store.send(.barrier).finish()
    try await clock.waitForSleepers(atLeast: 1)
    await clock.advance(by: .seconds(1))
    // The completion callback marks the actual dispatch terminal boundary,
    // without an arbitrary delay used to give the runtime time to settle.
    #expect(await finished.wait())
    await store.send(.barrier).finish()
    #expect(store.state.values == [7])
    #expect(diagnostics.snapshot().activeDispatches.isEmpty)
  }

  @Test("shared throttle dispatch cancellation leaves newer work alive")
  func sharedThrottleCancellation() async throws {
    let clock = ManualTestClock()
    let diagnostics = StoreDiagnostics()
    let store = Store(
      reducer: CompletionConsistencyFeature(), clock: .manual(clock), diagnostics: diagnostics)
    let first = store.send(.request(1, .throttle))
    await store.send(.barrier).finish()
    let second = store.send(.request(2, .throttle))
    await store.send(.barrier).finish()
    let physicalTask = try #require(
      store.throttleState.trailingTask(for: CompletionConsistencyFeature.timingID))
    first.cancel()
    await first.finish()
    #expect(first.isFinished)
    #expect(!second.isFinished)
    #expect(!physicalTask.isCancelled)
    try await clock.waitForSleepers(atLeast: 1)
    await clock.advance(by: .seconds(1))
    await physicalTask.value
    await second.finish()
    #expect(store.state.values == [2])
    #expect(diagnostics.snapshot().activeDispatches.isEmpty)
    #expect(diagnostics.snapshot().records.filter { $0.kind == .terminated }.count == 4)
  }

  @Test("throttle replacement releases every discarded dispatch", arguments: [1, 1_000])
  func discardedSharedThrottle(count: Int) async throws {
    let clock = ManualTestClock()
    let diagnostics = StoreDiagnostics(capacity: 16)
    let store = Store(
      reducer: CompletionConsistencyFeature(), clock: .manual(clock), diagnostics: diagnostics)
    for value in 0..<count {
      store.send(.request(value, .throttle))
      await store.send(.barrier).finish()
    }
    let physicalTask = try #require(
      store.throttleState.trailingTask(for: CompletionConsistencyFeature.timingID))
    try await clock.waitForSleepers(atLeast: 1)
    await clock.advance(by: .seconds(1))
    await physicalTask.value
    await store.send(.barrier).finish()
    #expect(store.state.values == [count - 1])
    #expect(diagnostics.snapshot().activeDispatches.isEmpty)
    #expect(diagnostics.snapshot().records.count <= 16)
    #expect(store.effectBridge.cancellationScopeMetrics.liveScopes == 0)
  }

  @Test(
    "perform maps all errors while active in both hosts",
    arguments: PerformConsistencyFeature.Outcome.allCases)
  func performMapping(outcome: PerformConsistencyFeature.Outcome) async {
    let production = Store(reducer: PerformConsistencyFeature(outcome: outcome))
    await production.send(.start).finish()
    #expect(production.state.results == [outcome.expected])

    let testing = TestStore(reducer: PerformConsistencyFeature(outcome: outcome))
    await testing.send(.start)
    await testing.receive(.result(outcome.expected), timeout: .seconds(1)) {
      $0.results = [outcome.expected]
    }
    await testing.finish()
  }

  @Test("ordinary sequence run keeps its silent CancellationError contract")
  func ordinaryRunCancellationErrorControl() async {
    let production = Store(reducer: PerformConsistencyFeature(outcome: .success))
    await production.send(.sequenceCancellation).finish()
    #expect(production.state.results.isEmpty)
    let testing = TestStore(reducer: PerformConsistencyFeature(outcome: .success))
    await testing.send(.sequenceCancellation)
    await testing.finish()
  }

  @Test(
    "accepted cancellation suppresses a later thrown error without faking physical completion",
    arguments: [false, true])
  func cancellationBeforeFailure(throwsCancellation: Bool) async throws {
    let started = ConsistencySignal()
    let release = ConsistencyGate()
    let diagnostics = StoreDiagnostics()
    let store = Store(
      reducer: PerformConsistencyFeature(
        outcome: .failure,
        beforeResult: {
          started.signal()
          await release.wait()
          if throwsCancellation { throw CancellationError() }
        }),
      diagnostics: diagnostics
    )
    let task = store.send(.start)
    try #require(await started.wait())
    task.cancel()
    #expect(task.isCancelled)
    #expect(!task.isFinished)
    #expect(diagnostics.snapshot().activeDispatches.count == 1)
    #expect(diagnostics.snapshot().activeDispatches.first?.activeRunCount == 1)
    await release.open()
    await task.finish()
    #expect(task.isFinished)
    #expect(store.state.results.isEmpty)
    #expect(diagnostics.snapshot().activeDispatches.isEmpty)
    #expect(diagnostics.snapshot().records.filter { $0.kind == .terminated }.count == 1)
  }

  @Test("releasing the Store cancels a trailing timer and closes its dispatch")
  func storeReleaseClosesTrailingDispatch() async throws {
    let clock = ManualTestClock()
    let diagnostics = StoreDiagnostics()
    var store: Store<CompletionConsistencyFeature>? = Store(
      reducer: CompletionConsistencyFeature(), clock: .manual(clock), diagnostics: diagnostics)
    let isStoreAlive = { [weak store] in store != nil }
    store?.send(.request(1, .throttle))
    await store?.send(.barrier).finish()
    let physicalTask = try #require(
      store?.throttleState.trailingTask(for: CompletionConsistencyFeature.timingID))
    try await clock.waitForSleepers(atLeast: 1)
    store = nil
    #expect(!isStoreAlive())
    await physicalTask.value
    #expect(diagnostics.snapshot().activeDispatches.isEmpty)
    #expect(await clock.sleeperCount == 0)
  }
}

@MainActor
private func discardControlDispatch(
  _ store: Store<CompletionConsistencyFeature>,
  mode: CompletionConsistencyFeature.Mode,
  finished: ConsistencySignal
) {
  let task = store.send(.request(7, mode))
  task.observeCompletion { finished.signal() }
}

struct CompletionConsistencyFeature: Reducer {
  struct State: Sendable, DefaultInitializable {
    var values: [Int] = []
    init() {}
  }
  enum Mode: Sendable { case throttle, debounce, run }
  enum Action: Sendable {
    case request(Int, Mode)
    case commit(Int)
    case barrier
  }
  static let timingID = AnyEffectID(StaticEffectID("completion-consistency"))

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .request(let value, let mode):
      switch mode {
      case .throttle:
        return .send(.commit(value)).throttle(
          Self.timingID, for: .seconds(1), leading: false, trailing: true)
      case .debounce:
        return .send(.commit(value)).debounce(Self.timingID, for: .seconds(1))
      case .run:
        return .run { send, context in
          do {
            try await context.sleep(for: .seconds(1))
            await send(.commit(value))
          } catch {}
        }
      }
    case .commit(let value):
      state.values.append(value)
      return .none
    case .barrier:
      return .run { _ in }
    }
  }
}

struct PerformConsistencyFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var results: [String] = []
    init() {}
  }
  enum Action: Equatable, Sendable {
    case start, sequenceCancellation
    case result(String)
  }
  enum Outcome: Sendable, CaseIterable {
    case success, failure, cancellationError
    var expected: String {
      switch self {
      case .success: "success:42"
      case .failure: "failure:unavailable"
      case .cancellationError: "failure:cancellation"
      }
    }
  }
  enum Failure: Error { case unavailable }
  let outcome: Outcome
  var beforeResult: @Sendable () async throws -> Void = {}

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start:
      return .perform(
        operation: {
          try await beforeResult()
          switch outcome {
          case .success: return 42
          case .failure: throw Failure.unavailable
          case .cancellationError: throw CancellationError()
          }
        }, success: { .result("success:\($0)") },
        failure: {
          .result($0 is CancellationError ? "failure:cancellation" : "failure:unavailable")
        })
    case .sequenceCancellation:
      return .run { _ in ConsistencyCancelledSequence<Action>() }
    case .result(let result):
      state.results.append(result)
      return .none
    }
  }
}

private final class ConsistencySignal: Sendable {
  private let stream: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation
  init() {
    let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    stream = pair.stream
    continuation = pair.continuation
  }
  func signal() {
    continuation.yield()
    continuation.finish()
  }
  func wait() async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
      group.addTask { [stream] in
        for await _ in stream { return true }
        return false
      }
      group.addTask {
        do { try await Task.sleep(for: .seconds(5)) } catch {}
        return false
      }
      let result = await group.next() ?? false
      group.cancelAll()
      return result
    }
  }
}

private actor ConsistencyGate {
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

private struct ConsistencyCancelledSequence<Element: Sendable>: AsyncSequence, Sendable {
  struct AsyncIterator: AsyncIteratorProtocol, Sendable {
    mutating func next() async throws -> Element? { throw CancellationError() }
  }
  func makeAsyncIterator() -> AsyncIterator { .init() }
}
