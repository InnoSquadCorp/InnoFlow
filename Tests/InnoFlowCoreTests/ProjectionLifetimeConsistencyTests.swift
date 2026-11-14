// MARK: - ProjectionLifetimeConsistencyTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import InnoFlowCore
import Observation
import Testing
import os

// Locks three projection contracts:
// - a dependency bucket's change predicate is determined by its key, so a
//   collection scope and a key-path selection on the same key path cannot
//   override each other's comparison;
// - an owner keeps a key-path selection alive exactly while a tracked read
//   may still be waiting for its notification, and never evaluates a key path
//   on behalf of a selection that no longer exists;
// - the registry tolerates observers that register or disappear while a
//   refresh pass is delivering callbacks.

private struct LifetimeRow: Hashable, Sendable, Identifiable {
  var primary: Int
  var alternate: Int
  var title: String
  var id: Int { primary }
}

private let evaluationCounter = OSAllocatedUnfairLock(initialState: 0)

private struct LifetimeFeature: Reducer {
  struct State: Equatable, Sendable {
    var rows = IdentifiedArray<Int, LifetimeRow>(uniqueElements: [], id: { $0.primary })
    var items: [Int] = []
    var count = 0
    var unrelated = 0

    /// A dependency whose evaluation is observable without trapping.
    var countedCount: Int {
      evaluationCounter.withLock { $0 += 1 }
      return count
    }
  }

  enum RowAction: Sendable { case noop }

  enum Action: Sendable {
    case replaceRows(IdentifiedArray<Int, LifetimeRow>)
    case row(id: Int, action: RowAction)
    case increment
    case touchUnrelated
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .replaceRows(let rows):
      state.rows = rows
    case .row:
      break
    case .increment:
      state.count += 1
    case .touchUnrelated:
      state.unrelated += 1
    }
    return .none
  }
}

private let lifetimeRowPath = CollectionActionPath<
  LifetimeFeature.Action, Int, LifetimeFeature.RowAction
>(
  embed: { .row(id: $0, action: $1) },
  extract: {
    guard case .row(let id, let action) = $0 else { return nil }
    return (id, action)
  }
)

@MainActor
private final class ReentrantObserver: ProjectionObserver {
  private let onRefresh: @MainActor () -> Void
  private(set) var refreshCount = 0

  init(onRefresh: @escaping @MainActor () -> Void = {}) {
    self.onRefresh = onRefresh
  }

  func refreshFromParentStore() -> Bool {
    refreshCount += 1
    onRefresh()
    return false
  }
}

@MainActor
@Suite("Projection lifetime and dependency predicates", .serialized, .timeLimit(.minutes(5)))
struct ProjectionLifetimeConsistencyTests {
  // MARK: Dependency predicates

  /// Same element values, different stored IDs: only `IdentifiedArray`
  /// equality sees the change, the collection scope's row identity does not.
  private func idsSeenBySelection(collectionScopeFirst: Bool) -> [Int] {
    let rows = [LifetimeRow(primary: 1, alternate: 101, title: "same")]
    let original = IdentifiedArray(uniqueElements: rows, id: { $0.primary })
    let replacement = IdentifiedArray(uniqueElements: rows, id: { $0.alternate })
    let store = Store(reducer: LifetimeFeature(), initialState: .init(rows: original))

    var scopes: [ScopedStore<LifetimeFeature, LifetimeRow, LifetimeFeature.RowAction>] = []
    if collectionScopeFirst {
      scopes = store.scope(collection: \.rows, action: lifetimeRowPath)
      _ = scopes.first?.state
    }
    let selection = store.select(\LifetimeFeature.State.rows)
    #expect(Array(selection.requireAlive().ids) == [1])

    store.send(.replaceRows(replacement))
    #expect(Array(store.state.rows.ids) == [101])
    let seen = Array(selection.requireAlive().ids)
    withExtendedLifetime(scopes) {}
    return seen
  }

  @Test("Control: a key-path selection alone sees an identity-only replacement")
  func keyPathSelectionAloneSeesIdentityOnlyReplacement() {
    #expect(idsSeenBySelection(collectionScopeFirst: false) == [101])
  }

  @Test(
    "A key-path selection keeps its own predicate after a collection scope on the same key path")
  func keyPathSelectionAfterCollectionScopeSeesIdentityOnlyReplacement() {
    #expect(idsSeenBySelection(collectionScopeFirst: true) == [101])
  }

