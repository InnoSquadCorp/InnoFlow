// MARK: - StoreCaches.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

package struct CollectionScopeCallsite: Equatable {
  package let fileID: String
  package let line: UInt
  package let column: UInt
}

package struct SelectionCallsite: Hashable, Equatable {
  package let fileID: String
  package let line: UInt
  package let column: UInt
}

package enum SelectionSignature: Hashable {
  case keyPath(AnyKeyPath)
  case dependencies([AnyKeyPath])
  case alwaysRefresh(memoized: Bool)
}

package struct SelectionCacheKey: Hashable {
  package let callsite: SelectionCallsite
  package let signature: SelectionSignature
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

    preconditionFailure(
      """
      scope(collection:action:) must use a single call site per collection key path for a given Store instance.
      Existing call site: \(bucket.callsite.fileID):\(bucket.callsite.line):\(bucket.callsite.column)
      New call site: \(callsite.fileID):\(callsite.line):\(callsite.column)
      """
    )
  }

  package func store(_ bucket: CollectionScopeCacheBucket, for keyPath: AnyKeyPath) {
    buckets[keyPath] = bucket
  }
}

@MainActor
package final class SelectionCacheEntry {
  package let key: SelectionCacheKey
  package let valueType: Any.Type
  package let selection: AnyObject

  package init(
    key: SelectionCacheKey,
    valueType: Any.Type,
    selection: AnyObject
  ) {
    self.key = key
    self.valueType = valueType
    self.selection = selection
  }
}

/// SelectionCache retains stable `SelectedStore` identities per call site and selection signature.
///
/// Invariants:
/// - one call site/signature must map to one selection value type per owner instance
/// - cached selections stay alive for the lifetime of the owning store/projection
@MainActor
package final class SelectionCache {
  private var entries: [SelectionCacheKey: SelectionCacheEntry] = [:]

  package init() {}

  package func cached<Value>(
    for key: SelectionCacheKey,
    valueType: Value.Type
  ) -> SelectedStore<Value>? {
    guard let entry = entries[key] else { return nil }
    precondition(
      entry.valueType == valueType,
      """
      select(...) must use a single value type per call site and selection signature for a given Store or ScopedStore instance.
      Existing type: \(String(reflecting: entry.valueType))
      Requested type: \(String(reflecting: valueType))
      Call site: \(key.callsite.fileID):\(key.callsite.line):\(key.callsite.column)
      """
    )
    return entry.selection as? SelectedStore<Value>
  }

  package func store<Value>(
    _ selection: SelectedStore<Value>,
    for key: SelectionCacheKey,
    valueType: Value.Type
  ) {
    entries[key] = .init(
      key: key,
      valueType: valueType,
      selection: selection
    )
  }
}
