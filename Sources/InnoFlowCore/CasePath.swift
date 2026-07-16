// MARK: - CasePath.swift
// InnoFlow - CasePath Abstraction
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

/// A lightweight case path abstraction for embedding and extracting enum actions.
///
/// Independently constructed paths have distinct cache identities, while
/// `@InnoFlow`-generated computed paths recreate a stable identity for the same
/// specialized root and private generated marker.
public struct CasePath<Root, Value>: Sendable {
  public let embed: @Sendable (Value) -> Root
  public let extract: @Sendable (Root) -> Value?
  package let identity: ActionPathIdentity

  public init(
    embed: @escaping @Sendable (Value) -> Root,
    extract: @escaping @Sendable (Root) -> Value?
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
    embed: @escaping @Sendable (Value) -> Root,
    extract: @escaping @Sendable (Root) -> Value?
  ) -> Self {
    Self(
      embed: embed,
      extract: extract,
      identity: ActionPathIdentity.generatedCasePath(root: Root.self, marker: marker)
    )
  }

  private init(
    embed: @escaping @Sendable (Value) -> Root,
    extract: @escaping @Sendable (Root) -> Value?,
    identity: ActionPathIdentity
  ) {
    self.embed = embed
    self.extract = extract
    self.identity = identity
  }
}
