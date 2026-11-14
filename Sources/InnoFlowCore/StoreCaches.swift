// MARK: - StoreCaches.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

private let singleScopeCachePeriodicCompactionIntervalDefault: UInt64 = 64

package struct SingleScopeCallsite: Hashable {
  package let fileID: String
  package let line: UInt
  package let column: UInt
}

package struct SingleScopeCacheKey: Hashable {
  package let callsite: SingleScopeCallsite
  package let stateKeyPath: AnyKeyPath
  package let childStateType: ObjectIdentifier
  package let childActionType: ObjectIdentifier
}

package struct CollectionScopeCacheSignature: Equatable {
  package let childStateType: ObjectIdentifier
  package let childActionType: ObjectIdentifier
  package let actionPathIdentity: ActionPathIdentity
}

package struct SelectionCallsite: Hashable, Equatable {
  package let fileID: String
  package let line: UInt
  package let column: UInt
}

package enum SelectionSignature: Hashable {
  case keyPath(AnyKeyPath)
  case singleDependency(AnyKeyPath)
  case dependencies([AnyKeyPath])
  /// Closure-only selection (no declared keypath dependencies). `memoized`
  /// reflects whether the cached observer compares snapshots before rerunning
  /// the selector — false maps to "always refresh", true to memoization. The
  /// boolean is part of the cache key so two `select(memoize:)` callsites
  /// with opposite memoize settings cannot collide on the same cache slot.
  case closureSelector(memoized: Bool)
}

package struct SelectionCacheKey: Hashable {
  package let callsite: SelectionCallsite
  package let signature: SelectionSignature
  package let semanticID: String?
  package let valueType: ObjectIdentifier?

  package init(
    callsite: SelectionCallsite,
    signature: SelectionSignature,
    semanticID: String?,
    valueType: ObjectIdentifier? = nil
  ) {
    self.callsite = callsite
    self.signature = signature
    self.semanticID = semanticID
    self.valueType = valueType
  }

  package func forValueType<Value>(_ type: Value.Type) -> Self {
    .init(
      callsite: callsite,
      signature: signature,
      semanticID: semanticID,
      valueType: ObjectIdentifier(type)
    )
  }
}

@MainActor
package final class SingleScopeCacheEntry {
  package weak var scope: AnyObject?

  package init(scope: AnyObject) {
    self.scope = scope
  }
}

/// Weakly caches live single-state projections by call site and projection
/// signature. The action-path token is retained strongly so manual reference
/// identity cannot collide through allocator address reuse after the caller
/// releases a path; generated tokens may compare by their stable macro key.
/// Matching buckets prune on every access; periodic cross-bucket maintenance
/// bounds dead metadata from signatures that are no longer requested.
@MainActor
package final class SingleScopeCache {
  private var entries: [SingleScopeCacheKey: [ActionPathIdentity: SingleScopeCacheEntry]] = [:]
  private let periodicCompactionInterval: UInt64
  private var accessCount: UInt64 = 0

  package init() {
    self.periodicCompactionInterval = singleScopeCachePeriodicCompactionIntervalDefault
  }

  package func cached<ParentReducer: Reducer, ChildState: Equatable, ChildAction>(
    for key: SingleScopeCacheKey,
    actionPathIdentity: ActionPathIdentity
  ) -> ScopedStore<ParentReducer, ChildState, ChildAction>? {
    compactIfNeeded()
    var bucket = prunedBucket(for: key)
    guard let entry = bucket[actionPathIdentity] else { return nil }

    guard
      let scope = entry.scope
        as? ScopedStore<ParentReducer, ChildState, ChildAction>
    else {
      bucket.removeValue(forKey: actionPathIdentity)
      update(bucket, for: key)
      return nil
    }

    return scope
  }

  package func store<ParentReducer: Reducer, ChildState: Equatable, ChildAction>(
    _ scope: ScopedStore<ParentReducer, ChildState, ChildAction>,
    for key: SingleScopeCacheKey,
    actionPathIdentity: ActionPathIdentity
  ) {
    var bucket = prunedBucket(for: key)
    bucket[actionPathIdentity] = .init(scope: scope)
    entries[key] = bucket
  }

  private func compactIfNeeded() {
    accessCount &+= 1
    guard accessCount.isMultiple(of: periodicCompactionInterval) else { return }

    for key in Array(entries.keys) {
      _ = prunedBucket(for: key)
    }
  }

  private func prunedBucket(
    for key: SingleScopeCacheKey
  ) -> [ActionPathIdentity: SingleScopeCacheEntry] {
    guard var bucket = entries[key] else { return [:] }
    guard bucket.values.contains(where: { $0.scope == nil }) else {
      return bucket
    }

    bucket = bucket.filter { $0.value.scope != nil }
    update(bucket, for: key)
    return bucket
  }

  private func update(
    _ bucket: [ActionPathIdentity: SingleScopeCacheEntry],
    for key: SingleScopeCacheKey
  ) {
    if bucket.isEmpty {
      entries.removeValue(forKey: key)
    } else {
      entries[key] = bucket
    }
  }
}

