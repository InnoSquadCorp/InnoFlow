// MARK: - TestStoreInvariant.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

/// A named predicate checked after every state transition performed by TestStore.
public struct TestStoreInvariant<State: Equatable>: Sendable {
  public let name: String
  package let location: TestStoreSourceLocation
  package let predicate: @MainActor @Sendable (State) -> Bool

  public init(
    _ name: String,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column,
    predicate: @escaping @MainActor @Sendable (State) -> Bool
  ) {
    self.init(
      name, location: .init(fileID: fileID, filePath: filePath, line: line, column: column),
      predicate: predicate)
  }

  package init(
    _ name: String,
    location: TestStoreSourceLocation,
    predicate: @escaping @MainActor @Sendable (State) -> Bool
  ) {
    self.name = name
    self.location = location
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
