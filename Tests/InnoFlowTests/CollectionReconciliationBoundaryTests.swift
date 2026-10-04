import InnoFlowCore
import InnoFlowTesting
import Testing
import os

private final class ReconciliationReads: Sendable {
  private let value = OSAllocatedUnfairLock(initialState: 0)
  func record() { value.withLock { $0 += 1 } }
  func reset() { value.withLock { $0 = 0 } }
  var count: Int { value.withLock { $0 } }
}

private struct ReconciliationChild: Equatable, Sendable { var generation: Int }
private struct ReconciliationRow: Equatable, Identifiable, Sendable {
  let id: Int
  var child: ReconciliationChild?
}
private struct ReconciliationRows: MutableCollection, RandomAccessCollection, Equatable, Sendable {
  var elements: [ReconciliationRow]
  let reads: ReconciliationReads
  var startIndex: Int { elements.startIndex }
  var endIndex: Int { elements.endIndex }
  func index(after i: Int) -> Int { i + 1 }
  func index(before i: Int) -> Int { i - 1 }
  subscript(i: Int) -> ReconciliationRow {
    get {
      reads.record()
      return elements[i]
    }
    set { elements[i] = newValue }
  }
  static func == (lhs: Self, rhs: Self) -> Bool { lhs.elements == rhs.elements }
}
private struct ReconciliationState: Equatable, Sendable {
  var rows: ReconciliationRows
  var ticks = 0
  var generation = 0
}
private enum ReconciliationAction: Sendable {
  case install([Int])
  case tick, removeAll, replaceFirst, reverse
  case row(Int, Void)
}
private func reconciliationReducer() -> Reduce<ReconciliationState, ReconciliationAction, Never> {
  let row = Reduce<ReconciliationRow, Void, Never> { _, _ in .none }
    .optionalChild(
      state: \.child, action: CasePath<Void, Void>(embed: { $0 }, extract: { $0 }),
      instanceID: { $0.generation },
      reducer: Reduce<ReconciliationChild, Void, Never> { _, _ in .none })
  let collection = ForEachReducer(
    state: \ReconciliationState.rows,
    action: CollectionActionPath<ReconciliationAction, Int, Void>(
      embed: { .row($0, $1) },
      extract: { if case .row(let id, let value) = $0 { (id, value) } else { nil } }),
    reducer: row)
  return Reduce { state, action in
    switch action {
    case .install(let ids):
      return .merge(ids.map { collection.reduce(into: &state, action: .row($0, ())) })
    case .tick: state.ticks += 1
    case .removeAll: state.rows.elements.removeAll()
    case .replaceFirst: state.rows.elements[0].child = .init(generation: 10001)
    case .reverse: state.rows.elements.reverse()
    case .row: return collection.reduce(into: &state, action: action)
    }
    return .none
  }
}

@MainActor private final class ReconciliationHost {
  let live: Store<Reduce<ReconciliationState, ReconciliationAction, Never>>?
  let testing: TestStore<Reduce<ReconciliationState, ReconciliationAction, Never>>?
  init(testing: Bool, rows: [ReconciliationRow], reads: ReconciliationReads) {
    let initial = ReconciliationState(rows: .init(elements: rows, reads: reads))
    if testing {
      live = nil
      let host = TestStore(reducer: reconciliationReducer(), initialState: initial)
      host.exhaustivity = .off
      self.testing = host
    } else {
      live = Store(reducer: reconciliationReducer(), initialState: initial)
      self.testing = nil
    }
  }
  var ownerCount: Int {
    live?.effectBridge.childLifetimeRegistry.activeOwnerCount
      ?? testing!.childLifetimeRegistry.activeOwnerCount
  }
  func send(_ action: ReconciliationAction) async {
    if let live { await live.send(action).finish() } else { await testing!.send(action) }
  }
  func finish() async { if let testing { await testing.finish() } }
}

