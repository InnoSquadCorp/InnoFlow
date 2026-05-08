// MARK: - ScopedStore.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import Observation

package enum ScopedStoreFailureKind {
  case parentReleased
  case collectionEntryRemoved
  case collectionIdentityRequired
}

package func scopedStoreFailureMessage(
  parentType: Any.Type,
  childType: Any.Type,
  stableID: AnyHashable?,
  kind: ScopedStoreFailureKind
) -> String {
  let scopedType =
    "ScopedStore<\(String(reflecting: parentType)), \(String(reflecting: childType))>"
  let idSection = stableID.map { "\nElement ID: \($0)" } ?? ""

  switch kind {
  case .parentReleased:
    return """
      \(scopedType) outlived its parent store.\(idSection)
      Remediation: regenerate the scoped store from parent state before using it again.
      """
  case .collectionEntryRemoved:
    return """
      \(scopedType) outlived its source collection entry.\(idSection)
      Remediation: regenerate the scoped store from parent state before using it again.
      """
  case .collectionIdentityRequired:
    return """
      \(scopedType) can expose Identifiable only when created with store.scope(collection:action:).
      Remediation: regenerate the scoped store from parent state using collection scoping.
      """
  }
}

extension Store {
  fileprivate func stateProjectionRegistration<ChildState: Equatable>(
    state: KeyPath<R.State, ChildState>
  ) -> ProjectionObserverRegistration<R.State> {
    .dependency(
      .keyPath(state as AnyKeyPath),
      hasChanged: { previousState, nextState in
        previousState[keyPath: state] != nextState[keyPath: state]
      }
    )
  }

  fileprivate func collectionProjectionRegistration<CollectionState>(
    collection: KeyPath<R.State, CollectionState>
  ) -> ProjectionObserverRegistration<R.State>
  where
    CollectionState: RandomAccessCollection,
    CollectionState.Element: Equatable & Identifiable
  {
    .dependency(
      .keyPath(collection as AnyKeyPath),
      hasChanged: { previousState, nextState in
        collectionSnapshotChanged(
          previousState[keyPath: collection],
          nextState[keyPath: collection]
        )
      }
    )
  }

  /// Creates a derived store for child state/action pairs.
  fileprivate func makeScopedStore<ChildState: Equatable, ChildAction>(
    state: KeyPath<R.State, ChildState>,
    action: @escaping @Sendable (ChildAction) -> R.Action
  ) -> ScopedStore<R, ChildState, ChildAction> {
    ScopedStore(
      parent: self,
      stateResolver: { parentState in
        parentState[keyPath: state]
      },
      observerRegistration: stateProjectionRegistration(state: state),
      actionTransform: action
    )
  }

  /// Creates a derived store using a case path for action lifting.
  public func scope<ChildState: Equatable, ChildAction>(
    state: KeyPath<R.State, ChildState>,
    action: CasePath<R.Action, ChildAction>
  ) -> ScopedStore<R, ChildState, ChildAction> {
    makeScopedStore(state: state, action: action.embed)
  }

