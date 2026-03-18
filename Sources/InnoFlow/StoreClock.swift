// MARK: - StoreClock.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

/// Runtime clock hooks used by `Store` for debounce, throttle, and time-window comparisons.
public struct StoreClock: Sendable {
  public typealias Instant = ContinuousClock.Instant

  /// Returns the current instant according to the store's scheduling clock.
  public let now: @Sendable () async -> Instant

  /// Suspends for the requested duration according to the store's scheduling clock.
  public let sleep: @Sendable (Duration) async throws -> Void

  /// Creates a store clock from async `now` and `sleep` hooks.
  public init(
    now: @escaping @Sendable () async -> Instant,
    sleep: @escaping @Sendable (Duration) async throws -> Void
  ) {
    self.now = now
    self.sleep = sleep
  }

  /// The default wall-clock implementation backed by `ContinuousClock`.
  public static let continuous = Self(
    now: { ContinuousClock().now },
    sleep: { duration in
      try await Task.sleep(for: duration)
    }
  )
}
