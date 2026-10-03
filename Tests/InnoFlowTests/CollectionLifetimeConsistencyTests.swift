import Foundation
import InnoFlowCore
import InnoFlowTesting
import Testing

private actor CollectionLifetimeGate {
  private var entered = false
  private var opened = false
  private var entries: [CheckedContinuation<Void, Never>] = []
  private var releases: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    entered = true
    for entry in entries { entry.resume() }
    entries.removeAll()
    guard !opened else { return }
    await withCheckedContinuation { releases.append($0) }
  }

  func waitUntilEntered() async {
    guard !entered else { return }
    await withCheckedContinuation { entries.append($0) }
  }

  func open() {
    opened = true
    for release in releases { release.resume() }
    releases.removeAll()
  }
}

private actor CollectionLifetimeAdmissions {
  private var values: [EffectAdmission] = []
  private var waiter: CheckedContinuation<[EffectAdmission], Never>?

  func record(_ admission: EffectAdmission) {
    values.append(admission)
    if values.count == 2 {
      waiter?.resume(returning: values)
      waiter = nil
    }
  }

  func pair() async -> [EffectAdmission] {
    if values.count == 2 { return values }
    return await withCheckedContinuation { waiter = $0 }
  }
}

private struct CollectionLifetimeChild: Equatable, Sendable {
  var instance: Int
  var received: [Int] = []
}

private struct CollectionLifetimeRow: Equatable, Identifiable, Sendable {
  let id: Int
  var child: CollectionLifetimeChild?
}

private struct CollectionLifetimeState: Equatable, Sendable {
  var rows: [CollectionLifetimeRow]
  var identified: IdentifiedArray<Int, CollectionLifetimeRow>
  var parentReceived: [Int] = []

  init(equalInstances: Bool) {
    let values = [
      CollectionLifetimeRow(id: 0, child: .init(instance: 10)),
      CollectionLifetimeRow(id: 1, child: .init(instance: equalInstances ? 10 : 20)),
    ]
    rows = values
    identified = .init(uniqueElements: values, id: { $0.id })
  }

  mutating func set(_ row: CollectionLifetimeRow?, id: Int, useIdentified: Bool) {
    if useIdentified {
      identified[id: id] = row
    } else if let index = rows.firstIndex(where: { $0.id == id }) {
      if let row { rows[index] = row } else { rows.remove(at: index) }
    } else if let row {
      rows.append(row)
    }
  }

  func row(_ id: Int, useIdentified: Bool) -> CollectionLifetimeRow? {
    useIdentified ? identified[id: id] : rows.first { $0.id == id }
  }
}

private enum CollectionLifetimeChildAction: Equatable, Sendable {
  case start(Int)
  case scheduled(Int)
  case done(Int)
  case admission, emit
}

private enum CollectionLifetimeRowAction: Equatable, Sendable {
  case child(CollectionLifetimeChildAction)
  case close, parentDone
}

private enum CollectionLifetimeAction: Equatable, Sendable {
  case row(Int, CollectionLifetimeRowAction)
  case replace(Int)
  case remove
  case insert(Int)
  case rootDone, reorder
}

private let collectionLifetimeActionPath = CollectionActionPath<
  CollectionLifetimeAction, Int, CollectionLifetimeRowAction
>(
  embed: { .row($0, $1) },
  extract: { if case .row(let id, let action) = $0 { (id, action) } else { nil } }
)

