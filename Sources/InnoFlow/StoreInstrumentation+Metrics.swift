// MARK: - StoreInstrumentation+Metrics.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
public import os

/// A snapshot of effect-runtime metrics observed by
/// ``StoreInstrumentationMetricsCollector``.
///
/// Snapshots are value types so they can be copied across actor boundaries
/// without locking. Use the snapshot for assertions or for forwarding to a
/// metrics backend.
public struct StoreInstrumentationMetricsSnapshot: Sendable, Equatable {
  public var runStarted: Int = 0
  public var runFinished: Int = 0
  public var runFailed: Int = 0
  public var actionEmitted: Int = 0
  public var actionDropped: Int = 0
  public var effectsCancelled: Int = 0

  public init() {}

  public init(
    runStarted: Int = 0,
    runFinished: Int = 0,
    runFailed: Int = 0,
    actionEmitted: Int = 0,
    actionDropped: Int = 0,
    effectsCancelled: Int = 0
  ) {
    self.runStarted = runStarted
    self.runFinished = runFinished
    self.runFailed = runFailed
    self.actionEmitted = actionEmitted
    self.actionDropped = actionDropped
    self.effectsCancelled = effectsCancelled
  }
}

/// Reference-semantics counter that aggregates `StoreInstrumentation` events
/// into a `StoreInstrumentationMetricsSnapshot`.
///
/// Designed to be paired with one or more stores via `instrumentation()` —
/// the collector exposes a `Sendable` instrumentation value that increments
/// internal counters under an `OSAllocatedUnfairLock`. Call `snapshot()` from
/// any thread (or `.combined(...)` it with other adapters) to read the
/// running totals as an immutable value.
///
/// Pairing pattern:
///
/// ```swift
/// let metrics = StoreInstrumentationMetricsCollector<Feature.Action>()
/// let store = Store(
///   reducer: Feature(),
///   initialState: .init(),
///   instrumentation: .combined(
///     metrics.instrumentation(),
///     .osLog(logger: logger)
///   )
/// )
///
/// // ... later ...
/// let snap = metrics.snapshot()
/// metricsBackend.gauge("innoflow.run.failed", value: snap.runFailed)
/// ```
public final class StoreInstrumentationMetricsCollector<Action: Sendable>: Sendable {
  private let storage = OSAllocatedUnfairLock<StoreInstrumentationMetricsSnapshot>(
    initialState: .init()
  )

  public init() {}

  /// Returns a copy of the current counters.
  public func snapshot() -> StoreInstrumentationMetricsSnapshot {
    storage.withLock { $0 }
  }

  /// Resets every counter to zero. Useful for testing or per-window metric
  /// collection.
  public func reset() {
    storage.withLock { $0 = .init() }
  }

  /// A `StoreInstrumentation` value that increments the collector's counters
  /// for every observed event.
  public func instrumentation() -> StoreInstrumentation<Action> {
    let storage = self.storage
    return .sink { event in
      storage.withLock { snapshot in
        switch event {
        case .runStarted:
          snapshot.runStarted += 1
        case .runFinished:
          snapshot.runFinished += 1
        case .runFailed:
          snapshot.runFailed += 1
        case .actionEmitted:
          snapshot.actionEmitted += 1
        case .actionDropped:
          snapshot.actionDropped += 1
        case .effectsCancelled:
          snapshot.effectsCancelled += 1
        }
      }
    }
  }
}
