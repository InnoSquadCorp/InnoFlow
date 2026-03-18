// MARK: - EffectTask+SwiftUI.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import SwiftUI

package struct EffectAnimation: Sendable {
  package let rawValue: Animation?

  package init(_ rawValue: Animation?) {
    self.rawValue = rawValue
  }

  @MainActor
  package func perform(_ updates: () -> Void) {
    withAnimation(rawValue, updates)
  }
}

/// Shared context passed through effect interpretation in both `Store` and `TestStore`.
///
/// Extracted to eliminate duplication between production and testing runtimes.
package struct EffectExecutionContext: Sendable {
  package let cancellationID: EffectID?
  package let animation: EffectAnimation?
  /// Store-specific sequence number for cancellation boundary tracking.
  /// Nil in TestStore contexts.
  package let sequence: UInt64?

  package init(
    cancellationID: EffectID? = nil,
    animation: EffectAnimation? = nil,
    sequence: UInt64? = nil
  ) {
    self.cancellationID = cancellationID
    self.animation = animation
    self.sequence = sequence
  }

  package static func withCancellation(
    _ id: EffectID,
    on existing: Self?
  ) -> Self {
    .init(cancellationID: id, animation: existing?.animation, sequence: existing?.sequence)
  }

  package static func withAnimation(
    _ animation: EffectAnimation,
    on existing: Self?
  ) -> Self {
    .init(cancellationID: existing?.cancellationID, animation: animation, sequence: existing?.sequence)
  }
}

extension EffectTask {
  package func applyingAnimation(_ animation: EffectAnimation) -> Self {
    .init(operation: .animation(effect: self, animation: animation))
  }

  /// Applies animation to state changes caused by actions emitted from this effect.
  public func animation(_ animation: Animation? = .default) -> Self {
    applyingAnimation(.init(animation))
  }
}