@MainActor
package final class CollectionScopeOffsetBox {
  /// Offset recorded for an element that the indexed collection does not
  /// contain. Valid only while the box's revision is the bucket's revision.
  package static let absent = -1

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
  package let signature: CollectionScopeCacheSignature
  package var storesByID: [AnyHashable: AnyObject] = [:]
  package var offsetsByID: [AnyHashable: CollectionScopeOffsetBox] = [:]
  package var revision: UInt64 = 0

  package init(signature: CollectionScopeCacheSignature) {
    self.signature = signature
  }

  package func removeStore(_ store: AnyObject, for id: AnyHashable) {
    guard let cachedStore = storesByID[id], cachedStore === store else { return }
    storesByID.removeValue(forKey: id)
    offsetsByID.removeValue(forKey: id)
  }

  /// Records the current offset of every row that still has an element and
  /// returns the elements whose rows can observe a difference: elements that
  /// changed value and elements that are gone.
  ///
  /// Starts a new revision. Every state change reaches the projection
  /// registry before any row resolves its element, and only a structural
  /// change can add or remove an element, so a box indexed by the current
  /// revision stays valid until the next structural change indexes again.
  /// Returns `nil` when the collection exposes no contiguous storage and
  /// every row has to be refreshed; removed rows then keep an outdated box
  /// and resolve through their linear fallback.
  package func reindex<CollectionState: Collection>(
    from previousCollection: CollectionState,
    to nextCollection: CollectionState
  ) -> [AnyHashable]?
  where CollectionState.Element: Equatable & Identifiable {
    let previousRevision = revision
    revision &+= 1
    guard !offsetsByID.isEmpty else { return [] }

    let affected = previousCollection.withContiguousStorageIfAvailable { previous in
      nextCollection.withContiguousStorageIfAvailable { next -> [AnyHashable] in
        var affectedElementIDs: [AnyHashable] = []
        for offset in 0..<next.count {
          let element = next[offset]
          let elementID = AnyHashable(element.id)
          guard let offsetBox = offsetsByID[elementID] else { continue }

          // The box still holds the element's offset in the previous
          // collection when it was indexed by the previous revision — unless
          // the rows were scoped again after the reduction and before this
          // pass, which indexes them against the next collection. Identical
          // bytes are the same element either way; otherwise the element at
          // that offset must be confirmed before its value is compared.
          let previousOffset = offsetBox.offset
          let isUnchanged =
            offsetBox.revision == previousRevision
            && previousOffset >= 0 && previousOffset < previous.count
            && (projectionElementsAreBitwiseEqual(previous, previousOffset, next, offset)
              || (previous[previousOffset].id == element.id
                && previous[previousOffset] == element))
          if !isUnchanged {
            affectedElementIDs.append(elementID)
          }
          offsetBox.offset = offset
          offsetBox.revision = revision
        }
        for (elementID, offsetBox) in offsetsByID where offsetBox.revision != revision {
          // The element is gone. Record that for this revision so its row
          // deactivates without scanning the collection for it.
          offsetBox.offset = CollectionScopeOffsetBox.absent
          offsetBox.revision = revision
          affectedElementIDs.append(elementID)
        }
        return affectedElementIDs
      }
    }
    if case .some(.some(let affectedElementIDs)) = affected {
      return affectedElementIDs
    }

    for (offset, element) in nextCollection.enumerated() {
      guard let offsetBox = offsetsByID[AnyHashable(element.id)] else { continue }
      offsetBox.offset = offset
      offsetBox.revision = revision
    }
    return nil
  }
}

/// Whether two stored elements have identical bytes.
///
/// Identical bytes mean identical stored properties and identical references
/// to any out-of-line storage, so the elements are the same value and a row
/// showing one cannot observe a difference from the other. The check is only
/// ever used to skip work: elements that differ in bytes are still compared
/// with `==`, which also covers padding that happens to differ. The one
/// deliberate consequence is for irreflexive values such as a `Double` NaN:
/// an element that did not change is treated as unchanged even though `==`
/// would call it different from itself.
package func projectionElementsAreBitwiseEqual<Element>(
  _ lhs: UnsafeBufferPointer<Element>,
  _ lhsOffset: Int,
  _ rhs: UnsafeBufferPointer<Element>,
  _ rhsOffset: Int
) -> Bool {
  let size = MemoryLayout<Element>.size
  guard size > 0 else { return true }
  guard let lhsBase = lhs.baseAddress, let rhsBase = rhs.baseAddress else { return false }
  return memcmp(
    UnsafeRawPointer(lhsBase + lhsOffset),
    UnsafeRawPointer(rhsBase + rhsOffset),
    size
  ) == 0
}

