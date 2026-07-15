// MARK: - Exhaustivity.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

/// Controls how completely ``TestStore`` verifies state transitions.
public enum Exhaustivity: Equatable, Sendable {
  /// Requires every state mutation to be asserted.
  case on

  /// Allows partial state assertions.
  ///
  /// Set `showSkippedAssertions` to `true` to record non-failing warnings for
  /// state transitions checked in non-exhaustive mode.
  case off(showSkippedAssertions: Bool)

  /// Non-exhaustive testing without skipped-assertion warnings.
  public static let off = Self.off(showSkippedAssertions: false)
}

extension Exhaustivity {
  package var isOn: Bool {
    self == .on
  }

  package var showsSkippedAssertions: Bool {
    guard case .off(let showSkippedAssertions) = self else { return false }
    return showSkippedAssertions
  }
}
