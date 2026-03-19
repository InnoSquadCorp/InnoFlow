// MARK: - StoreSupport.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import os

package final class StoreLifetimeToken: Sendable {
  private let released = OSAllocatedUnfairLock(initialState: false)

  package init() {}

  package func markReleased() {
    released.withLock { $0 = true }
  }

  package var isReleased: Bool {
    released.withLock { $0 }
  }
}

package protocol ProjectionObserver: AnyObject {
  @MainActor
  func refreshFromParentStore() -> Bool
}

package enum ProjectionDependencyKey: Hashable {
  case keyPath(AnyKeyPath)
  case custom(SelectionCallsite)
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
  weak var observer: AnyObject?
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
  private var alwaysObservers: [ObjectIdentifier: WeakProjectionObserver] = [:]
  private var dependencyBuckets: [ProjectionDependencyKey: DependencyBucket] = [:]
  private var refreshPassCount: UInt64 = 0
  private var evaluatedObservers: UInt64 = 0
  private var refreshedObservers: UInt64 = 0
  private var prunedObservers: UInt64 = 0
  private var compactionPassCount: UInt64 = 0
  private var staleObserverHints: Int = 0

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

      if registrations.contains(where: {
        if case .custom = $0.key { return true }
        return false
      }) {
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
    }
  }

  package func refreshAll() {
    refreshPassCount &+= 1
    _ = refresh(observers: &alwaysObservers)
    let (pendingDependencyObservers, staleCount) = collectDependencyObservers(
      for: Array(dependencyBuckets.keys)
    )
    staleObserverHints &+= staleCount
    refresh(pendingObservers: pendingDependencyObservers)
    staleObserverHints = 0
  }

  package func refresh(from oldSnapshot: Snapshot, to newSnapshot: Snapshot) {
    refreshPassCount &+= 1
    staleObserverHints &+= refresh(observers: &alwaysObservers)

    let changedDependencyKeys = dependencyBuckets.compactMap { dependencyKey, bucket in
      bucket.hasChanged(oldSnapshot, newSnapshot) ? dependencyKey : nil
    }
    let (pendingDependencyObservers, staleCount) = collectDependencyObservers(
      for: changedDependencyKeys
    )
    staleObserverHints &+= staleCount
    refresh(pendingObservers: pendingDependencyObservers)

    compactIfNeeded()
  }

  package func pruneAllObservers() {
    let bucketPrunedCount = dependencyBuckets.reduce(0) { partialResult, entry in
      partialResult + entry.value.observers.count
    }
    prunedObservers &+= UInt64(alwaysObservers.count + bucketPrunedCount)
    alwaysObservers.removeAll(keepingCapacity: true)
    dependencyBuckets.removeAll(keepingCapacity: true)
    staleObserverHints = 0
  }

  private var registeredObserverCount: Int {
    var ids = Set(alwaysObservers.keys)
    for bucket in dependencyBuckets.values {
      ids.formUnion(bucket.observers.keys)
    }
    return ids.count
  }

  @discardableResult
  private func refresh(observers: inout [ObjectIdentifier: WeakProjectionObserver]) -> Int {
    var staleObserverIDs: [ObjectIdentifier] = []

    for (observerID, box) in observers {
      guard let observer = box.observer as? any ProjectionObserver else {
        staleObserverIDs.append(observerID)
        continue
      }

      evaluatedObservers &+= 1
      if observer.refreshFromParentStore() {
        refreshedObservers &+= 1
      }
    }

    for observerID in staleObserverIDs {
      observers.removeValue(forKey: observerID)
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

  private func collectDependencyObservers(
    for dependencyKeys: [ProjectionDependencyKey]
  ) -> ([ObjectIdentifier: any ProjectionObserver], Int) {
    var pendingObservers: [ObjectIdentifier: any ProjectionObserver] = [:]
    var staleObserversByDependency: [ProjectionDependencyKey: [ObjectIdentifier]] = [:]

    for dependencyKey in dependencyKeys {
      guard let bucket = dependencyBuckets[dependencyKey] else { continue }
      for (observerID, box) in bucket.observers {
        guard let observer = box.observer as? any ProjectionObserver else {
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

    for dependencyKey in Array(dependencyBuckets.keys) {
      guard var bucket = dependencyBuckets[dependencyKey] else { continue }
      bucket.observers.removeValue(forKey: observerID)
      if bucket.observers.isEmpty {
        dependencyBuckets.removeValue(forKey: dependencyKey)
      } else {
        dependencyBuckets[dependencyKey] = bucket
      }
    }
  }

  private func removeObservers(
    _ observerIDs: [ObjectIdentifier],
    fromDependencyBucket dependencyKey: ProjectionDependencyKey
  ) {
    guard var bucket = dependencyBuckets[dependencyKey] else { return }

    for observerID in observerIDs {
      if bucket.observers.removeValue(forKey: observerID) != nil {
        prunedObservers &+= 1
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
    switch dependencyKey {
    case .custom:
      alwaysObservers[observerID] = weakObserver

    case .keyPath:
      if var bucket = dependencyBuckets[dependencyKey] {
        bucket.observers[observerID] = weakObserver
        dependencyBuckets[dependencyKey] = bucket
      } else {
        dependencyBuckets[dependencyKey] = DependencyBucket(
          observers: [observerID: weakObserver],
          hasChanged: hasChanged
        )
      }
    }
  }

  private func compactIfNeeded() {
    let shouldCompactForStaleObservers = staleObserverHints >= compactionDeadObserverThreshold
    let shouldCompactForPeriodicMaintenance =
      periodicCompactionInterval > 0 && refreshPassCount.isMultiple(of: periodicCompactionInterval)

    guard shouldCompactForStaleObservers || shouldCompactForPeriodicMaintenance else { return }

    compactionPassCount &+= 1
    compact(observers: &alwaysObservers)
    for dependencyKey in Array(dependencyBuckets.keys) {
      guard var bucket = dependencyBuckets[dependencyKey] else { continue }
      compact(observers: &bucket.observers)
      if bucket.observers.isEmpty {
        dependencyBuckets.removeValue(forKey: dependencyKey)
      } else {
        dependencyBuckets[dependencyKey] = bucket
      }
    }
    staleObserverHints = 0
  }

  private func compact(observers: inout [ObjectIdentifier: WeakProjectionObserver]) {
    let liveObservers = observers.filter { $0.value.observer != nil }
    let removedCount = observers.count - liveObservers.count
    if removedCount > 0 {
      prunedObservers &+= UInt64(removedCount)
    }
    observers = liveObservers
  }
}

package struct StoreQueuedAction<Action> {
  package let action: Action
  package let animation: EffectAnimation?
}

@MainActor
package final class StoreActionQueue<Action> {
  private var buffered: [StoreQueuedAction<Action>] = []
  private var head = 0
  private var isDraining = false

  package init() {}

  package func enqueue(_ action: Action, animation: EffectAnimation?) {
    buffered.append(.init(action: action, animation: animation))
  }

  package func beginDrain() -> Bool {
    guard !isDraining else { return false }
    isDraining = true
    return true
  }

  package func next() -> StoreQueuedAction<Action>? {
    guard head < buffered.count else { return nil }
    let action = buffered[head]
    head += 1
    return action
  }

  package func finishDrain() {
    isDraining = false
    buffered.removeAll(keepingCapacity: true)
    head = 0
  }
}

package struct CollectionScopeCallsite: Equatable {
  package let fileID: String
  package let line: UInt
}

package struct SelectionCallsite: Hashable, Equatable {
  package let fileID: String
  package let line: UInt
}

@MainActor
package final class CollectionScopeOffsetBox {
  package var offset: Int
  package var revision: UInt64

  package init(offset: Int, revision: UInt64 = 0) {
    self.offset = offset
    self.revision = revision
  }
}

/// Per-collection cache for stable row projections and their latest fast-path offsets.
@MainActor
package final class CollectionScopeCacheBucket {
  package let callsite: CollectionScopeCallsite
  package var storesByID: [AnyHashable: AnyObject] = [:]
  package var offsetsByID: [AnyHashable: CollectionScopeOffsetBox] = [:]
  package var revision: UInt64 = 0

  package init(callsite: CollectionScopeCallsite) {
    self.callsite = callsite
  }
}

/// CollectionScopeCache pins a single call site to each collection key path and
/// retains stable scoped-store identities for list rendering.
///
/// Invariants:
/// - one key path must map to one call site per Store instance
/// - `storesByID` and `offsetsByID` are pruned to currently live collection ids
@MainActor
package final class CollectionScopeCache {
  private var buckets: [AnyKeyPath: CollectionScopeCacheBucket] = [:]

  package init() {}

  package func validatedBucket(
    for keyPath: AnyKeyPath,
    callsite: CollectionScopeCallsite
  ) -> CollectionScopeCacheBucket {
    guard let bucket = buckets[keyPath] else {
      return .init(callsite: callsite)
    }

    guard bucket.callsite != callsite else {
      return bucket
    }

    #if DEBUG
      preconditionFailure(
        """
        scope(collection:action:) must use a single call site per collection key path for a given Store instance.
        Existing call site: \(bucket.callsite.fileID):\(bucket.callsite.line)
        New call site: \(callsite.fileID):\(callsite.line)
        """
      )
    #else
      return .init(callsite: callsite)
    #endif
  }

  package func store(_ bucket: CollectionScopeCacheBucket, for keyPath: AnyKeyPath) {
    buckets[keyPath] = bucket
  }
}

@MainActor
package final class SelectionCacheEntry {
  package let callsite: SelectionCallsite
  package let valueType: Any.Type
  package let selection: AnyObject

  package init(
    callsite: SelectionCallsite,
    valueType: Any.Type,
    selection: AnyObject
  ) {
    self.callsite = callsite
    self.valueType = valueType
    self.selection = selection
  }
}

/// SelectionCache retains stable `SelectedStore` identities per call site.
///
/// Invariants:
/// - one call site must map to one selection value type per owner instance
/// - cached selections stay alive for the lifetime of the owning store/projection
@MainActor
package final class SelectionCache {
  private var entries: [SelectionCallsite: SelectionCacheEntry] = [:]

  package init() {}

  package func cached<Value>(
    for callsite: SelectionCallsite,
    valueType: Value.Type
  ) -> SelectedStore<Value>? {
    guard let entry = entries[callsite] else { return nil }
    #if DEBUG
      precondition(
        entry.valueType == valueType,
        """
        select(...) must use a single value type per call site for a given Store or ScopedStore instance.
        Existing type: \(String(reflecting: entry.valueType))
        Requested type: \(String(reflecting: valueType))
        Call site: \(callsite.fileID):\(callsite.line)
        """
      )
    #endif
    return entry.selection as? SelectedStore<Value>
  }

  package func store<Value>(
    _ selection: SelectedStore<Value>,
    for callsite: SelectionCallsite,
    valueType: Value.Type
  ) {
    entries[callsite] = .init(
      callsite: callsite,
      valueType: valueType,
      selection: selection
    )
  }
}
