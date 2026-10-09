import Foundation
import InnoFlowCore
import InnoFlowTesting
import Testing

private actor LifetimeGate {
  private var entered = false
  private var opened = false
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    entered = true
    for waiter in entryWaiters { waiter.resume() }
    entryWaiters.removeAll()
    guard !opened else { return }
    await withCheckedContinuation { releaseWaiters.append($0) }
  }
  func waitUntilEntered() async {
    guard !entered else { return }
    await withCheckedContinuation { entryWaiters.append($0) }
  }
  func open() {
    opened = true
    for waiter in releaseWaiters { waiter.resume() }
    releaseWaiters.removeAll()
  }
}

private struct LifetimeChildState: Equatable, Sendable {
  var instance = 1
  var businessID = 42
  var values: [Int] = []
}
private enum LifetimeChildAction: Equatable, Sendable {
  case start(Int)
  case scheduled(Int)
  case done(Int)
  case emitAndClose, cancel
}
private struct LifetimeParentState: Equatable, Sendable {
  var left: LifetimeChildState? = .init()
  var right: LifetimeChildState? = .init()
  var parentValues: [Int] = []
}
private enum LifetimeParentAction: Equatable, Sendable {
  case left(LifetimeChildAction)
  case right(LifetimeChildAction)
  case closeLeft
  case openLeft(Int)
  case replaceLeft(Int)
  case parentDone(Int)
}
private let lifetimeLeftPath = CasePath<LifetimeParentAction, LifetimeChildAction>(
  embed: { .left($0) }, extract: { if case .left(let action) = $0 { action } else { nil } }
)
private let lifetimeRightPath = CasePath<LifetimeParentAction, LifetimeChildAction>(
  embed: { .right($0) }, extract: { if case .right(let action) = $0 { action } else { nil } }
)

private func lifetimeReducer(
  gates: [LifetimeGate], parentWork: Bool = false
) -> some Reducer<LifetimeParentState, LifetimeParentAction, String> {
  let child = Reduce<LifetimeChildState, LifetimeChildAction, String> { state, action in
    switch action {
    case .start(let index):
      return .run { send in
        await gates[index].wait()
        await send(.done(index))
      }.cancellable(EffectID("shared"))
    case .scheduled(let index):
      return .run(id: EffectID("shared"), policy: .dropWhileRunning) { send, _ in
        await gates[index].wait()
        await send(.done(index))
      }
    case .done(let index):
      state.values.append(index)
      return .output("child-\(index)")
    case .emitAndClose:
      return .output("stale-child")
    case .cancel:
      return .cancel(EffectID("shared"))
    }
  }
  return Reduce<LifetimeParentState, LifetimeParentAction, String> { state, action in
    switch action {
    case .closeLeft, .left(.emitAndClose):
      state.left = nil
      return .output("parent-close")
    case .openLeft(let instance), .replaceLeft(let instance):
      state.left = .init(instance: instance)
    case .parentDone(let index):
      state.parentValues.append(index)
      return .output("parent-\(index)")
    case .left(.start(0)) where parentWork:
      return .run { send in
        await gates[2].wait()
        await send(.parentDone(2))
      }
    default:
      break
    }
    return .none
  }
  .optionalChild(
    state: \.left, action: lifetimeLeftPath, instanceID: { $0.instance }, reducer: child
  )
  .optionalChild(
    state: \.right, action: lifetimeRightPath, instanceID: { $0.instance }, reducer: child)
}

@Suite("Optional child lifetime consistency")
@MainActor
struct OptionalChildLifetimeConsistencyTests {
  @Test func sameReductionChildOutputIsSuppressedButParentOutputSurvives() async {
    let store = Store(reducer: lifetimeReducer(gates: []), initialState: .init())
    let task = store.send(.left(.emitAndClose), capturingOutputs: .unbounded)
    await task.finish()
    var outputs: [String] = []
    for await output in task.outputs { outputs.append(output) }
    #expect(outputs == ["parent-close"])
    #expect(store.state.left == nil)
    #expect(store.effectBridge.childLifetimeRegistry.activeOwnerCount == 1)
  }

  @Test func testStoreSameReductionChildOutputIsSuppressed() async {
    let store = TestStore(reducer: lifetimeReducer(gates: []), initialState: .init())
    await store.send(.left(.emitAndClose)) { $0.left = nil }
    await store.receiveOutput("parent-close")
    await store.finish()
    #expect(store.childLifetimeRegistry.activeOwnerCount == 1)
  }