private func collectionLifetimeReducer(
  useIdentified: Bool, gates: [CollectionLifetimeGate],
  admissions: CollectionLifetimeAdmissions? = nil
) -> Reduce<CollectionLifetimeState, CollectionLifetimeAction, String> {
  let child = Reduce<CollectionLifetimeChild, CollectionLifetimeChildAction, String> {
    state, action in
    switch action {
    case .start(let index):
      return .run { send in
        await gates[index].wait()
        await send(.done(index))
      }.cancellable(EffectID("same-child-work"))
    case .scheduled(let index):
      return .run(
        id: EffectID("same-child-work"), policy: .dropWhileRunning,
        onAdmission: { admission in
          Task { await admissions?.record(admission) }
          return .admission
        }
      ) { send, _ in
        await gates[index].wait()
        await send(.done(index))
      }
    case .done(let value):
      state.received.append(value)
    case .emit:
      return .output("stale-child")
    case .admission:
      break
    }
    return .none
  }
  let row = Reduce<CollectionLifetimeRow, CollectionLifetimeRowAction, String> { state, action in
    switch action {
    case .close:
      state.child = nil
    case .child(.start(0)):
      return .run { send in
        await gates[2].wait()
        await send(.parentDone)
      }
    default:
      break
    }
    return .none
  }.optionalChild(
    state: \.child,
    action: CasePath(
      embed: { .child($0) },
      extract: { if case .child(let action) = $0 { action } else { nil } }),
    instanceID: { $0.instance }, child: child)
  let array = ForEachReducer(
    state: \CollectionLifetimeState.rows, action: collectionLifetimeActionPath, reducer: row)
  let identified = ForEachIdentifiedReducer(
    state: \CollectionLifetimeState.identified, action: collectionLifetimeActionPath, reducer: row)
  let reducer = CombineReducers<CollectionLifetimeState, CollectionLifetimeAction, String> {
    Reduce { state, action in
      if useIdentified { return identified.reduce(into: &state, action: action) }
      return array.reduce(into: &state, action: action)
    }
    Reduce { state, action in
      switch action {
      case .replace(let instance), .insert(let instance):
        state.set(
          .init(id: 0, child: .init(instance: instance)), id: 0, useIdentified: useIdentified)
      case .remove, .row(0, .child(.emit)):
        state.set(nil, id: 0, useIdentified: useIdentified)
        return .output("parent-remove")
      case .row(0, .child(.start(0))):
        return .run { send in
          await gates[3].wait()
          await send(.rootDone)
        }
      case .reorder:
        state.rows.reverse()
        state.identified = .init(uniqueElements: state.identified.values.reversed(), id: { $0.id })
      case .row(0, .parentDone):
        state.parentReceived.append(2)
      case .rootDone:
        state.parentReceived.append(3)
      default:
        break
      }
      return .none
    }
  }
  return Reduce { state, action in reducer.reduce(into: &state, action: action) }
}

@MainActor
private final class CollectionLifetimeHost {
  typealias R = Reduce<CollectionLifetimeState, CollectionLifetimeAction, String>
  private let live: Store<R>?
  private let testing: TestStore<R>?
  private var tasks: [FlowTask] = []

  init(useTestStore: Bool, reducer: R, state: CollectionLifetimeState) {
    if useTestStore {
      live = nil
      let store = TestStore(reducer: reducer, initialState: state)
      store.exhaustivity = .off
      testing = store
    } else {
      live = Store(reducer: reducer, initialState: state)
      testing = nil
    }
  }

  var state: CollectionLifetimeState { live?.state ?? testing!.state }
  var ownerCount: Int {
    live?.effectBridge.childLifetimeRegistry.activeOwnerCount
      ?? testing!.childLifetimeRegistry.activeOwnerCount
  }

  @discardableResult
  func send(_ action: CollectionLifetimeAction) async -> FlowTask {
    let task: FlowTask
    if let live {
      task = live.send(action)
    } else {
      task = await testing!.send(action).flowTaskReference
    }
    tasks.append(task)
    return task
  }

  func finish() async {
    if let testing { await testing.finish() } else { for task in tasks { await task.finish() } }
  }
}

enum CollectionLifetimeMutation: CaseIterable, Sendable {
  case close, replace, removeAndReenter
}

