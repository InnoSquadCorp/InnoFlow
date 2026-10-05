import InnoFlowCore
import InnoFlowTesting
import Testing

@Suite("Testing effect ledger", .serialized)
@MainActor
struct TestEffectLedgerConsistencyTests {
  @Test("latest replacement is recorded in the displaced dispatch ledger")
  func latestSupersession() async {
    let firstGate = LedgerGate()
    let secondGate = LedgerGate()
    let starts = AsyncStream<Int>.makeStream()
    let store = TestStore(
      reducer: LedgerFeature(gates: [1: firstGate, 2: secondGate], starts: starts.continuation))
    let first = await store.send(.start(1, .latest))
    var started = starts.stream.makeAsyncIterator()
    #expect(await started.next() == 1)
    let second = await store.send(.start(2, .latest))
    #expect(await started.next() == 2)
    #expect(first.effectLedger.events.contains(.superseded))
    #expect(first.effectLedger.events.contains(.cancelled(.superseded)))
    #expect(!second.effectLedger.events.contains(.superseded))
    #expect(!first.isFinished)
    await firstGate.open()
    await secondGate.open()
    await first.finish()
    await second.finish()
    #expect(first.effectLedger.events.last == .finished)
    #expect(second.effectLedger.events.last == .finished)
    #expect(store.effectLedgers.count == 0)
    await store.finish()
  }

  @Test("serial pending, rejection, cancellation-before-start, and capacity return are observable")
  func serialAdmissionLifecycle() async {
    let firstGate = LedgerGate()
    let fourthGate = LedgerGate()
    let starts = AsyncStream<Int>.makeStream()
    let store = TestStore(
      reducer: LedgerFeature(gates: [1: firstGate, 4: fourthGate], starts: starts.continuation))
    let first = await store.send(.start(1, .serial(maxPending: 1)))
    var started = starts.stream.makeAsyncIterator()
    #expect(await started.next() == 1)
    let pending = await store.send(.start(2, .serial(maxPending: 1)))
    let rejected = await store.send(.start(3, .serial(maxPending: 1)))
    #expect(pending.effectLedger.events.contains(.admitted(.queued(position: 1))))
    #expect(rejected.effectLedger.events.contains(.rejected(.queueFull(maxPending: 1))))
    #expect(!rejected.effectLedger.events.contains(.started))
    pending.cancel()
    await pending.finish()
    #expect(pending.effectLedger.events.contains(.cancelled(.dispatch)))
    #expect(pending.effectLedger.events.contains(.admitted(.cancelledBeforeStart)))
    let fourth = await store.send(.start(4, .serial(maxPending: 1)))
    #expect(fourth.effectLedger.events.contains(.admitted(.queued(position: 1))))
    await firstGate.open()
    #expect(await started.next() == 4)
    await fourthGate.open()
    await first.finish()
    await fourth.finish()
    await rejected.finish(timeout: .zero)
    await store.finish()
    #expect(store.effectLedgers.count == 0)
  }

  @Test("drop rejection and successful physical start remain distinct")
  func dropAdmission() async {
    let gate = LedgerGate()
    let starts = AsyncStream<Int>.makeStream()
    let store = TestStore(reducer: LedgerFeature(gates: [1: gate], starts: starts.continuation))
    let first = await store.send(.start(1, .dropWhileRunning))
    var started = starts.stream.makeAsyncIterator()
    #expect(await started.next() == 1)
    let second = await store.send(.start(2, .dropWhileRunning))
    #expect(first.effectLedger.events.contains(.admitted(.started)))
    #expect(first.effectLedger.events.contains(.started))
    #expect(second.effectLedger.events == [.rejected(.busy), .finished])
    await gate.open()
    await first.finish()
    await second.finish()
    await store.finish()
  }

  @Test("run errors are captured once before dispatch completion")
  func failureEvent() async {
    let store = TestStore(reducer: LedgerFeature())
    var failures = 0
    store.issueReporter = { _, _ in failures += 1 }
    let task = await store.send(.fail)
    await task.finish()
    #expect(failures == 1)
    #expect(
      task.effectLedger.events.filter {
        if case .failed = $0 { return true }
        return false
      }.count == 1)
    #expect(task.effectLedger.events.last == .finished)
    await store.finish()
  }

  @Test("bounded ledgers preserve chronological order and stop at physical completion")
  func boundedSnapshot() {
    let storage = TestEffectLedgerStorage(capacity: 3)
    storage.record(.admitted(.started))
    storage.record(.started)
    storage.record(.cancelled(.dispatch))
    storage.record(.finished)
    storage.record(.started)
    #expect(storage.snapshot.events == [.started, .cancelled(.dispatch), .finished])
    #expect(storage.snapshot.droppedEventCount == 1)
  }

  @Test("discarded immediate dispatches release ledger registrations synchronously")
  func discardedDispatchRegistrations() async {
    let store = TestStore(reducer: LedgerFeature())
    for _ in 0..<1_000 { await store.send(.none) }
    #expect(store.effectLedgers.count == 0)
    await store.finish(timeout: .zero)
  }
}

private actor LedgerGate {
  private var isOpen = false
  private var waiting: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { waiting.append($0) }
  }
  func open() {
    isOpen = true
    let continuations = waiting
    waiting.removeAll()
    for continuation in continuations { continuation.resume() }
  }
}

private struct LedgerFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {}
  enum Action: Sendable {
    case start(Int, EffectExecutionPolicy)
    case fail, none
  }
  var gates: [Int: LedgerGate] = [:]
  var starts: AsyncStream<Int>.Continuation?
  struct Failure: Error {}
  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .none: return .none
    case .fail:
      return .run { (_: EffectContext) async throws -> LedgerFailureSequence<Action> in
        throw Failure()
      }
    case .start(let id, let policy):
      let gate = gates[id]
      let starts = starts
      return .run(id: EffectID("ledger-lane"), policy: policy) { _, _ in
        starts?.yield(id)
        await gate?.wait()
      }
    }
  }
}

private struct LedgerFailureSequence<Element: Sendable>: AsyncSequence, Sendable {
  struct AsyncIterator: AsyncIteratorProtocol, Sendable {
    mutating func next() async throws -> Element? { nil }
  }
  func makeAsyncIterator() -> AsyncIterator { .init() }
}