  @Test func closeKeepsSameDispatchParentAndSiblingAliveAndJoinsPhysicalChild() async {
    let gates = (0..<3).map { _ in LifetimeGate() }
    let store = Store(
      reducer: lifetimeReducer(gates: gates, parentWork: true), initialState: .init())
    let left = store.send(.left(.start(0)), capturingOutputs: .unbounded)
    let right = store.send(.right(.start(1)), capturingOutputs: .unbounded)
    await gates[0].waitUntilEntered()
    await gates[1].waitUntilEntered()
    await gates[2].waitUntilEntered()
    await store.send(.closeLeft).finish()
    #expect(!left.isFinished)
    #expect(!right.isFinished)
    await gates[2].open()
    await gates[1].open()
    await right.finish()
    #expect(store.state.right?.values == [1])
    #expect(!left.isFinished)
    await gates[0].open()
    await left.finish()
    var outputs: [String] = []
    for await output in left.outputs { outputs.append(output) }
    #expect(outputs == ["parent-2"])
    #expect(store.state.parentValues == [2])
    #expect(store.state.left == nil)
  }

  @Test func testStoreClosePreservesSiblingAndDropsLateAction() async {
    let gates = (0..<2).map { _ in LifetimeGate() }
    let store = TestStore(reducer: lifetimeReducer(gates: gates), initialState: .init())
    let left = await store.send(.left(.start(0)))
    let right = await store.send(.right(.start(1)))
    await gates[0].waitUntilEntered()
    await gates[1].waitUntilEntered()
    await store.send(.closeLeft) { $0.left = nil }
    await store.receiveOutput("parent-close")
    #expect(!left.isFinished)
    await gates[0].open()
    await left.finish()
    await gates[1].open()
    await store.receive(.right(.done(1))) { $0.right?.values = [1] }
    await store.receiveOutput("child-1")
    await right.finish()
    await store.finish()
  }

  @Test func replaceAndReopenSameBusinessIDDropsOldInstanceEvents() async {
    let gates = (0..<2).map { _ in LifetimeGate() }
    let store = Store(reducer: lifetimeReducer(gates: gates), initialState: .init())
    let old = store.send(.left(.start(0)))
    await gates[0].waitUntilEntered()
    await store.send(.replaceLeft(2)).finish()
    let fresh = store.send(.left(.start(1)))
    await gates[1].waitUntilEntered()
    await gates[0].open()
    await old.finish()
    #expect(store.state.left?.values == [])
    #expect(store.state.left?.businessID == 42)
    await gates[1].open()
    await fresh.finish()
    #expect(store.state.left?.values == [1])
  }

  @Test func retainingInstanceIDKeepsLifetimeDespitePayloadReplacement() async {
    let gate = LifetimeGate()
    let store = Store(reducer: lifetimeReducer(gates: [gate]), initialState: .init())
    let task = store.send(.left(.start(0)))
    await gate.waitUntilEntered()
    await store.send(.replaceLeft(1)).finish()
    await gate.open()
    await task.finish()
    #expect(store.state.left?.values == [0])
  }

  @Test func sameRawSchedulerIDIsIsolatedBySiblingAndStore() async {
    let gates = (0..<3).map { _ in LifetimeGate() }
    let first = Store(reducer: lifetimeReducer(gates: gates), initialState: .init())
    let second = Store(reducer: lifetimeReducer(gates: gates), initialState: .init())
    let left = first.send(.left(.scheduled(0)))
    let right = first.send(.right(.scheduled(1)))
    let other = second.send(.left(.scheduled(2)))
    await gates[0].waitUntilEntered()
    await gates[1].waitUntilEntered()
    await gates[2].waitUntilEntered()
    await first.send(.closeLeft).finish()
    await gates[0].open()
    await gates[1].open()
    await gates[2].open()
    await left.finish()
    await right.finish()
    await other.finish()
    #expect(first.state.right?.values == [1])
    #expect(second.state.left?.values == [2])
    #expect(first.effectBridge.runScheduler.activeRequestCount == 0)
  }

  @Test func rawCancellationOutsideChildDoesNotCancelItsNamespacedWork() async {
    let gate = LifetimeGate()
    let store = Store(reducer: lifetimeReducer(gates: [gate]), initialState: .init())
    let task = store.send(.left(.start(0)))
    await gate.waitUntilEntered()
    await store.cancelEffects(identifiedBy: EffectID("shared"))
    await gate.open()
    await task.finish()
    #expect(store.state.left?.values == [0])
  }

  @Test func repeatedCloseReopenReleasesActiveRegistrations() async {
    let store = Store(
      reducer: lifetimeReducer(gates: []), initialState: .init(left: nil, right: nil))
    for instance in 0..<1_000 {
      await store.send(.openLeft(instance)).finish()
      #expect(store.effectBridge.childLifetimeRegistry.activeOwnerCount == 1)
      await store.send(.closeLeft).finish()
      #expect(store.effectBridge.childLifetimeRegistry.activeOwnerCount == 0)
    }
  }
}

