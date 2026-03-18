// MARK: - StoreClock.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

/// Runtime clock hooks used by `Store` for debounce, throttle, and time-window comparisons.
public struct StoreClock: Sendable {
  public typealias Instant = ContinuousClock.Instant

  public let now: @Sendable () async -> Instant
  public let sleep: @Sendable (Duration) async throws -> Void

  public init(
    now: @escaping @Sendable () async -> Instant,
    sleep: @escaping @Sendable (Duration) async throws -> Void
  ) {
    self.now = now
    self.sleep = sleep
  }

  public static let continuous = Self(
    now: { ContinuousClock().now },
    sleep: { duration in
      try await Task.sleep(for: duration)
    }
  )
}
