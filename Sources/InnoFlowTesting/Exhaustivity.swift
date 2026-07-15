// MARK: - Exhaustivity.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

/// Controls how completely ``TestStore`` verifies state transitions and
/// effect-emitted actions.
public enum Exhaustivity: Equatable, Sendable {
  /// Requires every state mutation and effect-emitted action to be asserted.
  case on

  /// Allows partial state assertions and automatically reduces unexpected
  /// effect-emitted actions.
  ///
  /// Set `showSkippedAssertions` to `true` to record non-failing warnings for
  /// state transitions and actions checked in non-exhaustive mode.
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