  // MARK: Selection lifetime

  @Test("A key-path selection that was never read is released with its last handle")
  func unreadKeyPathSelectionIsReleasedWithItsHandle() {
    let store = Store(reducer: LifetimeFeature(), initialState: .init())
    weak var weakSelection: SelectedStore<Int>?
    do {
      let selection = store.select(\LifetimeFeature.State.count)
      weakSelection = selection
    }

    #expect(weakSelection == nil)
    #expect(store.projectionObserverStats.registeredObservers == 0)
  }

  @Test("The owner never evaluates the key path of a released selection")
  func releasedSelectionKeyPathIsNotEvaluated() {
    let store = Store(reducer: LifetimeFeature(), initialState: .init())
    do { _ = store.select(\LifetimeFeature.State.countedCount) }
    let evaluationsAfterRelease = evaluationCounter.withLock { $0 }

    store.send(.increment)
    store.send(.touchUnrelated)

    #expect(evaluationCounter.withLock { $0 } == evaluationsAfterRelease)
  }

  @Test("Control: a retained key-path selection is evaluated and refreshed")
  func retainedSelectionKeyPathIsEvaluated() {
    let store = Store(reducer: LifetimeFeature(), initialState: .init())
    let selection = store.select(\LifetimeFeature.State.countedCount)
    let evaluationsAfterCreation = evaluationCounter.withLock { $0 }

    store.send(.increment)

    #expect(evaluationCounter.withLock { $0 } > evaluationsAfterCreation)
    #expect(selection.requireAlive() == 1)
  }

  @Test("A transient tracked read is notified even though the caller kept no handle")
  func transientTrackedReadIsNotified() {
    let store = Store(reducer: LifetimeFeature(), initialState: .init())
    let notificationCount = OSAllocatedUnfairLock(initialState: 0)

    withObservationTracking {
      _ = store.select(\LifetimeFeature.State.count).requireAlive()
    } onChange: {
      notificationCount.withLock { $0 += 1 }
    }
    store.send(.touchUnrelated)
    #expect(notificationCount.withLock { $0 } == 0)

    store.send(.increment)
    #expect(notificationCount.withLock { $0 } == 1)
  }

  @Test("A read selection keeps its identity for a reader that reads again after a notification")
  func rereadAfterNotificationKeepsIdentity() {
    let store = Store(reducer: LifetimeFeature(), initialState: .init())
    // One call site, and no reference that outlives a read: the owner alone
    // keeps the selection between reads. A weak reference proves the first
    // selection is still that object — comparing identifiers could match a
    // new object that reused a freed allocation.
    weak var firstSelection: SelectedStore<Int>?
    func transientRead() -> (isFirstSelection: Bool, value: Int) {
      let selection = store.select(\LifetimeFeature.State.count)
      if firstSelection == nil {
        firstSelection = selection
      }
      return (selection === firstSelection, selection.requireAlive())
    }

    let first = transientRead()
    store.send(.increment)
    #expect(firstSelection != nil)
    let second = transientRead()
    store.send(.increment)
    #expect(firstSelection != nil)
    let third = transientRead()

    #expect(first.value == 0)
    #expect(second.value == 1)
    #expect(third.value == 2)
    #expect(second.isFirstSelection)
    #expect(third.isFirstSelection)
  }

  @Test("A selection read only for liveness is still notified when its owner is released")
  func livenessOnlyReadIsNotifiedWhenTheOwnerIsReleased() {
    var store: Store<LifetimeFeature>? = Store(reducer: LifetimeFeature(), initialState: .init())
    let notificationCount = OSAllocatedUnfairLock(initialState: 0)
    withObservationTracking {
      _ = store!.select(\LifetimeFeature.State.count).isAlive
    } onChange: {
      notificationCount.withLock { $0 += 1 }
    }

    // A liveness tracker is not fired by value changes, so no number of
    // them may release the selection it is registered on.
    store!.send(.increment)
    store!.send(.increment)
    store!.send(.increment)
    #expect(notificationCount.withLock { $0 } == 0)

    store = nil
    #expect(notificationCount.withLock { $0 } == 1)
  }