@Suite("Collection reconciliation boundaries")
@MainActor struct CollectionReconciliationBoundaryTests {
  @Test(arguments: [false, true], [1, 32, 128, 512, 1_000])
  func denseOwnersPreserveLifetimeAcrossActions(testing: Bool, count: Int) async {
    let reads = ReconciliationReads()
    let host = ReconciliationHost(
      testing: testing,
      rows: (0..<count).map {
        .init(id: $0, child: .init(generation: $0))
      }, reads: reads)
    await host.send(.install(Array(0..<count)))
    #expect(host.ownerCount == count)
    await host.send(.tick)
    await host.send(.reverse)
    #expect(host.ownerCount == count)
    await host.send(.replaceFirst)
    #expect(host.ownerCount == count - 1)
    await host.send(.row(count - 1, ()))
    #expect(host.ownerCount == count)
    await host.send(.removeAll)
    #expect(host.ownerCount == 0)
    await host.finish()
  }

  @Test(
    arguments: [false, true], [[Int](), [0], [500], [999], [0, 142, 285, 428, 571, 714, 857, 999]])
  func sparseOwnersKeepDirectFirstLookup(testing: Bool, ids: [Int]) async {
    let reads = ReconciliationReads()
    let host = ReconciliationHost(
      testing: testing,
      rows: (0..<1_000).map {
        .init(id: $0, child: .init(generation: $0))
      }, reads: reads)
    await host.send(.install(ids))
    #expect(host.ownerCount == ids.count)
    reads.reset()
    await host.send(.tick)
    #expect(reads.count == ids.reduce(0) { $0 + $1 + 1 })
    await host.send(.removeAll)
    #expect(host.ownerCount == 0)
    await host.finish()
  }

  @Test(arguments: [false, true])
  func denseDuplicatesUseFirstIdentityAndRecheckReplacement(testing: Bool) async {
    let host = ReconciliationHost(
      testing: testing,
      rows: [
        .init(id: 0, child: .init(generation: 10)),
        .init(id: 0, child: .init(generation: 20)),
        .init(id: 1, child: .init(generation: 30)),
      ], reads: .init())
    await host.send(.install([0, 1]))
    #expect(host.ownerCount == 2)
    await host.send(.tick)
    #expect(host.ownerCount == 2)
    await host.send(.replaceFirst)
    #expect(host.ownerCount == 1)
    await host.send(.row(0, ()))
    #expect(host.ownerCount == 2)
    await host.send(.reverse)
    #expect(host.ownerCount == 1)
    await host.send(.removeAll)
    #expect(host.ownerCount == 0)
    await host.finish()
  }
}

private struct ReconciliationPair: Equatable, Sendable {
  var left: ReconciliationState
  var right: ReconciliationState
}
private enum ReconciliationPairAction: Sendable {
  case left(ReconciliationAction)
  case right(ReconciliationAction)
  case removeLeft
}
extension CollectionReconciliationBoundaryTests {
  @Test(arguments: [false, true])
  func denseSiblingCollectionsWithEqualIDsHaveDistinctIndexes(testing: Bool) async {
    let reducer = CombineReducers {
      Scope(
        state: \ReconciliationPair.left,
        action: CasePath<ReconciliationPairAction, ReconciliationAction>(
          embed: { .left($0) }, extract: { if case .left(let value) = $0 { value } else { nil } }),
        reducer: reconciliationReducer())
      Scope(
        state: \ReconciliationPair.right,
        action: CasePath<ReconciliationPairAction, ReconciliationAction>(
          embed: { .right($0) }, extract: { if case .right(let value) = $0 { value } else { nil } }),
        reducer: reconciliationReducer())
      Reduce<ReconciliationPair, ReconciliationPairAction, Never> { state, action in
        if case .removeLeft = action { state.left.rows.elements.removeAll() }
        return .none
      }
    }
    let initial = ReconciliationPair(
      left: .init(
        rows: .init(
          elements: (0..<2).map { .init(id: $0, child: .init(generation: $0)) }, reads: .init())),
      right: .init(
        rows: .init(
          elements: (0..<2).map { .init(id: $0, child: .init(generation: $0 + 10)) }, reads: .init()
        )))
    if testing {
      let store = TestStore(reducer: reducer, initialState: initial)
      store.exhaustivity = .off
      await store.send(.left(.install([0, 1])))
      await store.send(.right(.install([0, 1])))
      #expect(store.childLifetimeRegistry.activeOwnerCount == 4)
      await store.send(.left(.tick))
      #expect(store.childLifetimeRegistry.activeOwnerCount == 4)
      await store.send(.removeLeft)
      #expect(store.childLifetimeRegistry.activeOwnerCount == 2)
      await store.send(.right(.removeAll))
      #expect(store.childLifetimeRegistry.activeOwnerCount == 0)
      await store.finish()
    } else {
      let store = Store(reducer: reducer, initialState: initial)
      await store.send(.left(.install([0, 1]))).finish()
      await store.send(.right(.install([0, 1]))).finish()
      #expect(store.effectBridge.childLifetimeRegistry.activeOwnerCount == 4)
      await store.send(.left(.tick)).finish()
      #expect(store.effectBridge.childLifetimeRegistry.activeOwnerCount == 4)
      await store.send(.removeLeft).finish()
      #expect(store.effectBridge.childLifetimeRegistry.activeOwnerCount == 2)
      await store.send(.right(.removeAll)).finish()
      #expect(store.effectBridge.childLifetimeRegistry.activeOwnerCount == 0)
    }
  }
}

