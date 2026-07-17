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
  package let cancellationScope: EffectCancellationScope?
  private let cancellationTokens: [EffectCancellationToken]
  private let interpreterLease: EffectInterpreterLease?
  package let animation: EffectAnimation?
  /// Store/TestStore sequence number for cancellation boundary tracking.
  package let sequence: UInt64?
  package let origin: EffectOrigin?

  package var cancellationID: AnyEffectID? {
    cancellationIDs.last
  }

  private init(
    cancellationID: AnyEffectID? = nil,
    cancellationIDs: [AnyEffectID]? = nil,
    cancellationScope: EffectCancellationScope? = nil,
    cancellationTokens: [EffectCancellationToken] = [],
    interpreterLease: EffectInterpreterLease? = nil,
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
    self.cancellationScope = cancellationScope
    self.cancellationTokens = cancellationTokens
    self.interpreterLease = interpreterLease
    self.animation = animation
    self.sequence = sequence
    self.origin = origin
  }

  package static func managedRoot(
    cancellationScope: EffectCancellationScope,
    interpreterLease: EffectInterpreterLease,
    animation: EffectAnimation? = nil,
    sequence: UInt64,
    origin: EffectOrigin? = nil
  ) -> Self {
    .init(
      cancellationScope: cancellationScope,
      cancellationTokens: [],
      interpreterLease: interpreterLease,
      animation: animation,
      sequence: sequence,
      origin: origin
    )
  }

  /// Numeric-only context for immediate instrumentation and isolated driver tests.
  ///
  /// This context has no cancellation ownership and must never be used to model
  /// cancellable work. Store/TestStore execution uses `managedRoot` factories.
  package static func unmanaged(
    animation: EffectAnimation? = nil,
    sequence: UInt64? = nil
  ) -> Self {
    .init(
      animation: animation,
      sequence: sequence,
      origin: nil
    )
  }

  package static func withCancellation(
    _ id: AnyEffectID,
    on existing: Self?
  ) -> Self {
    precondition(
      existing?.cancellationScope == nil || existing?.interpreterLease != nil,
      "A frozen effect execution context cannot resume structural interpretation"
    )
    let token = existing?.cancellationScope?.token(for: id)
    return .init(
      cancellationIDs: (existing?.cancellationIDs ?? []) + [id],
      cancellationScope: existing?.cancellationScope,
      cancellationTokens: (existing?.cancellationTokens ?? []) + (token.map { [$0] } ?? []),
      interpreterLease: existing?.interpreterLease,
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
      cancellationScope: existing?.cancellationScope,
      cancellationTokens: existing?.cancellationTokens ?? [],
      interpreterLease: existing?.interpreterLease,
      animation: animation,
      sequence: existing?.sequence,
      origin: existing?.origin
    )
  }

  package var shouldProceed: Bool {
    guard cancellationScope?.isGloballyCancelled != true else { return false }
    return cancellationTokens.allSatisfy { $0.isCancelled == false }
  }

  /// Returns a terminal execution context that cannot discover new IDs.
  ///
  /// Runs and queued actions retain their exact cancellation tokens and global
  /// sequence scope, but intentionally release structural interpreter ownership.
  package func frozenForExecution() -> Self {
    .init(
      cancellationIDs: cancellationIDs,
      cancellationScope: cancellationScope,
      cancellationTokens: cancellationTokens,
      interpreterLease: nil,
      animation: animation,
      sequence: sequence,
      origin: origin
    )
  }

  package func isCancelled(id: AnyEffectID) -> Bool {
    cancellationScope?.isCancelled(id: id) == true
  }
}

extension EffectTask {
  package func applyingAnimation(_ animation: EffectAnimation) -> Self {
    .init(operation: .animation(effect: self, animation: animation))
  }
}
