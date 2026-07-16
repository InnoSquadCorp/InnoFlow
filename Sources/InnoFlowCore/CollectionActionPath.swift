// MARK: - CollectionActionPath.swift
// InnoFlow - Collection Action Path Abstraction
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

/// A lightweight action path abstraction for identifiable child actions that
/// carry both an element id and a child action payload.
///
/// Value copies preserve one opaque runtime identity. Independently
/// constructed paths have distinct identities so collection scope caches never
/// reuse a row store with an outdated action transform. `@InnoFlow`-generated
/// computed paths recreate a stable identity for the same specialized root and
/// private generated marker.
public struct CollectionActionPath<Root, ID, ChildAction>: Sendable {
  /// Embeds a child action for a specific element id back into the root action.
  public let embed: @Sendable (ID, ChildAction) -> Root

  /// Extracts an `(id, childAction)` pair from a root action when it matches.
  public let extract: @Sendable (Root) -> (ID, ChildAction)?

  package let identity: ActionPathIdentity

  /// Creates a collection action path from explicit embedding and extraction closures.
  public init(
    embed: @escaping @Sendable (ID, ChildAction) -> Root,
    extract: @escaping @Sendable (Root) -> (ID, ChildAction)?
  ) {
    self.init(
      embed: embed,
      extract: extract,
      identity: ActionPathIdentity()
    )
  }

  /// Framework hook used by `@InnoFlow` for generated computed action paths.
  ///
  /// Application code should use ``init(embed:extract:)`` so independently
  /// constructed transforms retain independent cache identities.
  @_documentation(visibility: internal)
  public static func _innoFlowGenerated<Marker>(
    marker: Marker.Type,
    embed: @escaping @Sendable (ID, ChildAction) -> Root,
    extract: @escaping @Sendable (Root) -> (ID, ChildAction)?
  ) -> Self {
    Self(
      embed: embed,
      extract: extract,
      identity: ActionPathIdentity.generatedCollectionActionPath(
        root: Root.self,
        marker: marker
      )
    )
  }

  private init(
    embed: @escaping @Sendable (ID, ChildAction) -> Root,
    extract: @escaping @Sendable (Root) -> (ID, ChildAction)?,
    identity: ActionPathIdentity
  ) {
    self.embed = embed
    self.extract = extract
    self.identity = identity
  }
}
