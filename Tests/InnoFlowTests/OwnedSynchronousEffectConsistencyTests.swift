import InnoFlowCore
import InnoFlowTesting
import Observation
import Testing
import os

private struct SynchronousChild: Reducer {
  var gate: SynchronousEffectGate? = nil
  var cancellationObserved: OSAllocatedUnfairLock<Bool>? = nil
  struct State: Equatable, Sendable {
    var id = 1
    var count = 0
  }
  enum Action: Equatable, Sendable {
    case start, follow, output, sendAndClose, outputAndClose, handoff, composite, merge, startRun,
      run
  }
  func reduce(into state: inout State, action: Action) -> ReducerEffect<Action, String> {
    switch action {
    case .start, .sendAndClose, .handoff: return .send(.follow)
    case .follow:
      state.count += 1
      return .none
    case .output, .outputAndClose: return .output("child")
    case .composite: return .concatenate(.send(.follow), .send(.follow))
    case .merge: return .merge(.send(.follow), .send(.follow))
    case .startRun: return .send(.run)
    case .run:
      guard let gate else { return .none }
      return .run { send in
        await withTaskCancellationHandler {
          await gate.wait()
        } onCancel: {
          gate.cancellation.signal()
        }
        cancellationObserved?.withLock { $0 = Task.isCancelled }
        await send(.follow)
      }.cancellable(EffectID("shared"))
    }
  }
}
private struct SynchronousParentState: Equatable, Sendable {
  var child: SynchronousChild.State? = .init()
  var trace: [String] = []
  var completed = 0
}
private enum SynchronousParentAction: Equatable, Sendable {
  case child(SynchronousChild.Action)
  case tick, close
  case replace(Int)
  case startParent, finishParent
}
private let synchronousChildPath = CasePath<SynchronousParentAction, SynchronousChild.Action>(
  embed: { .child($0) }, extract: { if case .child(let value) = $0 { value } else { nil } })

/// Intentionally ignores cancellation until the test releases its physical work.
private actor SynchronousEffectGate {
  nonisolated let cancellation = AsyncTestSignal()
  private var entered = false
  private var released = false
  private var arrivals: [CheckedContinuation<Void, Never>] = []
  private var releases: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    entered = true
    for arrival in arrivals { arrival.resume() }
    arrivals.removeAll()
    if !released { await withCheckedContinuation { releases.append($0) } }
  }
  func waitUntilEntered() async {
    if !entered { await withCheckedContinuation { arrivals.append($0) } }
  }
  func open() {
    released = true
    for release in releases { release.resume() }
    releases.removeAll()
  }
}

private struct SynchronousFeature: Reducer {
  let managed: Bool
  var gate: SynchronousEffectGate? = nil
  var cancellationObserved: OSAllocatedUnfairLock<Bool>? = nil
  var followupAfterCompletion = false
  func reduce(into state: inout SynchronousParentState, action: SynchronousParentAction)
    -> ReducerEffect<SynchronousParentAction, String>
  {
    let parent = Reduce<SynchronousParentState, SynchronousParentAction, String> { state, action in
      switch action {
      case .child(.start), .child(.handoff): state.trace.append("start")
      case .child(.follow):
        state.trace.append("follow")
        if gate != nil { return .send(.startParent) }
      case .child(.sendAndClose), .child(.outputAndClose), .close:
        state.trace.append("close")
        state.child = nil
      case .tick: state.trace.append("tick")
      case .replace(let id): state.child = .init(id: id)
      case .startParent:
        guard let gate else { return .none }
        return .run { send in
          await withTaskCancellationHandler {
            await gate.wait()
          } onCancel: {
            gate.cancellation.signal()
          }
          cancellationObserved?.withLock { $0 = Task.isCancelled }
          await send(.finishParent)
        }.cancellable(EffectID("shared"))
      case .finishParent:
        state.completed += 1
        if followupAfterCompletion { return .send(.tick) }
      default: break
      }
      return .none
    }
    let child = SynchronousChild(gate: gate, cancellationObserved: cancellationObserved)
    if managed {
      return parent.optionalChild(
        state: \.child, action: synchronousChildPath, instanceID: { $0.id },
        child: child
      ).reduce(into: &state, action: action)
    }
    return CombineReducers {
      IfLet(state: \.child, action: synchronousChildPath, reducer: child)
      parent
    }.reduce(into: &state, action: action)
  }
}

