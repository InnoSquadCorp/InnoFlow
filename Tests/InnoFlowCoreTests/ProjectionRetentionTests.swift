// MARK: - ProjectionRetentionTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import InnoFlowCore
import Observation
import Testing
import os

@testable import InnoFlowCoreTestSupport

// Locks which read keeps a selection alive and which tracker notifies its
// reader:
// - a liveness read (`isAlive`) observes the owner's liveness and retains
//   nothing, so a selection that is also read for its value follows the value
//   rule, and a liveness reader is notified when the owner is deactivated even
//   after the selection was released: when the store is released, or when a
//   row's element is removed. A scope that is released without being
//   deactivated notifies no one, which no test here covers;
// - obtaining a closure-based selection from the `id:` cache records the same
//   read of the owner that creating one records, without reading the owner's
//   state, so a reducer can obtain one while its own store reduces, and its
//   reader is notified after the holder that created it lets go;
// - a reader that reads a handle it holds is notified through the selection
//   alone.

private let keyPathEvaluations = OSAllocatedUnfairLock(initialState: 0)

private struct RetentionRow: Equatable, Sendable, Identifiable {
  let id: Int
  var value = 0
}

private struct RetentionFeature: Reducer {
  struct State: Equatable, Sendable {
    var count = 0
    var other = 0
    var items: [Int] = []
    var rows = IdentifiedArray(uniqueElements: (0..<3).map { RetentionRow(id: $0) })
    var child = Child()

    struct Child: Equatable, Sendable {
      var number = 0
    }

    /// An element read whose evaluations are counted.
    subscript(counted index: Int) -> Int {
      keyPathEvaluations.withLock { $0 += 1 }
      return items[index]
    }
  }

  enum RowAction: Sendable {
    case increment
  }

  enum ChildAction: Sendable {
    case bump
  }

  enum Action: Sendable {
    case increment
    case touchOther
    case setItems([Int])
    case bumpItems
    case row(id: Int, action: RowAction)
    case remove(Int)
    case child(ChildAction)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .increment:
      state.count += 1
    case .touchOther:
      state.other += 1
    case .setItems(let items):
      state.items = items
    case .bumpItems:
      state.items = state.items.map { $0 + 1 }
    case .row(let id, .increment):
      state.rows[id: id]?.value += 1
    case .remove(let id):
      _ = state.rows.remove(id: id)
    case .child(.bump):
      state.child.number += 1
    }
    return .none
  }
}

private let retentionRowPath = CollectionActionPath<
  RetentionFeature.Action, Int, RetentionFeature.RowAction
>(
  embed: { .row(id: $0, action: $1) },
  extract: {
    guard case .row(let id, let action) = $0 else { return nil }
    return (id, action)
  }
)

private let retentionChildPath = CasePath<RetentionFeature.Action, RetentionFeature.ChildAction>(
  embed: { .child($0) },
  extract: {
    guard case .child(let action) = $0 else { return nil }
    return action
  }
)

/// `RetentionFeature` as a closure reducer that runs `read.body` while it
/// reduces `.touchOther`: inside the reduction, which holds exclusive access
/// to the store's state.
private typealias ReadingFeature = Reduce<
  RetentionFeature.State, RetentionFeature.Action, Never
>

@MainActor
private final class ReductionTimeRead {
  var body: (@MainActor () -> Void)?
}

private func reading(_ read: ReductionTimeRead) -> ReadingFeature {
  Reduce { state, action in
    if case .touchOther = action {
      MainActor.assumeIsolated { read.body?() }
    }
    return RetentionFeature().reduce(into: &state, action: action)
  }
}

/// One call site per kind, shared by the holder and the reader, like a helper
/// or a view that two places use.
@MainActor
private func sharedSelection<R: Reducer>(
  _ kind: ProjectionRetentionTests.SharedSelectionKind,
  of store: Store<R>
) -> SelectedStore<Int> where R.State == RetentionFeature.State {
  switch kind {
  case .dependingOn:
    store.select(dependingOn: \.count, id: "shared") { $0 * 2 }
  case .dependingOnAll:
    store.select(dependingOnAll: \.count, \.other, id: "shared") { count, _ in count * 2 }
  case .selector:
    store.select(id: "shared") { $0.count * 2 }
  case .memoizedSelector:
    store.select(id: "shared", memoize: true) { $0.count * 2 }
  }
}

@MainActor
private func sharedSelection<R: Reducer>(
  _ kind: ProjectionRetentionTests.SharedSelectionKind,
  of row: ScopedStore<R, RetentionRow, RetentionFeature.RowAction>
) -> SelectedStore<Int> {
  switch kind {
  case .dependingOn:
    row.select(dependingOn: \.value, id: "shared") { $0 * 2 }
  case .dependingOnAll:
    row.select(dependingOnAll: \.value, \.id, id: "shared") { value, _ in value * 2 }
  case .selector:
    row.select(id: "shared") { $0.value * 2 }
  case .memoizedSelector:
    row.select(id: "shared", memoize: true) { $0.value * 2 }
  }
}

