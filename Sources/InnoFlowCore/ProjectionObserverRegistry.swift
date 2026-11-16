// MARK: - ProjectionObserverRegistry.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

package protocol ProjectionObserver: AnyObject {
  @MainActor
  func refreshFromParentStore() -> Bool
}

/// Identifies one dependency bucket.
///
/// A bucket evaluates a single change predicate for all of its observers, so
/// a key must determine that predicate completely: `keyPath` is always value
/// inequality, and always-refresh and memoized selectors use separate cases.
/// Collection scopes compare element identity instead and are registered
/// through ``ProjectionCollectionRegistration``, in storage of their own, so
/// they can never share a bucket with a key-path selection.
package enum ProjectionDependencyKey: Hashable {
  case keyPath(AnyKeyPath)
  case custom(SelectionCallsite)
  case memoizedCustom(SelectionCallsite)
}

/// How a collection differs between two snapshots, as seen by its rows.
package enum ProjectionCollectionChange {
  /// No row can observe a difference.
  case none
  /// These elements changed value; ids, order and count are intact.
  case elements([AnyHashable])
  /// Ids, order or count changed, so any row may have moved or disappeared.
  case structure
}

/// Registers one row projection of a collection.
///
/// Rows of the same collection share a bucket keyed by the collection key
/// path. The bucket classifies each state change once and refreshes only the
/// rows it affects, instead of refreshing every row whenever any row changes.
package struct ProjectionCollectionRegistration<Snapshot> {
  package let collection: AnyKeyPath
  package let elementID: AnyHashable
  package let change: (Snapshot, Snapshot) -> ProjectionCollectionChange
  /// Runs once per pass, before any row is refreshed, when the change is
  /// structural. Rows use it to resolve their new positions together. It
  /// returns the elements whose rows can observe a difference — a changed
  /// value or a removed element — or `nil` when every row must be refreshed.
  package let prepareStructuralRefresh: (Snapshot, Snapshot) -> [AnyHashable]?

  package init(
    collection: AnyKeyPath,
    elementID: AnyHashable,
    change: @escaping (Snapshot, Snapshot) -> ProjectionCollectionChange,
    prepareStructuralRefresh: @escaping (Snapshot, Snapshot) -> [AnyHashable]?
  ) {
    self.collection = collection
    self.elementID = elementID
    self.change = change
    self.prepareStructuralRefresh = prepareStructuralRefresh
  }
}

package struct ProjectionDependencyRegistration<Snapshot> {
  package let key: ProjectionDependencyKey
  package let hasChanged: (Snapshot, Snapshot) -> Bool

  package init(
    _ key: ProjectionDependencyKey,
    hasChanged: @escaping (Snapshot, Snapshot) -> Bool
  ) {
    self.key = key
    self.hasChanged = hasChanged
  }
}

package enum ProjectionObserverRegistration<Snapshot> {
  case alwaysRefresh
  case dependency(
    ProjectionDependencyKey,
    hasChanged: (Snapshot, Snapshot) -> Bool
  )
  case dependencies([ProjectionDependencyRegistration<Snapshot>])
  case collectionElement(ProjectionCollectionRegistration<Snapshot>)
}

package struct ProjectionObserverRegistryStats: Sendable, Equatable {
  package let registeredObservers: Int
  package let refreshPassCount: UInt64
  package let evaluatedObservers: UInt64
  package let refreshedObservers: UInt64
  package let prunedObservers: UInt64
  package let compactionPassCount: UInt64
}

package struct WeakProjectionObserver {
  weak var observer: (any ProjectionObserver)?
}

private let projectionObserverCompactionDeadObserverThresholdDefault = 16
private let projectionObserverPeriodicCompactionIntervalDefault: UInt64 = 64