enum SynchronousOwnerChange: CaseIterable, Sendable { case close, replace, reopen }

@MainActor
private final class SynchronousStoreReference {
  weak var store: Store<SynchronousFeature>?
}

@Suite("Owned synchronous effects", .serialized)
@MainActor
struct OwnedSynchronousEffectConsistencyTests {
  @Test(arguments: [false, true])
  func directSendDrainsBeforeReturnAndBeforeIndependentActions(managed: Bool) async {
    let store = Store(reducer: SynchronousFeature(managed: managed), initialState: .init())
    let refreshes = store.scopedObserverRefreshCount
    let task = store.send(.child(.start))
    #expect(store.scopedObserverRefreshCount - refreshes == 2)
    #expect(store.state.child?.count == 1)
    #expect(task.isFinished)
    store.send(.tick)
    store.send(.close)
    #expect(store.state.trace == ["start", "follow", "tick", "close"])
    await task.finish()
  }

  @Test(arguments: [false, true])
  func directOutputIsCapturedAndObservedBeforeReturn(managed: Bool) async {
    let deliveries = OSAllocatedUnfairLock<
      [StoreInstrumentation<SynchronousParentAction>.OutputDeliveryEvent]
    >(initialState: [])
    let store = Store(
      reducer: SynchronousFeature(managed: managed), initialState: .init(),
      instrumentation: .init(didDeliverOutput: { event in deliveries.withLock { $0.append(event) } }
      ))
    let task = store.send(.child(.output), capturingOutputs: .unbounded)
    #expect(task.isFinished)
    let events = deliveries.withLock { $0 }
    #expect(events.count == 1)
    #expect(events.first?.dispatchCaptureDisposition == .enqueued)
    #expect(events.first?.wasSuppressedByCancellation == false)
    store.send(.close)
    var outputs = task.outputs.makeAsyncIterator()
    #expect(await outputs.next() == "child")
    #expect(await outputs.next() == nil)
  }

  @Test func discardedHandlesStillDrainSynchronously() {
    let store = Store(reducer: SynchronousFeature(managed: true), initialState: .init())
    for _ in 0..<64 { store.send(.child(.start)) }
    #expect(store.state.child?.count == 64)
    #expect(store.state.trace == Array(repeating: ["start", "follow"], count: 64).flatMap { $0 })
    #expect(store.effectBridge.cancellationScopeMetrics.liveInterpreters == 0)
    #expect(store.effectBridge.cancellationScopeMetrics.liveScopes == 0)
    #expect(store.effectBridge.cancellationScopeMetrics.liveExactTokens == 0)
    #expect(store.effectBridge.cancellationScopeMetrics.retainedPotentialIDs == 0)
  }

  @Test func sameReductionCloseObservesSuppressedSendAndOutput() async {
    let drops = OSAllocatedUnfairLock<[ActionDropReason]>(initialState: [])
    let emissions = OSAllocatedUnfairLock(initialState: 0)
    let suppressions = OSAllocatedUnfairLock(initialState: 0)
    let store = Store(
      reducer: SynchronousFeature(managed: true), initialState: .init(),
      instrumentation: .init(
        didEmitAction: { _ in emissions.withLock { $0 += 1 } },
        didDropAction: { event in drops.withLock { $0.append(event.reason) } },
        didDeliverOutput: { event in
          if event.wasSuppressedByCancellation { suppressions.withLock { $0 += 1 } }
        }))
    let send = store.send(.child(.sendAndClose))
    #expect(send.isFinished)
    #expect(drops.withLock { $0 } == [.cancellationBoundary])
    #expect(emissions.withLock { $0 } == 1)
    store.send(.replace(2))
    let output = store.send(.child(.outputAndClose), capturingOutputs: .unbounded)
    #expect(output.isFinished)
    #expect(suppressions.withLock { $0 } == 1)
    var outputs = output.outputs.makeAsyncIterator()
    #expect(await outputs.next() == nil)
  }