@Suite("Collection optional child lifetime consistency")
@MainActor
struct CollectionLifetimeConsistencyTests {
  @Test(
    arguments: [false, true].flatMap { host in
      [false, true].flatMap { identified in
        [false, true].flatMap { equal in
          CollectionLifetimeMutation.allCases.map { (host, identified, equal, $0) }
        }
      }
    })
  func rowsOwnIndependentLifetimes(
    useTestStore: Bool, useIdentified: Bool, equalInstances: Bool,
    mutation: CollectionLifetimeMutation
  ) async {
    let gates = (0..<5).map { _ in CollectionLifetimeGate() }
    let host = CollectionLifetimeHost(
      useTestStore: useTestStore,
      reducer: collectionLifetimeReducer(useIdentified: useIdentified, gates: gates),
      state: .init(equalInstances: equalInstances))
    let first = await host.send(.row(0, .child(.start(0))))
    await gates[0].waitUntilEntered()
    await gates[2].waitUntilEntered()
    await gates[3].waitUntilEntered()
    let sibling = await host.send(.row(1, .child(.start(1))))
    await gates[1].waitUntilEntered()
    #expect(host.ownerCount == 2)
    switch mutation {
    case .close:
      await host.send(.row(0, .close))
    case .replace:
      await host.send(.replace(30))
    case .removeAndReenter:
      await host.send(.remove)
    }
    #expect(host.ownerCount == 1)
    #expect(!first.isFinished && !sibling.isFinished)
    if case .removeAndReenter = mutation {
      // The same collection ID is reused, while the child gets a fresh instance.
      await host.send(.insert(30))
    }
    if mutation != .close {
      await host.send(.row(0, .child(.start(4))))
      await gates[4].waitUntilEntered()
      #expect(host.ownerCount == 2)
    }
    for gate in gates { await gate.open() }
    await host.finish()
    #expect(host.state.row(1, useIdentified: useIdentified)?.child?.received == [1])
    #expect(host.state.parentReceived.sorted() == [2, 3])
    if mutation == .close {
      #expect(host.state.row(0, useIdentified: useIdentified)?.child == nil)
    } else {
      #expect(host.state.row(0, useIdentified: useIdentified)?.child?.received == [4])
    }
    await host.send(.row(0, .close))
    await host.send(.row(1, .close))
    #expect(host.ownerCount == 0)
    await host.finish()
  }

  @Test(
    arguments: [false, true].flatMap { host in
      [false, true].flatMap { identified in
        [false, true].map { (host, identified, $0) }
      }
    })
  func equalRawSchedulerIDsHaveSeparateRowLanes(
    useTestStore: Bool, useIdentified: Bool, equalInstances: Bool
  ) async {
    let gates = (0..<2).map { _ in CollectionLifetimeGate() }
    let admissions = CollectionLifetimeAdmissions()
    let host = CollectionLifetimeHost(
      useTestStore: useTestStore,
      reducer: collectionLifetimeReducer(
        useIdentified: useIdentified, gates: gates, admissions: admissions),
      state: .init(equalInstances: equalInstances))
    await host.send(.row(0, .child(.scheduled(0))))
    await gates[0].waitUntilEntered()
    await host.send(.row(1, .child(.scheduled(1))))
    let outcomes = await admissions.pair()
    #expect(outcomes == [.started, .started])
    #expect(host.ownerCount == 2)
    await host.send(.row(0, .close))
    for gate in gates { await gate.open() }
    await host.finish()
    #expect(host.state.row(1, useIdentified: useIdentified)?.child?.received == [1])
  }

  @Test(arguments: [false, true], [false, true])
  func parentRemovalSuppressesSameReductionChildOutput(
    useTestStore: Bool, useIdentified: Bool
  ) async {
    let reducer = collectionLifetimeReducer(useIdentified: useIdentified, gates: [])
    if useTestStore {
      let store = TestStore(reducer: reducer, initialState: .init(equalInstances: true))
      await store.send(.row(0, .child(.emit))) {
        $0.set(nil, id: 0, useIdentified: useIdentified)
      }
      await store.receiveOutput("parent-remove")
      #expect(store.childLifetimeRegistry.activeOwnerCount == 0)
      await store.finish()
    } else {
      let store = Store(reducer: reducer, initialState: .init(equalInstances: true))
      let task = store.send(.row(0, .child(.emit)), capturingOutputs: .unbounded)
      await task.finish()
      var outputs: [String] = []
      for await output in task.outputs { outputs.append(output) }
      #expect(outputs == ["parent-remove"])
      #expect(store.effectBridge.childLifetimeRegistry.activeOwnerCount == 0)
    }
  }
}