@MainActor
package final class ProjectionObserverRegistry<Snapshot> {
  private struct DependencyBucket {
    var observers: [ObjectIdentifier: WeakProjectionObserver]
    let hasChanged: (Snapshot, Snapshot) -> Bool
  }

  private let compactionDeadObserverThreshold: Int
  private let periodicCompactionInterval: UInt64
  private struct CollectionBucket {
    var observersByElement: [AnyHashable: [ObjectIdentifier: WeakProjectionObserver]] = [:]
    let change: (Snapshot, Snapshot) -> ProjectionCollectionChange
    let prepareStructuralRefresh: (Snapshot, Snapshot) -> [AnyHashable]?
  }

  private struct CollectionMembership {
    let collection: AnyKeyPath
    let elementID: AnyHashable
  }

  private var alwaysObservers: [ObjectIdentifier: WeakProjectionObserver] = [:]
  private var dependencyBuckets: [ProjectionDependencyKey: DependencyBucket] = [:]
  /// Reverse index so removing one observer does not scan every bucket.
  private var dependencyKeysByObserver: [ObjectIdentifier: [ProjectionDependencyKey]] = [:]
  private var collectionBuckets: [AnyKeyPath: CollectionBucket] = [:]
  private var collectionMembershipByObserver: [ObjectIdentifier: CollectionMembership] = [:]
  private var refreshPassCount: UInt64 = 0
  private var evaluatedObservers: UInt64 = 0
  private var refreshedObservers: UInt64 = 0
  private var prunedObservers: UInt64 = 0
  private var compactionPassCount: UInt64 = 0
  private var staleObserverHints: Int = 0
  private var registrationCount: UInt64 = 0

  package init(
    compactionDeadObserverThreshold: Int = projectionObserverCompactionDeadObserverThresholdDefault,
    periodicCompactionInterval: UInt64 = projectionObserverPeriodicCompactionIntervalDefault
  ) {
    self.compactionDeadObserverThreshold = max(1, compactionDeadObserverThreshold)
    self.periodicCompactionInterval = max(1, periodicCompactionInterval)
  }

  package var statsSnapshot: ProjectionObserverRegistryStats {
    .init(
      registeredObservers: registeredObserverCount,
      refreshPassCount: refreshPassCount,
      evaluatedObservers: evaluatedObservers,
      refreshedObservers: refreshedObservers,
      prunedObservers: prunedObservers,
      compactionPassCount: compactionPassCount
    )
  }

  package func register(
    _ observer: any ProjectionObserver,
    registration: ProjectionObserverRegistration<Snapshot> = .alwaysRefresh
  ) {
    registrationCount &+= 1
    // A read-only view can create and release many independent selections
    // without ever dispatching an action. Refresh-only maintenance would keep
    // their weak registry metadata until the Store itself was released.
    if registrationCount.isMultiple(of: periodicCompactionInterval) {
      compactDeadObservers()
    }
    let observerID = ObjectIdentifier(observer)
    removeObserver(observerID)
    let weakObserver = WeakProjectionObserver(observer: observer)

    switch registration {
    case .alwaysRefresh:
      alwaysObservers[observerID] = weakObserver

    case .dependency(let dependencyKey, let hasChanged):
      registerDependency(
        observerID,
        weakObserver: weakObserver,
        dependencyKey: dependencyKey,
        hasChanged: hasChanged
      )

    case .dependencies(let registrations):
      guard !registrations.isEmpty else {
        alwaysObservers[observerID] = weakObserver
        return
      }

      var seenDependencies: Set<ProjectionDependencyKey> = []
      for registration in registrations {
        guard seenDependencies.insert(registration.key).inserted else { continue }
        registerDependency(
          observerID,
          weakObserver: weakObserver,
          dependencyKey: registration.key,
          hasChanged: registration.hasChanged
        )
      }

    case .collectionElement(let registration):
      // The first row's classification serves the whole bucket. That is
      // sound because the collection key path determines it: every row of
      // one collection compares the same collection the same way.
      collectionBuckets[
        registration.collection,
        default: CollectionBucket(
          change: registration.change,
          prepareStructuralRefresh: registration.prepareStructuralRefresh
        )
      ].observersByElement[registration.elementID, default: [:]][observerID] = weakObserver
      collectionMembershipByObserver[observerID] = .init(
        collection: registration.collection,
        elementID: registration.elementID
      )
    }
  }

  /// Removes an observer that is being deallocated.
  ///
  /// Projections call this from their MainActor deinitializer so a bucket
  /// never evaluates a dependency on behalf of an observer that no longer
  /// exists. Lazily pruned weak entries remain the fallback for observers
  /// without a deinitializer hook.
  package func unregister(_ observerID: ObjectIdentifier) {
    removeObserver(observerID)
  }

  package func refreshAll() {
    refreshPassCount &+= 1
    _ = refreshAlwaysObservers()
    let (pendingDependencyObservers, staleCount) = collectDependencyObservers(
      for: Array(dependencyBuckets.keys)
    )
    staleObserverHints &+= staleCount
    refresh(pendingObservers: pendingDependencyObservers)
    for collection in Array(collectionBuckets.keys) {
      refresh(pendingObserverArray: collectCollectionObservers(in: collection, elementIDs: nil))
    }
    staleObserverHints = 0
  }

  package func refresh(from oldSnapshot: Snapshot, to newSnapshot: Snapshot) {
    refreshPassCount &+= 1
    guard !alwaysObservers.isEmpty || !dependencyBuckets.isEmpty || !collectionBuckets.isEmpty
    else { return }
    staleObserverHints &+= refreshAlwaysObservers()

    var firstChangedDependencyKey: ProjectionDependencyKey?
    var multipleChangedDependencyKeys: [ProjectionDependencyKey]?
    for (dependencyKey, bucket) in dependencyBuckets {
      guard bucket.hasChanged(oldSnapshot, newSnapshot) else { continue }

      if let firstChangedDependencyKey {
        if multipleChangedDependencyKeys == nil {
          multipleChangedDependencyKeys = [firstChangedDependencyKey]
        }
        multipleChangedDependencyKeys?.append(dependencyKey)
      } else {
        firstChangedDependencyKey = dependencyKey
      }
    }

    if let multipleChangedDependencyKeys {
      let (pendingDependencyObservers, staleCount) = collectDependencyObservers(
        for: multipleChangedDependencyKeys
      )
      staleObserverHints &+= staleCount
      refresh(pendingObservers: pendingDependencyObservers)
    } else if let firstChangedDependencyKey {
      let (pendingDependencyObservers, staleCount) = collectDependencyObservers(
        for: firstChangedDependencyKey
      )
      staleObserverHints &+= staleCount
      refresh(pendingObserverArray: pendingDependencyObservers)
    }

    if !collectionBuckets.isEmpty {
      refreshCollectionBuckets(from: oldSnapshot, to: newSnapshot)
    }

    compactIfNeeded()
  }

  /// Refreshes the rows a collection change can affect.
  ///
  /// A value change inside a row refreshes that row only. A structural
  /// change lets the rows resolve their new positions once, together, and
  /// then refreshes the rows whose element changed or was removed.
  private func refreshCollectionBuckets(from oldSnapshot: Snapshot, to newSnapshot: Snapshot) {
    for (collection, bucket) in collectionBuckets {
      switch bucket.change(oldSnapshot, newSnapshot) {
      case .none:
        continue

      case .elements(let elementIDs):
        refresh(
          pendingObserverArray: collectCollectionObservers(in: collection, elementIDs: elementIDs)
        )

      case .structure:
        // Moving a row does not change what it shows. Once positions are
        // resolved, only rows whose element changed or disappeared refresh.
        let affectedElementIDs = bucket.prepareStructuralRefresh(oldSnapshot, newSnapshot)
        refresh(
          pendingObserverArray: collectCollectionObservers(
            in: collection,
            elementIDs: affectedElementIDs
          )
        )
      }
    }
  }

  /// Strong references to the live rows of a collection, for the given
  /// elements or for all of them, pruning rows that were released.
  private func collectCollectionObservers(
    in collection: AnyKeyPath,
    elementIDs: [AnyHashable]?
  ) -> ContiguousArray<any ProjectionObserver> {
    guard var bucket = collectionBuckets[collection] else { return [] }
    var pendingObservers: ContiguousArray<any ProjectionObserver> = []
    var staleObservers: [(elementID: AnyHashable, observerID: ObjectIdentifier)] = []

    func collect(_ elementID: AnyHashable) {
      guard let observers = bucket.observersByElement[elementID] else { return }
      for (observerID, box) in observers {
        if let observer = box.observer {
          pendingObservers.append(observer)
        } else {
          staleObservers.append((elementID, observerID))
        }
      }
    }

    if let elementIDs {
      for elementID in elementIDs {
        collect(elementID)
      }
    } else {
      for elementID in bucket.observersByElement.keys {
        collect(elementID)
      }
    }

    guard !staleObservers.isEmpty else { return pendingObservers }
    for stale in staleObservers {
      guard bucket.observersByElement[stale.elementID]?.removeValue(forKey: stale.observerID) != nil
      else { continue }
      if bucket.observersByElement[stale.elementID]?.isEmpty == true {
        bucket.observersByElement.removeValue(forKey: stale.elementID)
      }
      collectionMembershipByObserver.removeValue(forKey: stale.observerID)
      prunedObservers &+= 1
    }
    staleObserverHints &+= staleObservers.count
    if bucket.observersByElement.isEmpty {
      collectionBuckets.removeValue(forKey: collection)
    } else {
      collectionBuckets[collection] = bucket
    }
    return pendingObservers
  }

  package func pruneAllObservers() {
    let bucketPrunedCount = dependencyBuckets.reduce(0) { partialResult, entry in
      partialResult + entry.value.observers.count
    }
    prunedObservers &+= UInt64(
      alwaysObservers.count + bucketPrunedCount + collectionMembershipByObserver.count
    )
    alwaysObservers.removeAll(keepingCapacity: true)
    dependencyBuckets.removeAll(keepingCapacity: true)
    dependencyKeysByObserver.removeAll(keepingCapacity: true)
    collectionBuckets.removeAll(keepingCapacity: true)
    collectionMembershipByObserver.removeAll(keepingCapacity: true)
    staleObserverHints = 0
  }

  private var registeredObserverCount: Int {
    var ids = Set(alwaysObservers.keys)
    for bucket in dependencyBuckets.values {
      ids.formUnion(bucket.observers.keys)
    }
    ids.formUnion(collectionMembershipByObserver.keys)
    return ids.count
  }

  /// Refreshes always-refresh observers and prunes released ones.
  ///
  /// Storage is never accessed while a callback runs or while a strong
  /// observer reference is released: a callback may register another
  /// projection, and releasing the last reference runs a deinitializer that
  /// unregisters. Either would overlap an in-progress access to the storage.
  @discardableResult
  private func refreshAlwaysObservers() -> Int {
    guard !alwaysObservers.isEmpty else { return 0 }
    var liveObservers: ContiguousArray<any ProjectionObserver> = []
    var staleObserverIDs: [ObjectIdentifier] = []
    do {
      let snapshot = alwaysObservers
      liveObservers.reserveCapacity(snapshot.count)
      for (observerID, box) in snapshot {
        if let observer = box.observer {
          liveObservers.append(observer)
        } else {
          staleObserverIDs.append(observerID)
        }
      }
    }

    for observer in liveObservers {
      evaluatedObservers &+= 1
      if observer.refreshFromParentStore() {
        refreshedObservers &+= 1
      }
    }

    for observerID in staleObserverIDs {
      // A callback can register a new object at a recycled address.
      guard let box = alwaysObservers[observerID], box.observer == nil else { continue }
      alwaysObservers.removeValue(forKey: observerID)
      prunedObservers &+= 1
    }

    return staleObserverIDs.count
  }

  private func refresh(pendingObservers: [ObjectIdentifier: any ProjectionObserver]) {
    for observer in pendingObservers.values {
      evaluatedObservers &+= 1
      if observer.refreshFromParentStore() {
        refreshedObservers &+= 1
      }
    }
  }

  private func refresh(
    pendingObserverArray: ContiguousArray<any ProjectionObserver>
  ) {
    for observer in pendingObserverArray {
      evaluatedObservers &+= 1
      if observer.refreshFromParentStore() {
        refreshedObservers &+= 1
      }
    }
  }

  private func collectDependencyObservers(
    for dependencyKey: ProjectionDependencyKey
  ) -> (ContiguousArray<any ProjectionObserver>, Int) {
    guard var bucket = dependencyBuckets[dependencyKey] else { return ([], 0) }

    var pendingObservers: ContiguousArray<any ProjectionObserver> = []
    pendingObservers.reserveCapacity(bucket.observers.count)
    var staleObserverIDs: [ObjectIdentifier]?

    for (observerID, box) in bucket.observers {
      guard let observer = box.observer else {
        if staleObserverIDs == nil {
          staleObserverIDs = []
        }
        staleObserverIDs?.append(observerID)
        continue
      }
      pendingObservers.append(observer)
    }

    guard let staleObserverIDs else { return (pendingObservers, 0) }

    for observerID in staleObserverIDs {
      bucket.observers.removeValue(forKey: observerID)
      forgetDependencyKey(dependencyKey, for: observerID)
    }
    prunedObservers &+= UInt64(staleObserverIDs.count)

    // Finish pruning the copied bucket before invoking any observer callback.
    // A callback may register another observer in this bucket, so no copy may
    // be written back after `pendingObservers` leaves this method.
    if bucket.observers.isEmpty {
      dependencyBuckets.removeValue(forKey: dependencyKey)
    } else {
      dependencyBuckets[dependencyKey] = bucket
    }

    return (pendingObservers, staleObserverIDs.count)
  }

  private func collectDependencyObservers(
    for dependencyKeys: [ProjectionDependencyKey]
  ) -> ([ObjectIdentifier: any ProjectionObserver], Int) {
    var pendingObservers: [ObjectIdentifier: any ProjectionObserver] = [:]
    var staleObserversByDependency: [ProjectionDependencyKey: [ObjectIdentifier]] = [:]

    for dependencyKey in dependencyKeys {
      guard let bucket = dependencyBuckets[dependencyKey] else { continue }
      for (observerID, box) in bucket.observers {
        guard let observer = box.observer else {
          staleObserversByDependency[dependencyKey, default: []].append(observerID)
          continue
        }
        pendingObservers[observerID] = observer
      }
    }

    var staleObserverCount = 0
    for (dependencyKey, staleObserverIDs) in staleObserversByDependency {
      staleObserverCount += staleObserverIDs.count
      removeObservers(staleObserverIDs, fromDependencyBucket: dependencyKey)
    }

    return (pendingObservers, staleObserverCount)
  }

  private func removeObserver(_ observerID: ObjectIdentifier) {
    alwaysObservers.removeValue(forKey: observerID)

    if let membership = collectionMembershipByObserver.removeValue(forKey: observerID) {
      // In place, for the same reason as the dependency buckets below.
      let collection = membership.collection
      let elementID = membership.elementID
      collectionBuckets[collection]?.observersByElement[elementID]?
        .removeValue(forKey: observerID)
      if collectionBuckets[collection]?.observersByElement[elementID]?.isEmpty == true {
        collectionBuckets[collection]?.observersByElement.removeValue(forKey: elementID)
      }
      if collectionBuckets[collection]?.observersByElement.isEmpty == true {
        collectionBuckets.removeValue(forKey: collection)
      }
    }

    guard let dependencyKeys = dependencyKeysByObserver.removeValue(forKey: observerID) else {
      return
    }
    for dependencyKey in dependencyKeys {
      // Mutate the bucket where it is stored. Copying it out first makes its
      // observer table shared, so removing one observer would copy the whole
      // table: releasing N selections of one dependency would cost O(N²).
      dependencyBuckets[dependencyKey]?.observers.removeValue(forKey: observerID)
      if dependencyBuckets[dependencyKey]?.observers.isEmpty == true {
        dependencyBuckets.removeValue(forKey: dependencyKey)
      }
    }
  }

  private func forgetDependencyKey(
    _ dependencyKey: ProjectionDependencyKey,
    for observerID: ObjectIdentifier
  ) {
    guard var dependencyKeys = dependencyKeysByObserver[observerID] else { return }
    dependencyKeys.removeAll { $0 == dependencyKey }
    dependencyKeysByObserver[observerID] = dependencyKeys.isEmpty ? nil : dependencyKeys
  }

  private func removeObservers(
    _ observerIDs: [ObjectIdentifier],
    fromDependencyBucket dependencyKey: ProjectionDependencyKey
  ) {
    guard var bucket = dependencyBuckets[dependencyKey] else { return }

    for observerID in observerIDs {
      if bucket.observers.removeValue(forKey: observerID) != nil {
        prunedObservers &+= 1
        forgetDependencyKey(dependencyKey, for: observerID)
      }
    }

    if bucket.observers.isEmpty {
      dependencyBuckets.removeValue(forKey: dependencyKey)
    } else {
      dependencyBuckets[dependencyKey] = bucket
    }
  }

  private func registerDependency(
    _ observerID: ObjectIdentifier,
    weakObserver: WeakProjectionObserver,
    dependencyKey: ProjectionDependencyKey,
    hasChanged: @escaping (Snapshot, Snapshot) -> Bool
  ) {
    // Every dependency key routes through a bucket so its `hasChanged`
    // predicate is honored. The first registrant's predicate serves the whole
    // bucket, which is sound because a `ProjectionDependencyKey` determines
    // its predicate: key-path buckets compare values, and always-refresh and
    // memoized selectors use separate cases even when they originate at one
    // dynamic call site. Collection rows live in `collectionBuckets`.
    dependencyBuckets[
      dependencyKey,
      default: DependencyBucket(observers: [:], hasChanged: hasChanged)
    ].observers[observerID] = weakObserver
    dependencyKeysByObserver[observerID, default: []].append(dependencyKey)
  }

  private func compactIfNeeded() {
    let shouldCompactForStaleObservers = staleObserverHints >= compactionDeadObserverThreshold
    let shouldCompactForPeriodicMaintenance =
      periodicCompactionInterval > 0 && refreshPassCount.isMultiple(of: periodicCompactionInterval)

    guard shouldCompactForStaleObservers || shouldCompactForPeriodicMaintenance else { return }

    compactDeadObservers()
  }

  private func compactDeadObservers() {
    compactionPassCount &+= 1
    alwaysObservers = compacted(alwaysObservers, dependencyKey: nil)
    for (dependencyKey, bucket) in dependencyBuckets {
      let liveObservers = compacted(bucket.observers, dependencyKey: dependencyKey)
      guard liveObservers.count != bucket.observers.count else { continue }
      if liveObservers.isEmpty {
        dependencyBuckets.removeValue(forKey: dependencyKey)
      } else {
        dependencyBuckets[dependencyKey] = DependencyBucket(
          observers: liveObservers,
          hasChanged: bucket.hasChanged
        )
      }
    }
    for collection in Array(collectionBuckets.keys) {
      // Collecting every row prunes the released ones as a side effect; the
      // strong references it returns are dropped after the registry storage
      // is no longer being accessed.
      _ = collectCollectionObservers(in: collection, elementIDs: nil)
    }
    staleObserverHints = 0
  }

  /// Returns the live subset of a detached observer snapshot. The snapshot is
  /// a value copy, so no registry storage is accessed while weak references
  /// are loaded.
  private func compacted(
    _ observers: [ObjectIdentifier: WeakProjectionObserver],
    dependencyKey: ProjectionDependencyKey?
  ) -> [ObjectIdentifier: WeakProjectionObserver] {
    var liveObservers = observers
    for (observerID, box) in observers where box.observer == nil {
      liveObservers.removeValue(forKey: observerID)
      prunedObservers &+= 1
      if let dependencyKey {
        forgetDependencyKey(dependencyKey, for: observerID)
      }
    }
    return liveObservers
  }
}
