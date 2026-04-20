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

  private let clock = ContinuousClock()
  private let startedAt: ContinuousClock.Instant
  private var recordedEntries: [Entry] = []

  public init() {
    self.startedAt = ContinuousClock().now
  }

  // MARK: - Public API

  /// Returns a snapshot of all entries recorded so far, ordered by insertion.
  public func entries() -> [Entry] {
    recordedEntries
  }

  /// Writes every recorded entry as a newline-delimited JSON stream. Existing
  /// contents of `url` are replaced.
  public func dumpJSONL(to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    var payload = Data()
    for entry in recordedEntries {
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
  /// instrumentation callback**, then enqueues an asynchronous `append` that
  /// writes the pre-captured stamp. This keeps timing measurements faithful
  /// to the `Store` event order even under heavy scheduler contention — the
  /// actor hop only delays when the entry is visible, never the timestamp
  /// it carries.
  public nonisolated func instrumentation<Action: Sendable>() -> StoreInstrumentation<Action> {
    let recorder = self
    let startedAt = self.startedAt
    let clock = self.clock
    return StoreInstrumentation<Action>(
      didStartRun: { event in
        let timestampNanos = Self.nanoseconds(from: startedAt.duration(to: clock.now))
        let sequence = event.sequence ?? 0
        let effectID = event.cancellationID?.rawValue.description
        Task {
          await recorder.append(
            phase: .runStarted,
            sequence: sequence,
            effectID: effectID,
            actionLabel: nil,
            timestampNanos: timestampNanos
          )
        }
      },
      didFinishRun: { event in
        let timestampNanos = Self.nanoseconds(from: startedAt.duration(to: clock.now))
        let sequence = event.sequence ?? 0
        let effectID = event.cancellationID?.rawValue.description
        Task {
          await recorder.append(
            phase: .runFinished,
            sequence: sequence,
            effectID: effectID,
            actionLabel: nil,
            timestampNanos: timestampNanos
          )
        }
      },
      didEmitAction: { event in
        let timestampNanos = Self.nanoseconds(from: startedAt.duration(to: clock.now))
        let sequence = event.sequence ?? 0
        let effectID = event.cancellationID?.rawValue.description
        let label = Self.labelForAction(event.action)
        Task {
          await recorder.append(
            phase: .actionEmitted,
            sequence: sequence,
            effectID: effectID,
            actionLabel: label,
            timestampNanos: timestampNanos
          )
        }
      },
      didDropAction: { event in
        let timestampNanos = Self.nanoseconds(from: startedAt.duration(to: clock.now))
        let sequence = event.sequence ?? 0
        let effectID = event.cancellationID?.rawValue.description
        let label = event.action.map(Self.labelForAction)
        Task {
          await recorder.append(
            phase: .actionDropped,
            sequence: sequence,
            effectID: effectID,
            actionLabel: label,
            timestampNanos: timestampNanos
          )
        }
      },
      didCancelEffects: { event in
        let timestampNanos = Self.nanoseconds(from: startedAt.duration(to: clock.now))
        let effectID = event.id?.rawValue.description
        Task {
          await recorder.append(
            phase: .effectsCancelled,
            sequence: event.sequence,
            effectID: effectID,
            actionLabel: nil,
            timestampNanos: timestampNanos
          )
        }
      }
    )
  }

  // MARK: - Internal

  func append(
    phase: Phase,
    sequence: UInt64,
    effectID: String?,
    actionLabel: String?,
    timestampNanos: UInt64
  ) {
    recordedEntries.append(
      Entry(
        phase: phase,
        sequence: sequence,
        effectID: effectID,
        actionLabel: actionLabel,
        timestampNanos: timestampNanos
      )
    )
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
