// MARK: - EffectExecutionContext.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

package struct EffectAnimation: Sendable, CustomStringConvertible {
  private let performer: @MainActor @Sendable (_ updates: () -> Void) -> Void
  package let description: String

  package init(
    description: String,
    perform: @escaping @MainActor @Sendable (_ updates: () -> Void) -> Void
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
  package let cancellationIDs: [AnyEffectID]
  package let animation: EffectAnimation?
  /// Store/TestStore sequence number for cancellation boundary tracking.
  package let sequence: UInt64?

  package var cancellationID: AnyEffectID? {
    cancellationIDs.last
  }

  package init(
    cancellationID: AnyEffectID? = nil,
    cancellationIDs: [AnyEffectID]? = nil,
    animation: EffectAnimation? = nil,
    sequence: UInt64? = nil
  ) {
    if let cancellationIDs {
      self.cancellationIDs = cancellationIDs
    } else if let cancellationID {
      self.cancellationIDs = [cancellationID]
    } else {
      self.cancellationIDs = []
    }
    self.animation = animation
    self.sequence = sequence
  }

  package static func withCancellation(
    _ id: AnyEffectID,
    on existing: Self?
  ) -> Self {
    .init(
      cancellationIDs: (existing?.cancellationIDs ?? []) + [id],
      animation: existing?.animation,
      sequence: existing?.sequence
    )
  }

  package static func withAnimation(
    _ animation: EffectAnimation,
    on existing: Self?
  ) -> Self {
    .init(
      cancellationIDs: existing?.cancellationIDs ?? [],
      animation: animation,
      sequence: existing?.sequence
    )
  }
}

extension EffectTask {
  package func applyingAnimation(_ animation: EffectAnimation) -> Self {
    .init(operation: .animation(effect: self, animation: animation))
  }
}
