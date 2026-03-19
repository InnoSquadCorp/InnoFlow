// MARK: - CollectionActionPath.swift
// InnoFlow - Collection Action Path Abstraction
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

/// A lightweight action path abstraction for identifiable child actions that
/// carry both an element id and a child action payload.
public struct CollectionActionPath<Root, ID, ChildAction>: Sendable {
  /// Embeds a child action for a specific element id back into the root action.
  public let embed: @Sendable (ID, ChildAction) -> Root

  /// Extracts an `(id, childAction)` pair from a root action when it matches.
  public let extract: @Sendable (Root) -> (ID, ChildAction)?

  /// Creates a collection action path from explicit embedding and extraction closures.
  public init(
    embed: @escaping @Sendable (ID, ChildAction) -> Root,
    extract: @escaping @Sendable (Root) -> (ID, ChildAction)?
  ) {
    self.embed = embed
    self.extract = extract
  }
}
