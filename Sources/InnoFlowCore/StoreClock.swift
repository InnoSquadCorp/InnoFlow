// MARK: - StoreClock.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

/// Runtime clock hooks used by `Store` for debounce, throttle, and time-window comparisons.
///
/// ## Cancellation contract
///
/// `sleep` MUST propagate `CancellationError` (or surface another error that
/// the surrounding `Task` treats as cancellation) when the calling task is
/// cancelled mid-sleep. The default `.continuous` adapter satisfies this by
/// using `Task.sleep(for:)`, which throws on cancellation.
///
/// `Store`'s debounce, throttle, and trailing-drain paths rely on this
/// contract: a cancelled sleep is treated as "the pending work was scheduled
/// away" and triggers `StoreInstrumentation.didDropAction(.throttledOrDebouncedCancellation)`
/// instead of executing the effect. Test clocks (e.g. `ManualTestClock`) must
/// follow the same contract or those code paths will leak work past the
/// intended cancellation boundary.
public struct StoreClock: Sendable {
  public typealias Instant = ContinuousClock.Instant

  /// Returns the current instant according to the store's scheduling clock.
  public let now: @Sendable () async -> Instant

  /// Suspends for the requested duration according to the store's scheduling clock.
  ///
  /// Implementations MUST throw on cancellation. See the type-level
  /// "Cancellation contract" section for the precise semantics the runtime
  /// depends on.
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
