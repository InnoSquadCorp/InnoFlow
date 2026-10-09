import InnoFlowCore
import InnoFlowTesting
import Testing
import os

private final class GroupReadCounter: Sendable {
  private let storage = OSAllocatedUnfairLock(initialState: 0)
  func record() { storage.withLock { $0 += 1 } }
  func reset() { storage.withLock { $0 = 0 } }
  var count: Int { storage.withLock { $0 } }
}
private actor GroupLifetimeGate {
  private var entered = false
  private var opened = false
  private var starts: [CheckedContinuation<Void, Never>] = []
  private var releases: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    entered = true
    for start in starts { start.resume() }
    starts.removeAll()
    if !opened { await withCheckedContinuation { releases.append($0) } }
  }
  func waitUntilEntered() async {
    if !entered { await withCheckedContinuation { starts.append($0) } }
  }
  func open() {
    opened = true
    for release in releases { release.resume() }
    releases.removeAll()
  }
}
private struct GroupLifetimeChild: Equatable, Sendable {
  var generation: Int
  var received: [Int] = []
}
private struct GroupLifetimeRow: Equatable, Identifiable, Sendable {
  let id: Int
  var child: GroupLifetimeChild?
  var other: GroupLifetimeChild?
}
private struct GroupLifetimeRows: Equatable, MutableCollection, RandomAccessCollection, Sendable {
  var elements: [GroupLifetimeRow]
  let reads = GroupReadCounter()
  var startIndex: Int { elements.startIndex }
  var endIndex: Int { elements.endIndex }
  func index(after index: Int) -> Int { index + 1 }
  func index(before index: Int) -> Int { index - 1 }
  subscript(index: Int) -> GroupLifetimeRow {
    get {
      reads.record()
      return elements[index]
    }
    set { elements[index] = newValue }
  }
  static func == (lhs: Self, rhs: Self) -> Bool { lhs.elements == rhs.elements }
}
private struct GroupLifetimeState: Equatable, Sendable { var rows: GroupLifetimeRows }
private struct GroupLifetimeRoot: Equatable, Sendable {
  var groups: [GroupLifetimeState]
  var ticks = 0
}
private enum GroupChildAction: Equatable, Sendable {
  case install
  case start(Int)
  case done(Int)
}
private enum GroupLifetimeAction: Equatable, Sendable {
  case install([Int])
  case row(Int, GroupChildAction)
}
private enum GroupRootAction: Equatable, Sendable {
  case install([Int])
  case tick
  case group(Int, GroupLifetimeAction)
  case clear(Int)
  case replace(Int, Int, Int)
  case reverse(Int)
  case restore(Int)
}
private func groupLifetimeReducer(gates: [GroupLifetimeGate])
  -> Reduce<GroupLifetimeState, GroupLifetimeAction, Never>
{
  let child = Reduce<GroupLifetimeChild, GroupChildAction, Never> { state, action in
    switch action {
    case .install: return .none
    case .start(let index):
      return .run { send in
        await gates[index].wait()
        await send(.done(index))
      }
    case .done(let index):
      state.received.append(index)
      return .none
    }
  }
  let identity = CasePath<GroupChildAction, GroupChildAction>(embed: { $0 }, extract: { $0 })
  let row = Reduce<GroupLifetimeRow, GroupChildAction, Never> { _, _ in .none }
    .optionalChild(state: \.child, action: identity, instanceID: { $0.generation }, reducer: child)
    .optionalChild(state: \.other, action: identity, instanceID: { $0.generation }, reducer: child)
  let route = ForEachReducer(
    state: \GroupLifetimeState.rows,
    action: CollectionActionPath<GroupLifetimeAction, Int, GroupChildAction>(
      embed: { .row($0, $1) },
      extract: { if case .row(let id, let value) = $0 { (id, value) } else { nil } }),
    reducer: row)
  return Reduce { state, action in
    if case .install(let ids) = action {
      return .merge(ids.map { route.reduce(into: &state, action: .row($0, .install)) })
    }
    return route.reduce(into: &state, action: action)
  }
}
private func groupRootReducer(groupCount: Int, gates: [GroupLifetimeGate])
  -> Reduce<GroupLifetimeRoot, GroupRootAction, Never>
{
  let scopes = (0..<groupCount).map { index in
    Scope(
      state: \GroupLifetimeRoot.groups[index],
      action: CasePath<GroupRootAction, GroupLifetimeAction>(
        embed: { .group(index, $0) },
        extract: {
          if case .group(let group, let value) = $0, group == index { value } else { nil }
        }),
      reducer: groupLifetimeReducer(gates: gates))
  }
  return Reduce { state, action in
    switch action {
    case .install(let ids):
      return .merge(
        scopes.enumerated().map { index, scope in
          scope.reduce(into: &state, action: .group(index, .install(ids)))
        })
    case .tick: state.ticks += 1
    case .group(let group, _): return scopes[group].reduce(into: &state, action: action)
    case .clear(let group): state.groups[group].rows.elements.removeAll()
    case .replace(let group, let id, let generation):
      let index = state.groups[group].rows.elements.firstIndex { $0.id == id }!
      state.groups[group].rows.elements[index].child = .init(generation: generation)
    case .reverse(let group): state.groups[group].rows.elements.reverse()
    case .restore(let group):
      state.groups[group].rows.elements = (0..<2).map {
        .init(id: $0, child: .init(generation: 100_000 + group * 2 + $0))
      }
    }
    return .none
  }
}
private func groupInitialState(groupCount: Int, rowCount: Int, duplicateSlots: Bool)
  -> GroupLifetimeRoot
{
  .init(
    groups: (0..<groupCount).map { group in
      .init(
        rows: .init(
          elements: (0..<rowCount).map { row in
            let child = GroupLifetimeChild(generation: group * rowCount + row)
            return .init(id: row, child: child, other: duplicateSlots ? child : nil)
          }))
    })
}
@MainActor private final class GroupLifetimeHost {
  let live: Store<Reduce<GroupLifetimeRoot, GroupRootAction, Never>>?
  let testing: TestStore<Reduce<GroupLifetimeRoot, GroupRootAction, Never>>?
  private var tasks: [FlowTask] = []
  init(
    testing: Bool, groups: Int, rows: Int = 2, duplicateSlots: Bool = false,
    gates: [GroupLifetimeGate] = []
  ) {
    let initial = groupInitialState(
      groupCount: groups, rowCount: rows, duplicateSlots: duplicateSlots)
    let reducer = groupRootReducer(groupCount: groups, gates: gates)
    if testing {
      live = nil
      let store = TestStore(reducer: reducer, initialState: initial)
      store.exhaustivity = .off
      self.testing = store
    } else {
      live = Store(reducer: reducer, initialState: initial)
      self.testing = nil
    }
  }
  var state: GroupLifetimeRoot { live?.state ?? testing!.state }
  var owners: Int {
    live?.effectBridge.childLifetimeRegistry.activeOwnerCount
      ?? testing!.childLifetimeRegistry.activeOwnerCount
  }
  @discardableResult func send(_ action: GroupRootAction) async -> FlowTask {
    let task =
      if let live { live.send(action) } else { await testing!.send(action).flowTaskReference }
    tasks.append(task)
    return task
  }
  func receive(_ action: GroupRootAction) async { if let testing { await testing.receive(action) } }
  func finish() async {
    if let testing { await testing.finish() } else { for task in tasks { await task.finish() } }
  }
}