private enum CollectionLifetimeSelection: Equatable, Sendable {
  case active(CollectionLifetimeState)
  case inactive
}

private struct CollectionLifetimeEnvelope: Equatable, Sendable {
  var selection: CollectionLifetimeSelection
}

private enum CollectionLifetimeEnvelopeAction: Equatable, Sendable {
  case child(CollectionLifetimeAction)
  case close
}

private let collectionLifetimeSelectionPath = CasePath<
  CollectionLifetimeSelection, CollectionLifetimeState
>(
  embed: { .active($0) },
  extract: { if case .active(let state) = $0 { state } else { nil } }
)

private func collectionLifetimeEnvelopeReducer(
  useIdentified: Bool, gates: [CollectionLifetimeGate]
) -> some Reducer<CollectionLifetimeEnvelope, CollectionLifetimeEnvelopeAction, String> {
  let collection = collectionLifetimeReducer(useIdentified: useIdentified, gates: gates)
  let selected = IfCaseLet(
    state: CasePath<CollectionLifetimeSelection, CollectionLifetimeState>(
      embed: { .active($0) },
      extract: { if case .active(let state) = $0 { state } else { nil } }),
    action: CasePath<CollectionLifetimeAction, CollectionLifetimeAction>(
      embed: { $0 }, extract: { $0 }),
    reducer: collection, onMissing: .ignore)
  return CombineReducers {
    Scope(
      state: \CollectionLifetimeEnvelope.selection,
      action: CasePath<CollectionLifetimeEnvelopeAction, CollectionLifetimeAction>(
        embed: { .child($0) },
        extract: { if case .child(let action) = $0 { action } else { nil } }),
      reducer: selected)
    Reduce<CollectionLifetimeEnvelope, CollectionLifetimeEnvelopeAction, String> { state, action in
      if case .close = action { state.selection = .inactive }
      return .none
    }
  }
}

extension CollectionLifetimeConsistencyTests {
  @Test(arguments: [false, true], [false, true])
  func collectionInsideScopeAndCaseClosesAtFinalParentState(
    useTestStore: Bool, useIdentified: Bool
  ) async {
    let gates = (0..<2).map { _ in CollectionLifetimeGate() }
    let reducer = collectionLifetimeEnvelopeReducer(useIdentified: useIdentified, gates: gates)
    let initial = CollectionLifetimeEnvelope(selection: .active(.init(equalInstances: true)))
    if useTestStore {
      let store = TestStore(reducer: reducer, initialState: initial)
      let task = await store.send(.child(.row(1, .child(.start(1)))))
      await gates[1].waitUntilEntered()
      #expect(store.childLifetimeRegistry.activeOwnerCount == 1)
      await store.send(.close) { $0.selection = .inactive }
      #expect(store.childLifetimeRegistry.activeOwnerCount == 0)
      #expect(!task.isFinished)
      await gates[1].open()
      await task.finish()
      await store.finish()
    } else {
      let store = Store(reducer: reducer, initialState: initial)
      let task = store.send(.child(.row(1, .child(.start(1)))))
      await gates[1].waitUntilEntered()
      #expect(store.effectBridge.childLifetimeRegistry.activeOwnerCount == 1)
      await store.send(.close).finish()
      #expect(store.effectBridge.childLifetimeRegistry.activeOwnerCount == 0)
      #expect(!task.isFinished)
      await gates[1].open()
      await task.finish()
      #expect(store.state.selection == .inactive)
    }
  }
}

extension CollectionLifetimeConsistencyTests {
  @Test(arguments: [false, true], [false, true])
  func reorderingPreservesElementOwner(useTestStore: Bool, useIdentified: Bool) async {
    let gates = (0..<2).map { _ in CollectionLifetimeGate() }
    let host = CollectionLifetimeHost(
      useTestStore: useTestStore,
      reducer: collectionLifetimeReducer(useIdentified: useIdentified, gates: gates),
      state: .init(equalInstances: true))
    await host.send(.row(1, .child(.start(1))))
    await gates[1].waitUntilEntered()
    await host.send(.reorder)
    #expect(host.ownerCount == 1)
    await gates[1].open()
    await host.finish()
    #expect(host.state.row(1, useIdentified: useIdentified)?.child?.received == [1])
  }