  @Test("Releasing selections that share one dependency costs time linear in their number")
  func releasingSelectionsOfOneDependencyIsLinear() async {
    func secondsToRelease(_ count: Int) -> Double {
      let store = Store(reducer: LifetimeFeature(), initialState: .init())
      var held = (0..<count).map { _ in store.select(dependingOn: \.count) { $0 } }
      let elapsed = ContinuousClock().measure { held.removeAll() }
      return Double(elapsed.components.seconds)
        + Double(elapsed.components.attoseconds) / 1e18
    }
    // Every measurement runs on the MainActor without suspending, so the
    // sizes stay small and the test yields between measurements: tests that
    // run in the same process must not be starved past their own deadlines.
    func best(_ count: Int) async -> Double {
      var best = Double.infinity
      for _ in 0..<3 {
        best = min(best, secondsToRelease(count))
        await Task.yield()
      }
      return best
    }
    _ = secondsToRelease(200)

    // Four times the selections: about 4x when each release is O(1), about
    // 16x when each release copies the whole shared bucket.
    let small = await best(750)
    let large = await best(3_000)

    #expect(large < small * 9)
  }

  @Test("A read selection is released once two notifications pass without another read")
  func readSelectionIsReleasedAfterTwoUnreadNotifications() {
    let store = Store(reducer: LifetimeFeature(), initialState: .init())
    weak var weakSelection: SelectedStore<Int>?
    do {
      let selection = store.select(\LifetimeFeature.State.count)
      _ = selection.requireAlive()
      weakSelection = selection
    }
    #expect(weakSelection != nil)

    store.send(.touchUnrelated)
    #expect(weakSelection != nil)

    store.send(.increment)
    #expect(weakSelection != nil)

    store.send(.increment)
    #expect(weakSelection == nil)
    #expect(store.projectionObserverStats.registeredObservers == 0)
  }

  @Test("Dynamic key-path selections created at one call site do not accumulate")
  func dynamicKeyPathSelectionsDoNotAccumulate() {
    let store = Store(
      reducer: LifetimeFeature(),
      initialState: .init(items: Array(0..<1_000))
    )
    for index in 0..<1_000 {
      _ = store.select(\LifetimeFeature.State.items[index])
    }

    #expect(store.projectionObserverStats.registeredObservers == 0)
    #expect(store.selectionCache.entryCount < 128)
  }

  @Test("A scoped store releases an unread key-path selection with its last handle")
  func scopedStoreReleasesUnreadKeyPathSelection() {
    let rows = [LifetimeRow(primary: 1, alternate: 101, title: "row")]
    let store = Store(
      reducer: LifetimeFeature(),
      initialState: .init(rows: IdentifiedArray(uniqueElements: rows, id: { $0.primary }))
    )
    let scopes = store.scope(collection: \.rows, action: lifetimeRowPath)
    let row = scopes[0]
    weak var weakSelection: SelectedStore<String>?
    do {
      let selection = row.select(\LifetimeRow.title)
      weakSelection = selection
    }

    #expect(weakSelection == nil)
    #expect(row.projectionObserverStats.registeredObservers == 0)
  }

  // MARK: Registry reentrancy

  @Test("An always-refresh callback may register another observer during the pass")
  func alwaysRefreshCallbackMayRegisterAnotherObserver() {
    let registry = ProjectionObserverRegistry<Int>()
    let late = ReentrantObserver()
    var registeredLate = false
    let reentrant = ReentrantObserver {
      guard !registeredLate else { return }
      registeredLate = true
      registry.register(late, registration: .alwaysRefresh)
    }
    registry.register(reentrant, registration: .alwaysRefresh)

    registry.refresh(from: 0, to: 1)
    registry.refresh(from: 1, to: 2)

    #expect(reentrant.refreshCount == 2)
    #expect(late.refreshCount == 1)
    #expect(registry.statsSnapshot.registeredObservers == 2)
  }

  @Test("Removing one observer leaves the other dependencies of its buckets intact")
  func unregisterRemovesOnlyTheRequestedObserver() {
    let registry = ProjectionObserverRegistry<Int>()
    let first = ReentrantObserver()
    let second = ReentrantObserver()
    let registration = ProjectionObserverRegistration<Int>.dependency(
      .keyPath(\Int.self),
      hasChanged: { $0 != $1 }
    )
    registry.register(first, registration: registration)
    registry.register(second, registration: registration)

    registry.unregister(ObjectIdentifier(first))
    registry.refresh(from: 0, to: 1)

    #expect(first.refreshCount == 0)
    #expect(second.refreshCount == 1)
    #expect(registry.statsSnapshot.registeredObservers == 1)
  }
}