  @Test(arguments: SynchronousOwnerChange.allCases)
  func reentrantCloseOrReplacementDropsQueuedOldOwner(change: SynchronousOwnerChange) {
    let reference = SynchronousStoreReference()
    let emissions = OSAllocatedUnfairLock<[DispatchID?]>(initialState: [])
    let drops = OSAllocatedUnfairLock<[DispatchID?]>(initialState: [])
    let diagnostics = StoreDiagnostics(capacity: 64)
    let store = Store(
      reducer: SynchronousFeature(managed: true), initialState: .init(),
      instrumentation: .init(
        didEmitAction: { event in
          emissions.withLock { $0.append(event.dispatchID) }
          MainActor.assumeIsolated {
            if change != .replace { reference.store?.send(.close) }
            if change != .close { reference.store?.send(.replace(2)) }
          }
        },
        didDropAction: { event in drops.withLock { $0.append(event.dispatchID) } }),
      diagnostics: diagnostics)
    reference.store = store
    let task = store.send(.child(.start))
    #expect(task.isFinished)
    #expect(store.state.trace == (change == .replace ? ["start"] : ["start", "close"]))
    #expect(store.state.child?.count == (change == .close ? nil : 0))
    #expect(emissions.withLock { $0.count } == 1)
    #expect(drops.withLock { $0 } == emissions.withLock { $0 })
    #expect(drops.withLock { $0.first! } != nil)
    #expect(diagnostics.snapshot().activeDispatches.isEmpty)
  }

  @Test(arguments: [false, true])
  func explicitCompositeKeepsAsynchronousScheduling(parallel: Bool) async {
    let store = Store(reducer: SynchronousFeature(managed: true), initialState: .init())
    let task = store.send(.child(parallel ? .merge : .composite))
    #expect(store.state.child?.count == 0)
    #expect(!task.isFinished)
    await task.finish()
    #expect(store.state.child?.count == 2)
  }

  @Test(arguments: [false, true])
  func testStoreDirectSendRetainsDispatchUntilReceive(managed: Bool) async {
    let store = TestStore(reducer: SynchronousFeature(managed: managed), initialState: .init())
    let task = await store.send(.child(.start)) { $0.trace = ["start"] }
    #expect(!task.isFinished)
    #expect(store.state.child?.count == 0)
    await store.receive(.child(.follow)) {
      $0.child?.count = 1
      $0.trace.append("follow")
    }
    #expect(task.isFinished)
    await store.send(.tick) { $0.trace.append("tick") }
    await store.send(.close) {
      $0.child = nil
      $0.trace.append("close")
    }
    await task.finish()
    await store.finish()
  }

  @Test func testStoreDirectOutputAndSameReductionSuppression() async {
    let store = TestStore(reducer: SynchronousFeature(managed: true), initialState: .init())
    let output = await store.send(.child(.output))
    #expect(output.isFinished)
    await store.receiveOutput("child")
    await output.finish()
    let closed = await store.send(.child(.outputAndClose)) {
      $0.child = nil
      $0.trace.append("close")
    }
    #expect(closed.isFinished)
    await closed.finish()
    await store.finish()
  }

  @Test(arguments: [false, true])
  func parentFollowupsKeepIndependentLifetimeAfterChildClose(useTestStore: Bool) async {
    let gate = SynchronousEffectGate()
    let cancelled = OSAllocatedUnfairLock(initialState: false)
    let feature = SynchronousFeature(managed: true, gate: gate, cancellationObserved: cancelled)
    if useTestStore {
      let store = TestStore(reducer: feature, initialState: .init())
      let task = await store.send(.child(.handoff)) { $0.trace.append("start") }
      await store.receive(.child(.follow)) {
        $0.child?.count = 1
        $0.trace.append("follow")
      }
      #expect(!task.isFinished)
      await store.receive(.startParent)
      await gate.waitUntilEntered()
      await store.send(.close) {
        $0.child = nil
        $0.trace.append("close")
      }
      #expect(!task.isFinished)
      await gate.open()
      await store.receive(.finishParent) { $0.completed = 1 }
      await task.finish()
      #expect(!cancelled.withLock { $0 })
      #expect(store.state.completed == 1)
      await store.finish()
    } else {
      let store = Store(reducer: feature, initialState: .init())
      let task = store.send(.child(.handoff))
      #expect(store.state.child?.count == 1)
      #expect(!task.isFinished)
      await gate.waitUntilEntered()
      store.send(.close)
      #expect(!task.isFinished)
      await gate.open()
      await task.finish()
      #expect(!cancelled.withLock { $0 })
      #expect(store.state.completed == 1)
    }
  }

