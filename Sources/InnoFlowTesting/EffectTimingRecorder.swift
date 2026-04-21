// MARK: - EffectTimingRecorder.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.
//
// A test-only recorder that captures the timeline of `StoreInstrumentation`
// events (run lifecycle, action emission, cancellation) and serialises them
// to JSONL. The companion `scripts/compare-effect-timings.sh` compares a
// fresh run against a committed baseline so release-mode scheduling
// regressions (the class of failure that caused the 2026-04 `sleeperCount`
// fixes) surface in CI rather than in ad-hoc manual runs.

import Foundation
import InnoFlow
import os

/// Captures `StoreInstrumentation` events with monotonic nanosecond timestamps
/// so performance regressions in effect scheduling / completion timing can be
/// detected by a baseline comparison.
///
/// The recorder is an actor — its `entries()` accessor and `dumpJSONL(to:)`
/// method are safe to call concurrently with ongoing recording. The
/// `instrumentation()` factory returns a `StoreInstrumentation<Action>` value
/// that can be passed directly to `Store(reducer:..., instrumentation:)`.
public actor EffectTimingRecorder {
  /// Phase of the recorded event, mirroring `StoreInstrumentationEvent` but
  /// flattened into a single enum that can be serialised.
  public enum Phase: String, Codable, Sendable {
    case runStarted
    case runFinished
    case actionEmitted
    case actionDropped
    case effectsCancelled
  }

  /// A single observation. `timestampNanos` is measured from
  /// ``EffectTimingRecorder.start`` using `ContinuousClock`, so values are
  /// monotonic and comparable across the same recorder instance only.
  public struct Entry: Codable, Equatable, Sendable {
    public let phase: Phase
    public let sequence: UInt64
    public let effectID: String?
    public let actionLabel: String?
    public let timestampNanos: UInt64

    public init(
      phase: Phase,
      sequence: UInt64,
      effectID: String?,
      actionLabel: String?,
      timestampNanos: UInt64
    ) {
      self.phase = phase
      self.sequence = sequence
      self.effectID = effectID
      self.actionLabel = actionLabel
      self.timestampNanos = timestampNanos
    }
  }

  private struct StoredEntry: Sendable {
    let ordering: UInt64
    let entry: Entry
  }

  private struct StorageState: Sendable {
    var nextOrdering: UInt64 = 0
    var recordedEntries: [StoredEntry] = []
  }

  private let clock = ContinuousClock()
  private let startedAt: ContinuousClock.Instant
  private let storage = OSAllocatedUnfairLock(initialState: StorageState())

  public init() {
    self.startedAt = ContinuousClock().now
  }

  // MARK: - Public API

  /// Returns a snapshot of all entries recorded so far, ordered by the
  /// instrumentation callback sequence that captured them.
  public func entries() -> [Entry] {
    snapshotEntries()
  }

  /// Writes every recorded entry as a newline-delimited JSON stream. Existing
  /// contents of `url` are replaced.
  public func dumpJSONL(to url: URL) throws {
    let entries = snapshotEntries()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    var payload = Data()
    for entry in entries {
      let encoded = try encoder.encode(entry)
      payload.append(encoded)
      payload.append(0x0A)  // '\n'
    }

    try payload.write(to: url, options: .atomic)
  }

  /// Factory for a `StoreInstrumentation<Action>` that funnels every
  /// `Store` event through this recorder.
  ///
  /// Each event captures its `timestampNanos` **synchronously inside the
  /// instrumentation callback**, then writes the pre-captured stamp into a
  /// lock-backed buffer with a stable ordering token. This keeps timing
  /// measurements faithful to the `Store` event order even under heavy
  /// scheduler contention while making `entries()` / `dumpJSONL(to:)`
  /// deterministic and complete.
  public nonisolated func instrumentation<Action: Sendable>() -> StoreInstrumentation<Action> {
    let recorder = self
    let startedAt = self.startedAt
    let clock = self.clock
    return StoreInstrumentation<Action>(
      didStartRun: { event in
        let timestampNanos = Self.nanoseconds(from: startedAt.duration(to: clock.now))
        let sequence = event.sequence ?? 0
        let effectID = event.cancellationID?.rawValue.description
        recorder.record(
          phase: .runStarted,
          sequence: sequence,
          effectID: effectID,
          actionLabel: nil,
          timestampNanos: timestampNanos
        )
      },
      didFinishRun: { event in
        let timestampNanos = Self.nanoseconds(from: startedAt.duration(to: clock.now))
        let sequence = event.sequence ?? 0
        let effectID = event.cancellationID?.rawValue.description
        recorder.record(
          phase: .runFinished,
          sequence: sequence,
          effectID: effectID,
          actionLabel: nil,
          timestampNanos: timestampNanos
        )
      },
      didEmitAction: { event in
        let timestampNanos = Self.nanoseconds(from: startedAt.duration(to: clock.now))
        let sequence = event.sequence ?? 0
        let effectID = event.cancellationID?.rawValue.description
        let label = Self.labelForAction(event.action)
        recorder.record(
          phase: .actionEmitted,
          sequence: sequence,
          effectID: effectID,
          actionLabel: label,
          timestampNanos: timestampNanos
        )
      },
      didDropAction: { event in
        let timestampNanos = Self.nanoseconds(from: startedAt.duration(to: clock.now))
        let sequence = event.sequence ?? 0
        let effectID = event.cancellationID?.rawValue.description
        let label = event.action.map(Self.labelForAction)
        recorder.record(
          phase: .actionDropped,
          sequence: sequence,
          effectID: effectID,
          actionLabel: label,
          timestampNanos: timestampNanos
        )
      },
      didCancelEffects: { event in
        let timestampNanos = Self.nanoseconds(from: startedAt.duration(to: clock.now))
        let effectID = event.id?.rawValue.description
        recorder.record(
          phase: .effectsCancelled,
          sequence: event.sequence,
          effectID: effectID,
          actionLabel: nil,
          timestampNanos: timestampNanos
        )
      }
    )
  }

  // MARK: - Internal

  private nonisolated func snapshotEntries() -> [Entry] {
    storage.withLock { state in
      state.recordedEntries
        .sorted { lhs, rhs in lhs.ordering < rhs.ordering }
        .map(\.entry)
    }
  }

  private nonisolated func record(
    phase: Phase,
    sequence: UInt64,
    effectID: String?,
    actionLabel: String?,
    timestampNanos: UInt64
  ) {
    storage.withLock { state in
      let ordering = state.nextOrdering
      state.nextOrdering &+= 1
      state.recordedEntries.append(
        StoredEntry(
          ordering: ordering,
          entry: Entry(
            phase: phase,
            sequence: sequence,
            effectID: effectID,
            actionLabel: actionLabel,
            timestampNanos: timestampNanos
          )
        )
      )
    }
  }

  private nonisolated static func nanoseconds(from duration: Duration) -> UInt64 {
    let components = duration.components
    let seconds = max(components.seconds, 0)
    let attoseconds = max(components.attoseconds, 0)
    let secondsNanos = UInt64(seconds) &* 1_000_000_000
    let attoNanos = UInt64(attoseconds / 1_000_000_000)
    return secondsNanos &+ attoNanos
  }

  private nonisolated static func labelForAction<Action: Sendable>(_ action: Action) -> String {
    let mirror = Mirror(reflecting: action)
    if mirror.displayStyle == .enum, let child = mirror.children.first, let label = child.label {
      return label
    }
    return String(describing: action)
  }
}