/// CollectionScopeCache pins one active projection signature to each
/// collection key path while retaining stable scoped-store identities for list
/// rendering.
///
/// Invariants:
/// - a matching signature reuses the complete row family
/// - changing the child types or action-path identity replaces it
/// - `storesByID` and `offsetsByID` are pruned to currently live collection ids
/// - a row deactivation evicts its matching cache entry during the same parent refresh
@MainActor
package final class CollectionScopeCache {
  private var buckets: [AnyKeyPath: CollectionScopeCacheBucket] = [:]

  package init() {}

  package func bucket(
    for keyPath: AnyKeyPath,
    signature: CollectionScopeCacheSignature
  ) -> CollectionScopeCacheBucket {
    guard let bucket = buckets[keyPath], bucket.signature == signature else {
      return .init(signature: signature)
    }

    return bucket
  }

  package func store(_ bucket: CollectionScopeCacheBucket, for keyPath: AnyKeyPath) {
    buckets[keyPath] = bucket
  }

  /// The row family currently cached for a collection key path, if any.
  package func activeBucket(for keyPath: AnyKeyPath) -> CollectionScopeCacheBucket? {
    buckets[keyPath]
  }
}

@MainActor
package final class SelectionCacheEntry {
  package let key: SelectionCacheKey
  package let valueType: Any.Type
  private var strongSelection: AnyObject?
  private weak var weakSelection: AnyObject?

  package var selection: AnyObject? { weakSelection }

  package init(
    key: SelectionCacheKey,
    valueType: Any.Type,
    selection: AnyObject
  ) {
    self.key = key
    self.valueType = valueType
    self.weakSelection = selection
  }

  /// Keeps the selection alive on behalf of a tracked read that has not been
  /// notified yet.
  package func retainSelection() {
    strongSelection = weakSelection
  }

  package func releaseSelection() {
    strongSelection = nil
  }
}

/// SelectionCache gives a selection one identity per owner-local call site,
/// signature, semantic ID and value type while that selection is alive.
///
/// Invariants:
/// - every entry references its selection weakly; an external handle always
///   keeps the identity alive
/// - a key-path selection is additionally retained by its entry from a tracked
///   read until the notification that consumes it, so a transient SwiftUI body
///   read (`store.select(\.count).requireAlive()`) still invalidates the view
/// - a key-path selection that is never read, or that is notified twice
///   without being read again, is released; the owner never keeps evaluating a
///   key path nobody can observe
/// - semantic closure selections are reused only while an external handle lives
/// - keyless closures are never cached
///
/// Key paths and explicit semantic IDs may both be dynamic, so released
/// entries are periodically compacted instead of growing for the owner's
/// entire lifetime.
@MainActor
package final class SelectionCache {
  private var entries: [SelectionCacheKey: SelectionCacheEntry] = [:]
  private var accessCount: UInt64 = 0

  package init() {}

  package func cached<Value>(
    for key: SelectionCacheKey,
    valueType: Value.Type
  ) -> SelectedStore<Value>? {
    compactIfNeeded()
    guard let entry = entries[key] else { return nil }
    guard let selection = entry.selection else {
      entries.removeValue(forKey: key)
      return nil
    }
    precondition(
      entry.valueType == valueType,
      """
      select(...) must use a single value type per call site and selection signature for a given Store or ScopedStore instance.
      Existing type: \(String(reflecting: entry.valueType))
      Requested type: \(String(reflecting: valueType))
      Call site: \(key.callsite.fileID):\(key.callsite.line):\(key.callsite.column)
      """
    )
    return selection as? SelectedStore<Value>
  }

  package func store<Value>(
    _ selection: SelectedStore<Value>,
    for key: SelectionCacheKey,
    valueType: Value.Type
  ) {
    compactIfNeeded()
    let entry = SelectionCacheEntry(key: key, valueType: valueType, selection: selection)
    entries[key] = entry
    if key.semanticID == nil {
      selection.retainWhileObserved(by: entry)
    }
  }

  package var entryCount: Int { entries.count }

  private func compactIfNeeded() {
    accessCount &+= 1
    guard accessCount % 64 == 0 else { return }
    entries = entries.filter { $0.value.selection != nil }
  }
}