private struct LifetimeMiddleState: Equatable, Sendable {
  var instance = 1
  var child: LifetimeChildState? = .init()
  var values: [Int] = []
}
private enum LifetimeMiddleAction: Equatable, Sendable {
  case child(LifetimeChildAction)
  case start, done, closeChild
}
private struct LifetimeOuterState: Equatable, Sendable {
  var middle: LifetimeMiddleState? = .init()
}
private enum LifetimeOuterAction: Equatable, Sendable {
  case middle(LifetimeMiddleAction)
  case closeMiddle
}
private let lifetimeMiddlePath = CasePath<LifetimeOuterAction, LifetimeMiddleAction>(
  embed: { .middle($0) }, extract: { if case .middle(let action) = $0 { action } else { nil } }
)
private let lifetimeNestedPath = CasePath<LifetimeMiddleAction, LifetimeChildAction>(
  embed: { .child($0) }, extract: { if case .child(let action) = $0 { action } else { nil } }
)
private func nestedLifetimeReducer(gates: [LifetimeGate])
  -> some Reducer<LifetimeOuterState, LifetimeOuterAction, Never>
{
  let child = Reduce<LifetimeChildState, LifetimeChildAction, Never> { state, action in
    switch action {
    case .scheduled(let index):
      return .run(id: EffectID("shared"), policy: .dropWhileRunning) { send, _ in
        await gates[index].wait()
        await send(.done(index))
      }
    case .done(let index):
      state.values.append(index)
    default: break
    }
    return .none
  }
  let middle = Reduce<LifetimeMiddleState, LifetimeMiddleAction, Never> { state, action in
    switch action {
    case .start:
      return .run(id: EffectID("shared"), policy: .dropWhileRunning) { send, _ in
        await gates[1].wait()
        await send(.done)
      }
    case .done:
      state.values.append(1)
    case .closeChild:
      state.child = nil
    default: break
    }
    return .none
  }
  .optionalChild(
    state: \.child, action: lifetimeNestedPath, instanceID: { $0.instance }, reducer: child)
  return Reduce<LifetimeOuterState, LifetimeOuterAction, Never> { state, action in
    if case .closeMiddle = action { state.middle = nil }
    return .none
  }
  .optionalChild(
    state: \.middle, action: lifetimeMiddlePath, instanceID: { $0.instance }, reducer: middle)
}

extension OptionalChildLifetimeConsistencyTests {
  @Test(arguments: [false, true])
  func nestedOwnerSameRawLaneAndInnerClosePreserveOuter(useTestStore: Bool) async {
    let gates = (0..<2).map { _ in LifetimeGate() }
    if useTestStore {
      let store = TestStore(reducer: nestedLifetimeReducer(gates: gates), initialState: .init())
      let inner = await store.send(.middle(.child(.scheduled(0))))
      let outer = await store.send(.middle(.start))
      await gates[0].waitUntilEntered()
      await gates[1].waitUntilEntered()
      #expect(store.childLifetimeRegistry.activeOwnerCount == 2)
      await store.send(.middle(.closeChild)) { $0.middle?.child = nil }
      #expect(store.childLifetimeRegistry.activeOwnerCount == 1)
      #expect(!inner.isFinished)
      await gates[0].open()
      await inner.finish()
      await gates[1].open()
      await store.receive(.middle(.done)) { $0.middle?.values = [1] }
      await outer.finish()
      await store.send(.closeMiddle) { $0.middle = nil }
      #expect(store.childLifetimeRegistry.activeOwnerCount == 0)
      await store.finish()
    } else {
      let store = Store(reducer: nestedLifetimeReducer(gates: gates), initialState: .init())
      let inner = store.send(.middle(.child(.scheduled(0))))
      let outer = store.send(.middle(.start))
      await gates[0].waitUntilEntered()
      await gates[1].waitUntilEntered()
      #expect(store.effectBridge.childLifetimeRegistry.activeOwnerCount == 2)
      await store.send(.middle(.closeChild)).finish()
      #expect(store.effectBridge.childLifetimeRegistry.activeOwnerCount == 1)
      #expect(!inner.isFinished)
      await gates[0].open()
      await inner.finish()
      await gates[1].open()
      await outer.finish()
      #expect(store.state.middle?.values == [1])
      await store.send(.closeMiddle).finish()
      #expect(store.effectBridge.childLifetimeRegistry.activeOwnerCount == 0)
    }
  }

