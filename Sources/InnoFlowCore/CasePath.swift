// MARK: - CasePath.swift
// InnoFlow - CasePath Abstraction
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

/// A lightweight case path abstraction for embedding and extracting enum actions.
public struct CasePath<Root, Value>: Sendable {
  public let embed: @Sendable (Value) -> Root
  public let extract: @Sendable (Root) -> Value?

  public init(
    embed: @escaping @Sendable (Value) -> Root,
    extract: @escaping @Sendable (Root) -> Value?
  ) {
    self.embed = embed
    self.extract = extract
  }
}
