// MARK: - CollectionActionPath.swift
// InnoFlow - Collection Action Path Abstraction
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

/// A lightweight action path abstraction for identifiable child actions that
/// carry both an element id and a child action payload.
public struct CollectionActionPath<Root, ID, ChildAction>: Sendable {
  public let embed: @Sendable (ID, ChildAction) -> Root
  public let extract: @Sendable (Root) -> (ID, ChildAction)?

  public init(
    embed: @escaping @Sendable (ID, ChildAction) -> Root,
    extract: @escaping @Sendable (Root) -> (ID, ChildAction)?
  ) {
    self.embed = embed
    self.extract = extract
  }
}