  @Test(arguments: [false, true], [false, true])
  func repeatedParentRemovalReleasesRegistrations(useTestStore: Bool, useIdentified: Bool) async {
    let host = CollectionLifetimeHost(
      useTestStore: useTestStore,
      reducer: collectionLifetimeReducer(useIdentified: useIdentified, gates: []),
      state: .init(equalInstances: true))
    for instance in 0..<100 {
      await host.send(.insert(instance))
      await host.send(.row(0, .child(.admission)))
      #expect(host.ownerCount == 1)
      await host.send(.remove)
      #expect(host.ownerCount == 0)
    }
    await host.finish()
  }
}

private struct CollectionLifetimeOptionalEnvelope: Equatable, Sendable {
  var selection: CollectionLifetimeState?
}

extension CollectionLifetimeConsistencyTests {
  @Test(arguments: [false, true], [false, true])
  func collectionInsideIfLetReconcilesOptionalParent(
    useTestStore: Bool, useIdentified: Bool
  ) async {
    let gates = (0..<2).map { _ in CollectionLifetimeGate() }
    let reducer = CombineReducers {
      IfLet(
        state: \CollectionLifetimeOptionalEnvelope.selection,
        action: CasePath<CollectionLifetimeEnvelopeAction, CollectionLifetimeAction>(
          embed: { .child($0) },
          extract: { if case .child(let action) = $0 { action } else { nil } }),
        reducer: collectionLifetimeReducer(useIdentified: useIdentified, gates: gates),
        onMissing: .ignore)
      Reduce<CollectionLifetimeOptionalEnvelope, CollectionLifetimeEnvelopeAction, String> {
        state, action in
        if case .close = action { state.selection = nil }
        return .none
      }
    }
    let initial = CollectionLifetimeOptionalEnvelope(selection: .init(equalInstances: true))
    if useTestStore {
      let store = TestStore(reducer: reducer, initialState: initial)
      let task = await store.send(.child(.row(1, .child(.start(1)))))
      await gates[1].waitUntilEntered()
      #expect(store.childLifetimeRegistry.activeOwnerCount == 1)
      await store.send(.close) { $0.selection = nil }
      #expect(store.childLifetimeRegistry.activeOwnerCount == 0)
      #expect(!task.isFinished)
      await gates[1].open()
      await task.finish()
      await store.finish()
    } else {
      let store = Store(reducer: reducer, initialState: initial)
      let task = store.send(.child(.row(1, .child(.start(1)))))
      await gates[1].waitUntilEntered()
      #expect(store.effectBridge.childLifetimeRegistry.activeOwnerCount == 1)
      await store.send(.close).finish()
      #expect(store.effectBridge.childLifetimeRegistry.activeOwnerCount == 0)
      #expect(!task.isFinished)
      await gates[1].open()
      await task.finish()
    }
  }
}

extension CollectionLifetimeConsistencyTests {
  @Test(arguments: [false, true], [false, true])
  func reconstructedCasePathKeepsOneStructuralOwner(
    useTestStore: Bool, useIdentified: Bool
  ) async {
    // Model a computed body that constructs fresh manual CasePaths on each call.
    let reducer = Reduce<CollectionLifetimeEnvelope, CollectionLifetimeEnvelopeAction, String> {
      state, action in
      collectionLifetimeEnvelopeReducer(useIdentified: useIdentified, gates: [])
        .reduce(into: &state, action: action)
    }
    let initial = CollectionLifetimeEnvelope(selection: .active(.init(equalInstances: true)))
    if useTestStore {
      let store = TestStore(reducer: reducer, initialState: initial)
      for _ in 0..<100 {
        await store.send(.child(.row(1, .child(.admission))))
        #expect(store.childLifetimeRegistry.activeOwnerCount == 1)
      }
      await store.send(.close) { $0.selection = .inactive }
      #expect(store.childLifetimeRegistry.activeOwnerCount == 0)
      await store.finish()
    } else {
      let store = Store(reducer: reducer, initialState: initial)
      for _ in 0..<100 {
        await store.send(.child(.row(1, .child(.admission)))).finish()
        #expect(store.effectBridge.childLifetimeRegistry.activeOwnerCount == 1)
      }
      await store.send(.close).finish()
      #expect(store.effectBridge.childLifetimeRegistry.activeOwnerCount == 0)
    }
  }
}