  /// Creates derived stores for each element in an identifiable collection.
  ///
  /// The returned stores carry a stable identity snapshot so they can be
  /// rendered directly in `ForEach`.
  fileprivate func makeScopedCollectionStores<CollectionState, ChildAction>(
    collection: KeyPath<R.State, CollectionState>,
    action: @escaping @Sendable (CollectionState.Element.ID, ChildAction) -> R.Action,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    column: UInt = #column
  ) -> [ScopedStore<R, CollectionState.Element, ChildAction>]
  where
    CollectionState: RandomAccessCollection,
    CollectionState.Element: Equatable & Identifiable,
    CollectionState.Element.ID: Sendable
  {
    let anyKeyPath = collection as AnyKeyPath
    let callsite = collectionScopeCallsite(fileID: fileID, line: line, column: column)
    let bucket = collectionScopeCache.validatedBucket(for: anyKeyPath, callsite: callsite)
    bucket.revision &+= 1
    let elements = state[keyPath: collection]
    var stores: [ScopedStore<R, CollectionState.Element, ChildAction>] = []

    for (offset, element) in elements.enumerated() {
      let scopedElementID = element.id
      let elementID = AnyHashable(scopedElementID)

      let offsetBox =
        bucket.offsetsByID[elementID]
        ?? CollectionScopeOffsetBox(offset: offset, revision: bucket.revision)
      offsetBox.offset = offset
      offsetBox.revision = bucket.revision
      bucket.offsetsByID[elementID] = offsetBox

      if let cached = bucket.storesByID[elementID]
        as? ScopedStore<R, CollectionState.Element, ChildAction>
      {
        stores.append(cached)
        continue
      }

      let scopedStore = ScopedStore(
        parent: self,
        stateResolver: { [collection, scopedElementID, weak bucket, offsetBox] state in
          resolveScopedCollectionElement(
            in: state,
            collection: collection,
            id: scopedElementID,
            bucket: bucket,
            offsetBox: offsetBox
          )
        },
        stableID: elementID,
        failureKind: .collectionEntryRemoved,
        observerRegistration: collectionProjectionRegistration(collection: collection),
        actionTransform: { childAction in
          action(scopedElementID, childAction)
        }
      )
      bucket.storesByID[elementID] = scopedStore
      stores.append(scopedStore)
    }

    var staleIDs: [AnyHashable] = []
    for (elementID, offsetBox) in bucket.offsetsByID where offsetBox.revision != bucket.revision {
      staleIDs.append(elementID)
    }
    for elementID in staleIDs {
      bucket.offsetsByID.removeValue(forKey: elementID)
      bucket.storesByID.removeValue(forKey: elementID)
    }

    collectionScopeCache.store(bucket, for: anyKeyPath)
    return stores
  }

  public func scope<CollectionState, ChildAction>(
    collection: KeyPath<R.State, CollectionState>,
    action: CollectionActionPath<R.Action, CollectionState.Element.ID, ChildAction>,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    column: UInt = #column
  ) -> [ScopedStore<R, CollectionState.Element, ChildAction>]
  where
    CollectionState: RandomAccessCollection,
    CollectionState.Element: Equatable & Identifiable,
    CollectionState.Element.ID: Sendable
  {
    makeScopedCollectionStores(
      collection: collection,
      action: action.embed,
      fileID: fileID,
      line: line,
      column: column
    )
  }

}

@MainActor
private func resolveScopedCollectionElement<ParentState, CollectionState>(
  in state: ParentState,
  collection: KeyPath<ParentState, CollectionState>,
  id: CollectionState.Element.ID,
  bucket: CollectionScopeCacheBucket?,
  offsetBox: CollectionScopeOffsetBox
) -> CollectionState.Element?
where
  CollectionState: RandomAccessCollection,
  CollectionState.Element: Equatable & Identifiable
{
  let collectionState = state[keyPath: collection]

  if let bucket,
    offsetBox.revision == bucket.revision,
    let candidate = scopedCollectionElement(
      in: collectionState,
      at: offsetBox.offset
    ),
    candidate.id == id
  {
    return candidate
  }

  for (offset, candidate) in collectionState.enumerated() where candidate.id == id {
    offsetBox.offset = offset
    if let bucket {
      offsetBox.revision = bucket.revision
    }
    return candidate
  }

  return nil
}

private func scopedCollectionElement<CollectionState>(
  in collection: CollectionState,
  at offset: Int
) -> CollectionState.Element?
where CollectionState: RandomAccessCollection {
  guard offset >= 0 else { return nil }
  guard
    let index = collection.index(
      collection.startIndex, offsetBy: offset, limitedBy: collection.endIndex),
    index != collection.endIndex
  else {
    return nil
  }
  return collection[index]
}