@Suite("Collection reconciliation across direct scopes")
@MainActor struct CollectionMultiScopeReconciliationTests {
  @Test(arguments: [false, true], [1, 8, 32, 128])
  func denseDirectScopesPreserveOwnerLifetimes(testing: Bool, groups: Int) async {
    let host = GroupLifetimeHost(testing: testing, groups: groups)
    await host.send(.install([0, 1]))
    #expect(host.owners == groups * 2)
    await host.send(.tick)
    await host.send(.reverse(0))
    #expect(host.owners == groups * 2)
    await host.send(.replace(0, 0, 100_000))
    #expect(host.owners == groups * 2 - 1)
    await host.send(.clear(groups - 1))
    #expect(host.owners == (groups == 1 ? 0 : groups * 2 - 3))
    await host.send(.restore(0))
    await host.send(.group(0, .install([0, 1])))
    #expect(host.owners == (groups == 1 ? 2 : groups * 2 - 2))
    await host.finish()
  }

  @Test(arguments: [false, true], [1, 8, 32, 128])
  func singletonScopesNeedNoIndexAndPreserveReplacement(testing: Bool, groups: Int) async {
    let host = GroupLifetimeHost(testing: testing, groups: groups, rows: 1)
    await host.send(.install([0]))
    #expect(host.owners == groups)
    for group in host.state.groups { group.rows.reads.reset() }
    await host.send(.tick)
    #expect(host.state.groups.reduce(0) { $0 + $1.rows.reads.count } == groups)
    await host.send(.replace(groups - 1, 0, 100_000))
    #expect(host.owners == groups - 1)
    await host.send(.group(groups - 1, .install([0])))
    #expect(host.owners == groups)
    await host.finish()
  }

  @Test(arguments: [false, true])
  func duplicateSlotsDoNotInflateCollectionDensity(testing: Bool) async {
    let groups = 8
    let host = GroupLifetimeHost(testing: testing, groups: groups, rows: 3, duplicateSlots: true)
    await host.send(.install([0]))
    #expect(host.owners == groups * 2)
    for group in host.state.groups { group.rows.reads.reset() }
    await host.send(.tick)
    // One addressed element per collection stays sparse even with two slots.
    #expect(host.state.groups.reduce(0) { $0 + $1.rows.reads.count } == groups * 2)
    await host.send(.clear(0))
    #expect(host.owners == (groups - 1) * 2)
    await host.finish()
  }

  @Test(arguments: [false, true])
  func removingOneDenseScopeJoinsItsPhysicalWorkAndPreservesOthers(testing: Bool) async {
    let gates = [GroupLifetimeGate(), GroupLifetimeGate()]
    let host = GroupLifetimeHost(testing: testing, groups: 8, gates: gates)
    await host.send(.install([0, 1]))
    let removed = await host.send(.group(0, .row(0, .start(0))))
    let sibling = await host.send(.group(7, .row(1, .start(1))))
    for gate in gates { await gate.waitUntilEntered() }
    await host.send(.clear(0))
    #expect(host.owners == 14)
    #expect(!removed.isFinished && !sibling.isFinished)
    await gates[1].open()
    await host.receive(.group(7, .row(1, .done(1))))
    await sibling.finish()
    #expect(host.state.groups[7].rows.elements[1].child?.received == [1])
    #expect(!removed.isFinished)
    await gates[0].open()
    await host.finish()
    #expect(removed.isFinished)
    #expect(host.state.groups[0].rows.elements.isEmpty)
  }
}
