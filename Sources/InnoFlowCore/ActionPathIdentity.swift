// MARK: - ActionPathIdentity.swift
// InnoFlow - Action Path Identity
// Copyright © 2025 InnoSquad. All rights reserved.

/// Opaque identity shared by value copies of an action path.
///
/// Manually constructed paths use reference identity. Macro-generated
/// computed paths use a stable root-type/marker key so generic accessors can
/// recreate the value without invalidating runtime caches.
package final class ActionPathIdentity: Hashable, Sendable {
  private enum GeneratedKind: UInt8, Hashable, Sendable {
    case casePath
    case collectionActionPath
  }

  private struct GeneratedKey: Hashable, Sendable {
    let rootType: ObjectIdentifier
    let kind: GeneratedKind
    let markerType: ObjectIdentifier
  }

  private let generatedKey: GeneratedKey?

  package init() {
    generatedKey = nil
  }

  private init(generatedKey: GeneratedKey) {
    self.generatedKey = generatedKey
  }

  package static func generatedCasePath<Root, Marker>(
    root: Root.Type,
    marker: Marker.Type
  ) -> ActionPathIdentity {
    generated(root: root, kind: .casePath, marker: marker)
  }

  package static func generatedCollectionActionPath<Root, Marker>(
    root: Root.Type,
    marker: Marker.Type
  ) -> ActionPathIdentity {
    generated(root: root, kind: .collectionActionPath, marker: marker)
  }

  package static func == (lhs: ActionPathIdentity, rhs: ActionPathIdentity) -> Bool {
    switch (lhs.generatedKey, rhs.generatedKey) {
    case (.none, .none):
      return lhs === rhs
    case (.some(let lhsKey), .some(let rhsKey)):
      return lhsKey == rhsKey
    case (.none, .some), (.some, .none):
      return false
    }
  }

  package func hash(into hasher: inout Hasher) {
    if let generatedKey {
      hasher.combine(GeneratedIdentityDiscriminator.generated)
      hasher.combine(generatedKey)
    } else {
      hasher.combine(GeneratedIdentityDiscriminator.manual)
      hasher.combine(ObjectIdentifier(self))
    }
  }

  private static func generated<Root, Marker>(
    root: Root.Type,
    kind: GeneratedKind,
    marker: Marker.Type
  ) -> ActionPathIdentity {
    ActionPathIdentity(
      generatedKey: GeneratedKey(
        rootType: ObjectIdentifier(root),
        kind: kind,
        markerType: ObjectIdentifier(marker)
      )
    )
  }

  private enum GeneratedIdentityDiscriminator: UInt8, Hashable, Sendable {
    case manual
    case generated
  }
}