private func collectionSnapshotChanged<CollectionState>(
  _ previousCollection: CollectionState,
  _ nextCollection: CollectionState
) -> Bool
where
  CollectionState: RandomAccessCollection,
  CollectionState.Element: Equatable & Identifiable
{
  guard previousCollection.count == nextCollection.count else { return true }

  for (previousElement, nextElement) in zip(previousCollection, nextCollection) {
    guard previousElement.id == nextElement.id, previousElement == nextElement else {
      return true
    }
  }

  return false
}

/// A read-only projection of parent store state with action forwarding.
@Observable
@MainActor
@dynamicMemberLookup
public final class ScopedStore<ParentReducer: Reducer, ChildState: Equatable, ChildAction> {
  package var cachedState: ChildState
  @ObservationIgnored private weak var parent: Store<ParentReducer>?
  @ObservationIgnored private let stateResolver: @MainActor (ParentReducer.State) -> ChildState?
  @ObservationIgnored private let actionTransform: @Sendable (ChildAction) -> ParentReducer.Action
  @ObservationIgnored package let failureKind: ScopedStoreFailureKind
  @ObservationIgnored package let observerRegistry = ProjectionObserverRegistry<ChildState>()
  @ObservationIgnored package let selectionCache = SelectionCache()
  @ObservationIgnored package var isActive = true
  @ObservationIgnored package var pendingObserverPrune = false
  @ObservationIgnored package nonisolated(unsafe) let stableID: AnyHashable?

  /// The current child state, falling back to the last cached snapshot
  /// when the parent store is released or the projection is inactive.
  ///
  /// This accessor exists so SwiftUI observer races do not crash release
  /// builds; it is **not** intended as a stable lifecycle-aware read path.
  /// New call sites should prefer ``optionalState`` (or gate on
  /// ``isAlive``) and treat `nil` as "regenerate the projection." Reserve
  /// `state` for tick-bounded observers (SwiftUI view bodies, dynamic
  /// member lookups) that must always return something.
  ///
  /// See ARCHITECTURE_CONTRACT.md — "Projection lifecycle contract".
  public var state: ChildState {
    // Lifecycle race: a SwiftUI observer may read this projection on the same
    // tick that its parent store is released. Rather than aborting the
    // process in release builds, return the last valid cached projection —
    // the observer refresh pass will invalidate dependents within the next
    // tick. Debug builds surface the race via `assertionFailure`.
    guard parent != nil else {
      assertionFailure(parentReleasedMessage())
      return cachedState
    }
    guard isActive else {
      assertionFailure(staleMessage())
      return cachedState
    }
    return cachedState
  }

  /// Whether this projection is still backed by a live parent store.
  ///
  /// Returns `false` once the parent `Store` has been released or the
  /// projection has been marked inactive (for example, when a collection
  /// element corresponding to this projection is removed). Callers can use
  /// this to skip work that would otherwise read a stale cached snapshot
  /// from `state` or have its action dropped by `send(_:)`.
  ///
  /// See ARCHITECTURE_CONTRACT.md — "Projection lifecycle contract".
  public var isAlive: Bool {
    parent != nil && isActive
  }

  /// A read accessor that reports a released parent or inactive projection
  /// as `nil` instead of returning the last cached snapshot.
  ///
  /// `state` keeps the existing cached-read contract for SwiftUI observer
  /// races. `optionalState` is the explicit form: callers that need to
  /// distinguish "value is fresh" from "parent is gone" without hitting a
  /// debug assertion or a release-time stale read should consult this
  /// property and treat `nil` as "regenerate the projection."
  public var optionalState: ChildState? {
    guard isAlive else { return nil }
    return cachedState
  }