  @Test(arguments: [false, true])
  func outerCloseInvalidatesAllNestedWork(useTestStore: Bool) async {
    let gates = (0..<2).map { _ in LifetimeGate() }
    if useTestStore {
      let store = TestStore(reducer: nestedLifetimeReducer(gates: gates), initialState: .init())
      let inner = await store.send(.middle(.child(.scheduled(0))))
      let outer = await store.send(.middle(.start))
      await gates[0].waitUntilEntered()
      await gates[1].waitUntilEntered()
      await store.send(.closeMiddle) { $0.middle = nil }
      #expect(store.childLifetimeRegistry.activeOwnerCount == 0)
      #expect(!inner.isFinished && !outer.isFinished)
      await gates[0].open()
      await gates[1].open()
      await inner.finish()
      await outer.finish()
      await store.finish()
    } else {
      let store = Store(reducer: nestedLifetimeReducer(gates: gates), initialState: .init())
      let inner = store.send(.middle(.child(.scheduled(0))))
      let outer = store.send(.middle(.start))
      await gates[0].waitUntilEntered()
      await gates[1].waitUntilEntered()
      await store.send(.closeMiddle).finish()
      #expect(store.effectBridge.childLifetimeRegistry.activeOwnerCount == 0)
      #expect(!inner.isFinished && !outer.isFinished)
      await gates[0].open()
      await gates[1].open()
      await inner.finish()
      await outer.finish()
      #expect(store.state.middle == nil)
    }
  }

  @Test func legacyIfLetKeepsItsExistingLifetimeBehavior() async {
    let gate = LifetimeGate()
    let child = Reduce<LifetimeChildState, LifetimeChildAction, Never> { state, action in
      switch action {
      case .start:
        return .run { send in
          await gate.wait()
          await send(.done(0))
        }
      case .done:
        state.values.append(0)
      default: break
      }
      return .none
    }
    let reducer = CombineReducers {
      IfLet(
        state: \LifetimeParentState.left, action: lifetimeLeftPath, reducer: child,
        onMissing: .ignore)
      Reduce<LifetimeParentState, LifetimeParentAction, Never> { state, action in
        if case .closeLeft = action { state.left = nil }
        if case .left(.done(let value)) = action { state.parentValues.append(value) }
        return .none
      }
    }
    let store = Store(reducer: reducer, initialState: .init())
    let task = store.send(.left(.start(0)))
    await gate.waitUntilEntered()
    await store.send(.closeLeft).finish()
    await gate.open()
    await task.finish()
    #expect(store.state.left == nil)
    #expect(store.state.parentValues == [0])
  }
}

private struct LifetimePairState: Equatable, Sendable {
  var first = LifetimeParentState(right: nil)
  var second = LifetimeParentState(right: nil)
}
private enum LifetimePairAction: Equatable, Sendable {
  case first(LifetimeParentAction)
  case second(LifetimeParentAction)
}
private func pairedLifetimeReducer(gates: [LifetimeGate])
  -> some Reducer<LifetimePairState, LifetimePairAction, String>
{
  let child = lifetimeReducer(gates: gates)
  return CombineReducers<LifetimePairState, LifetimePairAction, String> {
    Scope(
      state: \.first,
      action: CasePath(
        embed: { .first($0) },
        extract: { if case .first(let action) = $0 { action } else { nil } }
      ), reducer: child)
    Scope(
      state: \.second,
      action: CasePath(
        embed: { .second($0) },
        extract: { if case .second(let action) = $0 { action } else { nil } }
      ), reducer: child)
  }
}

extension OptionalChildLifetimeConsistencyTests {
  @Test(arguments: [false, true])
  func reusedReducerInDifferentScopesHasIndependentLifetimes(useTestStore: Bool) async {
    let gates = (0..<2).map { _ in LifetimeGate() }
    if useTestStore {
      let store = TestStore(reducer: pairedLifetimeReducer(gates: gates), initialState: .init())
      let first = await store.send(.first(.left(.scheduled(0))))
      let second = await store.send(.second(.left(.scheduled(1))))
      await gates[0].waitUntilEntered()
      await gates[1].waitUntilEntered()
      #expect(store.childLifetimeRegistry.activeOwnerCount == 2)
      await store.send(.first(.closeLeft)) { $0.first.left = nil }
      await store.receiveOutput("parent-close")
      #expect(store.childLifetimeRegistry.activeOwnerCount == 1)
      await gates[0].open()
      await first.finish()
      await gates[1].open()
      await store.receive(.second(.left(.done(1)))) { $0.second.left?.values = [1] }
      await store.receiveOutput("child-1")
      await second.finish()
      await store.finish()
    } else {
      let store = Store(reducer: pairedLifetimeReducer(gates: gates), initialState: .init())
      let first = store.send(.first(.left(.scheduled(0))))
      let second = store.send(.second(.left(.scheduled(1))))
      await gates[0].waitUntilEntered()
      await gates[1].waitUntilEntered()
      #expect(store.effectBridge.childLifetimeRegistry.activeOwnerCount == 2)
      await store.send(.first(.closeLeft)).finish()
      #expect(store.effectBridge.childLifetimeRegistry.activeOwnerCount == 1)
      await gates[0].open()
      await first.finish()
      await gates[1].open()
      await second.finish()
      #expect(store.state.second.left?.values == [1])
    }
  }
}