  @Test func testStoreAutomaticDrainPreservesParentIndependence() async {
    let gate = SynchronousEffectGate()
    let cancelled = OSAllocatedUnfairLock(initialState: false)
    let store = TestStore(
      reducer: SynchronousFeature(managed: true, gate: gate, cancellationObserved: cancelled),
      initialState: .init())
    store.exhaustivity = .off
    let task = await store.send(.child(.handoff))
    // A new send drains the queued child and parent action in non-exhaustive mode.
    await store.send(.tick)
    await gate.waitUntilEntered()
    await store.send(.close)
    #expect(!task.isFinished)
    await gate.open()
    await store.receive(.finishParent)
    await task.finish()
    #expect(!cancelled.withLock { $0 })
    #expect(store.state.completed == 1)
    await store.finish()
  }
}

private struct SynchronousPairState: Equatable, Sendable {
  var id = 1
  var left: SynchronousParentState? = .init()
  var right: SynchronousParentState? = .init()
}
private enum SynchronousPairAction: Equatable, Sendable {
  case left(SynchronousParentAction)
  case right(SynchronousParentAction)
}
private func synchronousPairReducer()
  -> some Reducer<SynchronousPairState, SynchronousPairAction, String>
{
  Reduce<SynchronousPairState, SynchronousPairAction, String> { _, _ in .none }
    .optionalChild(
      state: \.left,
      action: CasePath(
        embed: { .left($0) }, extract: { if case .left(let a) = $0 { a } else { nil } }),
      instanceID: { _ in 1 }, child: SynchronousFeature(managed: true)
    )
    .optionalChild(
      state: \.right,
      action: CasePath(
        embed: { .right($0) }, extract: { if case .right(let a) = $0 { a } else { nil } }),
      instanceID: { _ in 1 }, child: SynchronousFeature(managed: true))
}

extension OwnedSynchronousEffectConsistencyTests {
  @Test(arguments: [false, true])
  func nestedOwnersAndEqualIdentitySiblingsKeepSynchronousFollowups(useTestStore: Bool) async {
    if useTestStore {
      let store = TestStore(reducer: synchronousPairReducer(), initialState: .init())
      let left = await store.send(.left(.child(.start))) { $0.left?.trace.append("start") }
      await store.receive(.left(.child(.follow))) {
        $0.left?.child?.count = 1
        $0.left?.trace.append("follow")
      }
      #expect(left.isFinished)
      await store.send(.left(.close)) {
        $0.left?.child = nil
        $0.left?.trace.append("close")
      }
      let right = await store.send(.right(.child(.start))) { $0.right?.trace.append("start") }
      await store.receive(.right(.child(.follow))) {
        $0.right?.child?.count = 1
        $0.right?.trace.append("follow")
      }
      #expect(right.isFinished)
      #expect(store.state.left?.child == nil)
      #expect(store.state.right?.child?.count == 1)
      await left.finish()
      await right.finish()
      await store.finish()
    } else {
      let store = Store(reducer: synchronousPairReducer(), initialState: .init())
      let left = store.send(.left(.child(.start)))
      #expect(left.isFinished)
      #expect(store.state.left?.child?.count == 1)
      store.send(.left(.close))
      let right = store.send(.right(.child(.start)))
      #expect(right.isFinished)
      #expect(store.state.right?.child?.count == 1)
      #expect(store.state.left?.child == nil)
      await left.finish()
      await right.finish()
    }
  }
}