  init(
    parent: Store<ParentReducer>,
    stateResolver: @escaping @MainActor (ParentReducer.State) -> ChildState?,
    stableID: AnyHashable? = nil,
    failureKind: ScopedStoreFailureKind = .parentReleased,
    observerRegistration: ProjectionObserverRegistration<ParentReducer.State> = .alwaysRefresh,
    actionTransform: @escaping @Sendable (ChildAction) -> ParentReducer.Action
  ) {
    guard let initialState = stateResolver(parent.state) else {
      preconditionFailure(
        scopedStoreFailureMessage(
          parentType: ParentReducer.self,
          childType: ChildState.self,
          stableID: stableID,
          kind: failureKind
        )
      )
    }
    self.cachedState = initialState
    self.parent = parent
    self.stateResolver = stateResolver
    self.stableID = stableID
    self.failureKind = failureKind
    self.actionTransform = actionTransform
    parent.registerProjectionObserver(self, registration: observerRegistration)
  }

  private func staleMessage() -> String {
    scopedStoreFailureMessage(
      parentType: ParentReducer.self,
      childType: ChildState.self,
      stableID: stableID,
      kind: failureKind
    )
  }

  private func parentReleasedMessage() -> String {
    scopedStoreFailureMessage(
      parentType: ParentReducer.self,
      childType: ChildState.self,
      stableID: stableID,
      kind: .parentReleased
    )
  }

  private func refreshStateFromParent() -> Bool {
    guard isActive else {
      if pendingObserverPrune {
        observerRegistry.pruneAllObservers()
        pendingObserverPrune = false
      }
      return false
    }
    guard let parent else { return false }
    let previousState = cachedState
    guard let nextState = stateResolver(parent.state) else {
      // Background refresh deactivates a stale projection; direct access follows
      // the projection lifecycle contract via cached reads/no-op sends plus
      // debug assertions.
      isActive = false
      pendingObserverPrune = true
      observerRegistry.refreshAll()
      return true
    }
    if nextState != previousState {
      cachedState = nextState
      observerRegistry.refresh(from: previousState, to: nextState)
      return true
    }
    return false
  }

  public subscript<Value>(dynamicMember keyPath: KeyPath<ChildState, Value>) -> Value {
    state[keyPath: keyPath]
  }

  public subscript<Value>(dynamicMember keyPath: KeyPath<ChildState, BindableProperty<Value>>)
    -> Value
  where Value: Equatable & Sendable {
    state[keyPath: keyPath].value
  }

  public func send(_ action: ChildAction) {
    // Lifecycle race: silently drop the action if the parent store is gone.
    // See `state` above and ARCHITECTURE_CONTRACT.md — "Projection lifecycle
    // contract". Debug builds still surface the race via `assertionFailure`.
    guard let parent else {
      assertionFailure(parentReleasedMessage())
      return
    }
    guard isActive else {
      assertionFailure(staleMessage())
      return
    }
    parent.send(actionTransform(action))
  }

  package var projectionObserverStats: ProjectionObserverRegistryStats {
    observerRegistry.statsSnapshot
  }
}

extension ScopedStore: ProjectionObserver {
  package func refreshFromParentStore() -> Bool {
    refreshStateFromParent()
  }
}

extension ScopedStore: CustomDebugStringConvertible {
  public nonisolated var debugDescription: String {
    MainActor.assumeIsolated {
      """
      ScopedStore(parentType: \(String(reflecting: ParentReducer.self)), childType: \(String(reflecting: ChildState.self)), parentAlive: \(parent != nil), active: \(isActive), stableID: \(stableID.map(String.init(describing:)) ?? "nil"))
      """
    }
  }
}

extension ScopedStore: Identifiable where ChildState: Identifiable {
  public nonisolated var id: ChildState.ID {
    guard let id = stableID as? ChildState.ID else {
      preconditionFailure(
        scopedStoreFailureMessage(
          parentType: ParentReducer.self,
          childType: ChildState.self,
          stableID: stableID,
          kind: .collectionIdentityRequired
        )
      )
    }
    return id
  }
}
