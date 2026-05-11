// MARK: - EffectContext+Testing.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
@_exported public import InnoFlowCore

extension EffectContext {
  /// Builds an `EffectContext` suitable for direct invocation of effect operations
  /// inside unit tests, without going through a `Store` or `TestStore`.
  ///
  /// - Parameters:
  ///   - clock: A clock controlling `now()` and `sleep(for:)`. Defaults to a fresh
  ///     `ManualTestClock` so tests can advance time deterministically.
  ///   - isCancellationRequested: Cancellation probe. Defaults to never-cancel.
  ///   - errorReporter: Receives non-cancellation errors thrown by `AsyncSequence`
  ///     run effects. Defaults to a no-op.
  public static func testing(
    clock: ManualTestClock = ManualTestClock(),
    isCancellationRequested: @escaping @Sendable () async -> Bool = { false },
    errorReporter: @escaping @Sendable (any Error) async -> Void = { _ in }
  ) -> EffectContext {
    EffectContext(
      now: { await clock.now },
      sleep: { duration in try await clock.sleep(for: duration) },
      isCancellationRequested: isCancellationRequested,
      errorReporter: errorReporter
    )
  }
}
