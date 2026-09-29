// MARK: - TestStoreInvariant.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

/// A named predicate checked after every state transition performed by TestStore.
public struct TestStoreInvariant<State: Equatable>: Sendable {
  public let name: String
  package let file: StaticString
  package let line: UInt
  package let predicate: @MainActor @Sendable (State) -> Bool

  public init(
    _ name: String,
    file: StaticString = #filePath,
    line: UInt = #line,
    predicate: @escaping @MainActor @Sendable (State) -> Bool
  ) {
    self.name = name
    self.file = file
    self.line = line
    self.predicate = predicate
  }
}

package enum TestStoreReductionSource: String, Sendable {
  case send
  case receive
  case scopedSend
  case scopedReceive
  case automatic
}