@MainActor
@Suite("Projection retention follows value reads", .serialized, .timeLimit(.minutes(5)))
struct ProjectionRetentionTests {
  /// The closure-based selection kinds that accept a semantic `id:`.
  enum SharedSelectionKind: CaseIterable, Sendable {
    case dependingOn, dependingOnAll, selector, memoizedSelector
  }

  private func track(_ read: () -> Void) -> OSAllocatedUnfairLock<Int> {
    let notifications = OSAllocatedUnfairLock(initialState: 0)
    withObservationTracking(read) {
      notifications.withLock { $0 += 1 }
    }
    return notifications
  }

  // MARK: Liveness reads

  @Test("A selection read for its liveness and its value is released after two unread changes")
  func livenessAndValueReadFollowsTheValueRule() {
    let store = Store(reducer: RetentionFeature(), initialState: .init())
    weak var weakSelection: SelectedStore<Int>?
    let notifications: OSAllocatedUnfairLock<Int>
    do {
      let selection = store.select(\RetentionFeature.State.count)
      weakSelection = selection
      // The pattern `requireAlive()` documents for a caller that checks first.
      notifications = track {
        if selection.isAlive { _ = selection.requireAlive() }
      }
    }
    #expect(weakSelection != nil)

    store.send(.increment)
    #expect(notifications.withLock { $0 } == 1)
    #expect(weakSelection != nil)

    store.send(.increment)
    #expect(weakSelection == nil)
    #expect(store.projectionObserverStats.registeredObservers == 0)
  }

  @Test("A scoped selection read for its liveness and its value is released after two changes")
  func scopedLivenessAndValueReadFollowsTheValueRule() {
    let store = Store(reducer: RetentionFeature(), initialState: .init())
    let child = store.scope(state: \.child, action: retentionChildPath)
    weak var weakSelection: SelectedStore<Int>?
    let notifications: OSAllocatedUnfairLock<Int>
    do {
      let selection = child.select(\RetentionFeature.State.Child.number)
      weakSelection = selection
      notifications = track {
        if selection.isAlive { _ = selection.requireAlive() }
      }
    }

    child.send(.bump)
    #expect(notifications.withLock { $0 } == 1)
    #expect(weakSelection != nil)

    child.send(.bump)
    #expect(weakSelection == nil)
    #expect(child.projectionObserverStats.registeredObservers == 0)
  }

  @Test("Dynamic key-path selections read for liveness and value stop being evaluated")
  func dynamicKeyPathSelectionsReadForLivenessAreReleased() {
    let selectionCount = 64
    let store = Store(reducer: RetentionFeature(), initialState: .init())
    store.send(.setItems(Array(0..<selectionCount)))
    for index in 0..<selectionCount {
      // One call site with a dynamic key path, as a list body evaluates it.
      let selection = store.select(\RetentionFeature.State.[counted: index])
      _ = track {
        if selection.isAlive { _ = selection.requireAlive() }
      }
    }

    store.send(.bumpItems)
    store.send(.bumpItems)
    #expect(store.projectionObserverStats.registeredObservers == 0)

    keyPathEvaluations.withLock { $0 = 0 }
    store.send(.touchOther)
    #expect(keyPathEvaluations.withLock { $0 } == 0)
  }

  @Test("A liveness read retains nothing and is notified when the store is released")
  func livenessReadIsNotifiedByTheReleasedStore() {
    var store: Store<RetentionFeature>? = Store(reducer: RetentionFeature(), initialState: .init())
    weak var weakSelection: SelectedStore<Int>?
    let notifications = track {
      let selection = store!.select(\RetentionFeature.State.count)
      weakSelection = selection
      _ = selection.isAlive
    }
    #expect(weakSelection == nil)

    store!.send(.increment)
    #expect(notifications.withLock { $0 } == 0)

    store = nil
    #expect(notifications.withLock { $0 } == 1)
  }

  @Test("A liveness read of a row selection retains nothing and is notified when the row goes")
  func rowLivenessReadIsNotifiedByTheRemovedRow() {
    let store = Store(reducer: RetentionFeature(), initialState: .init())
    let row = store.scope(collection: \.rows, action: retentionRowPath)[1]
    weak var weakSelection: SelectedStore<Int>?
    let notifications = track {
      let selection = row.select(\RetentionRow.value)
      weakSelection = selection
      _ = selection.isAlive
    }
    #expect(weakSelection == nil)

    store.send(.row(id: 1, action: .increment))
    store.send(.remove(0))
    #expect(notifications.withLock { $0 } == 0)

    store.send(.remove(1))
    #expect(notifications.withLock { $0 } == 1)
    #expect(row.isAlive == false)
  }

  @Test("A liveness reader of a held selection is notified once when the store is released")
  func livenessReaderOfAHeldSelectionIsNotifiedOnce() {
    var store: Store<RetentionFeature>? = Store(reducer: RetentionFeature(), initialState: .init())
    let selection = store!.select(\RetentionFeature.State.count)
    let notifications = track { _ = selection.isAlive }

    store!.send(.increment)
    #expect(notifications.withLock { $0 } == 0)
    #expect(selection.requireAlive() == 1)

    store = nil
    #expect(notifications.withLock { $0 } == 1)
    #expect(selection.isAlive == false)
    #expect(selection.optionalValue == nil)
  }