private struct ReconciliationOptionalPair: Equatable, Sendable {
  var left: ReconciliationState?
  var right: ReconciliationState?
}
extension CollectionReconciliationBoundaryTests {
  @Test(arguments: [false, true])
  func equalRelativeCollectionPathsUnderDistinctParentOwnersStaySeparate(testing: Bool) async {
    let reducer = Reduce<ReconciliationOptionalPair, ReconciliationPairAction, Never> {
      state, action in
      if case .removeLeft = action { state.left = nil }
      return .none
    }.optionalChild(
      state: \.left,
      action: CasePath(
        embed: ReconciliationPairAction.left,
        extract: { if case .left(let value) = $0 { value } else { nil } }),
      instanceID: { $0.generation }, reducer: reconciliationReducer()
    ).optionalChild(
      state: \.right,
      action: CasePath(
        embed: ReconciliationPairAction.right,
        extract: { if case .right(let value) = $0 { value } else { nil } }),
      instanceID: { $0.generation }, reducer: reconciliationReducer())
    let initial = ReconciliationOptionalPair(
      left: .init(
        rows: .init(
          elements: (0..<2).map { .init(id: $0, child: .init(generation: $0)) }, reads: .init())),
      right: .init(
        rows: .init(
          elements: (0..<2).map { .init(id: $0, child: .init(generation: $0 + 10)) }, reads: .init()
        )))
    if testing {
      let store = TestStore(reducer: reducer, initialState: initial)
      store.exhaustivity = .off
      await store.send(.left(.install([0, 1])))
      await store.send(.right(.install([0, 1])))
      #expect(store.childLifetimeRegistry.activeOwnerCount == 6)
      await store.send(.left(.tick))
      #expect(store.childLifetimeRegistry.activeOwnerCount == 6)
      await store.send(.removeLeft)
      #expect(store.childLifetimeRegistry.activeOwnerCount == 3)
      await store.send(.right(.replaceFirst))
      #expect(store.childLifetimeRegistry.activeOwnerCount == 2)
      await store.send(.right(.removeAll))
      #expect(store.childLifetimeRegistry.activeOwnerCount == 1)
      await store.finish()
    } else {
      let store = Store(reducer: reducer, initialState: initial)
      await store.send(.left(.install([0, 1]))).finish()
      await store.send(.right(.install([0, 1]))).finish()
      #expect(store.effectBridge.childLifetimeRegistry.activeOwnerCount == 6)
      await store.send(.left(.tick)).finish()
      #expect(store.effectBridge.childLifetimeRegistry.activeOwnerCount == 6)
      await store.send(.removeLeft).finish()
      #expect(store.effectBridge.childLifetimeRegistry.activeOwnerCount == 3)
      await store.send(.right(.replaceFirst)).finish()
      #expect(store.effectBridge.childLifetimeRegistry.activeOwnerCount == 2)
      await store.send(.right(.removeAll)).finish()
      #expect(store.effectBridge.childLifetimeRegistry.activeOwnerCount == 1)
    }
  }
}
