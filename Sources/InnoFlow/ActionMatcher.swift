// MARK: - ActionMatcher.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

/// A payload-aware action matcher used by declarative phase mapping.
public struct ActionMatcher<Action: Sendable, Payload: Sendable>: Sendable {
  public let match: @Sendable (Action) -> Payload?

  public init(_ match: @escaping @Sendable (Action) -> Payload?) {
    self.match = match
  }
}

extension ActionMatcher where Action: Equatable, Payload == Void {
  public static func action(_ action: Action) -> Self {
    .init { candidate in
      candidate == action ? () : nil
    }
  }
}

extension ActionMatcher {
  public static func casePath<Value: Sendable>(
    _ path: CasePath<Action, Value>
  ) -> ActionMatcher<Action, Value> {
    .init(path.extract)
  }
}