  @Test("A liveness reader of a removed row is not notified again when the store is released")
  func removedRowLivenessReaderIsNotNotifiedByTheStoreRelease() {
    var store: Store<RetentionFeature>? = Store(reducer: RetentionFeature(), initialState: .init())
    let row = store!.scope(collection: \.rows, action: retentionRowPath)[1]
    let selection = row.select(\RetentionRow.value)
    store!.send(.remove(1))
    #expect(row.isAlive == false)

    let rowNotifications = track { _ = row.isAlive }
    let selectionNotifications = track { _ = selection.isAlive }
    store = nil
    #expect(rowNotifications.withLock { $0 } == 0)
    #expect(selectionNotifications.withLock { $0 } == 0)
  }

  // MARK: Semantic-ID cache hits

  @Test(
    "A reader of another holder's id: selection is notified after the holder lets go",
    arguments: SharedSelectionKind.allCases
  )
  func readerOfASharedSelectionIsNotifiedByTheStore(kind: SharedSelectionKind) {
    let store = Store(reducer: RetentionFeature(), initialState: .init())
    var holder: SelectedStore<Int>? = sharedSelection(kind, of: store)
    let notifications = track {
      let shared = sharedSelection(kind, of: store)
      #expect(shared === holder)
      #expect(shared.requireAlive() == 0)
    }
    weak let weakHolder = holder
    holder = nil
    #expect(weakHolder == nil)

    store.send(.increment)
    #expect(notifications.withLock { $0 } == 1)
  }

  @Test(
    "A reader of another holder's id: row selection is notified after the holder lets go",
    arguments: SharedSelectionKind.allCases
  )
  func readerOfASharedRowSelectionIsNotifiedByTheRow(kind: SharedSelectionKind) {
    let store = Store(reducer: RetentionFeature(), initialState: .init())
    let row = store.scope(collection: \.rows, action: retentionRowPath)[0]
    var holder: SelectedStore<Int>? = sharedSelection(kind, of: row)
    let notifications = track {
      let shared = sharedSelection(kind, of: row)
      #expect(shared === holder)
      #expect(shared.requireAlive() == 0)
    }
    weak let weakHolder = holder
    holder = nil
    #expect(weakHolder == nil)

    store.send(.row(id: 0, action: .increment))
    #expect(notifications.withLock { $0 } == 1)
    withExtendedLifetime(row) {}
  }

  @Test(
    "A reducer gets another holder's id: selection while its own store reduces",
    arguments: SharedSelectionKind.allCases, [false, true]
  )
  func sharedSelectionObtainedWhileTheStoreReduces(kind: SharedSelectionKind, onRow: Bool) {
    let read = ReductionTimeRead()
    let store = Store(reducer: reading(read), initialState: .init())
    let row = store.scope(collection: \.rows, action: retentionRowPath)[0]
    var holder: SelectedStore<Int>? =
      onRow ? sharedSelection(kind, of: row) : sharedSelection(kind, of: store)
    let heldID = holder.map(ObjectIdentifier.init)
    let obtainedID = OSAllocatedUnfairLock<ObjectIdentifier?>(initialState: nil)
    let notifications = OSAllocatedUnfairLock(initialState: 0)
    read.body = { [weak store, weak row] in
      guard let store, let row else { return }
      withObservationTracking {
        let shared = onRow ? sharedSelection(kind, of: row) : sharedSelection(kind, of: store)
        obtainedID.withLock { $0 = ObjectIdentifier(shared) }
        _ = shared.requireAlive()
      } onChange: {
        notifications.withLock { $0 += 1 }
      }
    }
    // `.touchOther` leaves the selected value unchanged.
    store.send(.touchOther)
    read.body = nil
    #expect(obtainedID.withLock { $0 } == heldID)
    #expect(notifications.withLock { $0 } == 0)

    weak let weakHolder = holder
    holder = nil
    #expect(weakHolder == nil)
    store.send(onRow ? .row(id: 0, action: .increment) : .increment)
    #expect(notifications.withLock { $0 } == 1)
  }

  @Test("Control: a reader of an id: selection it holds is notified through the selection alone")
  func readerOfAHeldSharedSelectionIsNotified() {
    let store = Store(reducer: RetentionFeature(), initialState: .init())
    let holder = sharedSelection(.dependingOn, of: store)
    // The held handle is read, not obtained again: no read of the store's
    // state is recorded.
    let notifications = track { _ = holder.requireAlive() }

    // `.touchOther` leaves the selected value unchanged.
    store.send(.touchOther)
    #expect(notifications.withLock { $0 } == 0)

    store.send(.increment)
    #expect(notifications.withLock { $0 } == 1)
    #expect(holder.requireAlive() == 2)
  }
}
