// MARK: - EffectExecutionContext.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

package struct EffectAnimation: @unchecked Sendable, CustomStringConvertible {
  private let performer: @MainActor (_ updates: () -> Void) -> Void
  package let description: String

  package init(
    description: String,
    perform: @escaping @MainActor (_ updates: () -> Void) -> Void
  ) {
    self.description = description
    self.performer = perform
  }

  @MainActor
  package func perform(_ updates: () -> Void) {
    performer(updates)
  }
}

/// Shared context passed through effect interpretation in both `Store` and `TestStore`.
///
/// Extracted to eliminate duplication between production and testing runtimes.
package struct EffectExecutionContext: Sendable {
  package let cancellationID: AnyEffectID?
  package let animation: EffectAnimation?
  /// Store/TestStore sequence number for cancellation boundary tracking.
  package let sequence: UInt64?

  package init(
    cancellationID: AnyEffectID? = nil,
    animation: EffectAnimation? = nil,
    sequence: UInt64? = nil
  ) {
    self.cancellationID = cancellationID
    self.animation = animation
    self.sequence = sequence
  }

  package static func withCancellation(
    _ id: AnyEffectID,
    on existing: Self?
  ) -> Self {
    .init(cancellationID: id, animation: existing?.animation, sequence: existing?.sequence)
  }

  package static func withAnimation(
    _ animation: EffectAnimation,
    on existing: Self?
  ) -> Self {
    .init(
      cancellationID: existing?.cancellationID, animation: animation, sequence: existing?.sequence)
  }
}

extension EffectTask {
  package func applyingAnimation(_ animation: EffectAnimation) -> Self {
    .init(operation: .animation(effect: self, animation: animation))
  }
}