extension OwnedSynchronousEffectConsistencyTests {
  @Test func testStoreScopedReceivePreservesParentIndependence() async {
    let gate = SynchronousEffectGate()
    let cancelled = OSAllocatedUnfairLock(initialState: false)
    let store = TestStore(
      reducer: SynchronousFeature(managed: true, gate: gate, cancellationObserved: cancelled),
      initialState: .init())
    let scoped = store.scope(
      state: \SynchronousParentState.self,
      action: CasePath<SynchronousParentAction, SynchronousParentAction>(
        embed: { $0 }, extract: { $0 }))
    let task = await scoped.send(.child(.handoff)) { $0.trace.append("start") }
    await scoped.receive(.child(.follow)) {
      $0.child?.count = 1
      $0.trace.append("follow")
    }
    await scoped.receive(.startParent)
    await gate.waitUntilEntered()
    await store.send(.close) {
      $0.child = nil
      $0.trace.append("close")
    }
    #expect(!task.isFinished)
    await gate.open()
    await scoped.receive(.finishParent) { $0.completed = 1 }
    await task.finish()
    #expect(!cancelled.withLock { $0 })
    #expect(store.state.completed == 1)
    await store.finish()
  }
}

extension OwnedSynchronousEffectConsistencyTests {
  @Test(arguments: [false, true])
  func observationCancellationPreservesImmediateEmissionThenQueueDrop(managed: Bool) async {
    let gate = SynchronousEffectGate()
    let emissions = OSAllocatedUnfairLock<[SynchronousParentAction]>(initialState: [])
    let drops = OSAllocatedUnfairLock<[SynchronousParentAction?]>(initialState: [])
    let store = Store(
      reducer: SynchronousFeature(managed: managed, gate: gate, followupAfterCompletion: true),
      initialState: .init(),
      instrumentation: .init(
        didEmitAction: { event in emissions.withLock { $0.append(event.action) } },
        didDropAction: { event in drops.withLock { $0.append(event.action) } }))
    let task = store.send(.child(.handoff))
    await gate.waitUntilEntered()
    withObservationTracking {
      _ = store.state.completed
    } onChange: {
      task.cancel()
    }
    await gate.open()
    await task.finish()
    #expect(task.isCancelled)
    #expect(store.state.completed == 1)
    #expect(store.state.trace == ["start", "follow"])
    #expect(emissions.withLock { $0 } == [.child(.follow), .startParent, .finishParent, .tick])
    #expect(drops.withLock { $0 } == [.tick])
  }
}

extension OwnedSynchronousEffectConsistencyTests {
  @Test(arguments: [false, true])
  func childFollowupRunKeepsOwnerAndJoinsPhysicalCancellation(useTestStore: Bool) async {
    let gate = SynchronousEffectGate()
    let cancelled = OSAllocatedUnfairLock(initialState: false)
    let feature = SynchronousFeature(managed: true, gate: gate, cancellationObserved: cancelled)
    if useTestStore {
      let store = TestStore(reducer: feature, initialState: .init())
      let task = await store.send(.child(.startRun))
      #expect(!task.isFinished)
      await store.receive(.child(.run))
      await gate.waitUntilEntered()
      await store.send(.close) {
        $0.child = nil
        $0.trace.append("close")
      }
      #expect(await gate.cancellation.wait(timeout: .seconds(5)))
      #expect(!task.isFinished)
      await gate.open()
      await task.finish()
      #expect(cancelled.withLock { $0 })
      #expect(store.state.completed == 0)
      await store.finish()
    } else {
      let store = Store(reducer: feature, initialState: .init())
      let task = store.send(.child(.startRun))
      #expect(!task.isFinished)
      await gate.waitUntilEntered()
      store.send(.close)
      #expect(await gate.cancellation.wait(timeout: .seconds(5)))
      #expect(!task.isFinished)
      await gate.open()
      await task.finish()
      #expect(cancelled.withLock { $0 })
      #expect(store.state.completed == 0)
    }
  }
}