private enum CollectionLifetimeOverlapAction: Equatable, Sendable {
  case first(CollectionLifetimeAction)
  case second(CollectionLifetimeAction)
  case close
}

private func overlappingLifetimeCase(
  path: CasePath<CollectionLifetimeOverlapAction, CollectionLifetimeAction>,
  lifetimeID: String, useIdentified: Bool, gates: [CollectionLifetimeGate],
  admissions: CollectionLifetimeAdmissions
) -> some Reducer<CollectionLifetimeSelection, CollectionLifetimeOverlapAction, String> {
  IfCaseLet(
    state: CasePath<CollectionLifetimeSelection, CollectionLifetimeState>(
      embed: { .active($0) },
      extract: { if case .active(let state) = $0 { state } else { nil } }),
    action: path,
    reducer: collectionLifetimeReducer(
      useIdentified: useIdentified, gates: gates, admissions: admissions),
    onMissing: .ignore,
    lifetimeID: EffectID(lifetimeID))
}

extension CollectionLifetimeConsistencyTests {
  @Test(arguments: [false, true], [false, true])
  func explicitHelperIdentitiesIsolateOverlappingCasePaths(
    useTestStore: Bool, useIdentified: Bool
  ) async {
    let gates = (0..<2).map { _ in CollectionLifetimeGate() }
    let admissions = CollectionLifetimeAdmissions()
    let reducer = Reduce<CollectionLifetimeSelection, CollectionLifetimeOverlapAction, String> {
      state, action in
      // Both custom paths deliberately match the same state. Rebuild the helper
      // at one declaration while explicit IDs preserve distinct namespaces.
      let combined = CombineReducers {
        overlappingLifetimeCase(
          path: CasePath(
            embed: { .first($0) },
            extract: { if case .first(let value) = $0 { value } else { nil } }),
          lifetimeID: "first", useIdentified: useIdentified, gates: gates, admissions: admissions)
        overlappingLifetimeCase(
          path: CasePath(
            embed: { .second($0) },
            extract: { if case .second(let value) = $0 { value } else { nil } }),
          lifetimeID: "second", useIdentified: useIdentified, gates: gates, admissions: admissions)
        Reduce<CollectionLifetimeSelection, CollectionLifetimeOverlapAction, String> {
          state, action in
          if case .close = action { state = .inactive }
          return .none
        }
      }
      return combined.reduce(into: &state, action: action)
    }
    if useTestStore {
      let store = TestStore(reducer: reducer, initialState: .active(.init(equalInstances: true)))
      store.exhaustivity = .off
      await store.send(.first(.row(1, .child(.scheduled(0)))))
      await gates[0].waitUntilEntered()
      await store.send(.second(.row(1, .child(.scheduled(1)))))
      #expect(await admissions.pair() == [.started, .started])
      #expect(store.childLifetimeRegistry.activeOwnerCount == 2)
      await store.send(.close)
      #expect(store.childLifetimeRegistry.activeOwnerCount == 0)
      for gate in gates { await gate.open() }
      await store.finish()
    } else {
      let store = Store(reducer: reducer, initialState: .active(.init(equalInstances: true)))
      let first = store.send(.first(.row(1, .child(.scheduled(0)))))
      await gates[0].waitUntilEntered()
      let second = store.send(.second(.row(1, .child(.scheduled(1)))))
      #expect(await admissions.pair() == [.started, .started])
      #expect(store.effectBridge.childLifetimeRegistry.activeOwnerCount == 2)
      await store.send(.close).finish()
      #expect(store.effectBridge.childLifetimeRegistry.activeOwnerCount == 0)
      for gate in gates { await gate.open() }
      await first.finish()
      await second.finish()
    }
  }
}
