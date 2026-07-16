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

/// User-facing assertion origin carried by testing effect contexts.
///
/// Production stores leave this `nil`. `TestStore` records the public action
/// assertion that created an effect so delayed and composed runs can report an
/// asynchronous failure at the initiating call site instead of whichever test
/// interaction happened most recently.
package struct EffectOrigin: Sendable {
  package let file: StaticString
  package let line: UInt

  package init(file: StaticString, line: UInt) {
    self.file = file
    self.line = line
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
  package let origin: EffectOrigin?

  package var cancellationID: AnyEffectID? {
    cancellationIDs.last
  }

  package init(
    cancellationID: AnyEffectID? = nil,
    cancellationIDs: [AnyEffectID]? = nil,
    animation: EffectAnimation? = nil,
    sequence: UInt64? = nil
  ) {
    self.init(
      cancellationID: cancellationID,
      cancellationIDs: cancellationIDs,
      animation: animation,
      sequence: sequence,
      origin: nil
    )
  }

  package init(
    cancellationID: AnyEffectID? = nil,
    cancellationIDs: [AnyEffectID]? = nil,
    animation: EffectAnimation? = nil,
    sequence: UInt64? = nil,
    origin: EffectOrigin?
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
    self.origin = origin
  }

  package static func withCancellation(
    _ id: AnyEffectID,
    on existing: Self?
  ) -> Self {
    .init(
      cancellationIDs: (existing?.cancellationIDs ?? []) + [id],
      animation: existing?.animation,
      sequence: existing?.sequence,
      origin: existing?.origin
    )
  }

  package static func withAnimation(
    _ animation: EffectAnimation,
    on existing: Self?
  ) -> Self {
    .init(
      cancellationIDs: existing?.cancellationIDs ?? [],
      animation: animation,
      sequence: existing?.sequence,
      origin: existing?.origin
    )
  }
}

extension EffectTask {
  package func applyingAnimation(_ animation: EffectAnimation) -> Self {
    .init(operation: .animation(effect: self, animation: animation))
  }
}
