// MARK: - StoreDiagnostics.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import os

/// Payload-free lifecycle classification for one dispatch diagnostic record.
public enum DispatchDiagnosticKind: Sendable, Equatable {
  case submitted
  case admission(EffectAdmission)
  case runStarted
  case runFinished
  case runFailed
  case actionEmitted
  case actionDropped(ActionDropReason)
  case outputDelivered(suppressedByCancellation: Bool)
  case cancellationRequested
  case terminated
}

/// One bounded metadata record for a root dispatch and its descendants.
public struct DispatchDiagnosticRecord: Sendable, Equatable {
  public let index: UInt64
  public let dispatchID: DispatchID
  public let kind: DispatchDiagnosticKind
  public let sequence: UInt64?
  public let runToken: UUID?
  public let hasEffectID: Bool
}

/// Current aggregate state for a dispatch that has not terminated.
public struct ActiveDispatchSnapshot: Sendable, Equatable {
  public let dispatchID: DispatchID
  public let activeRunCount: Int
  public let queuedRunCount: Int
  public let isCancellationRequested: Bool
  public let lastSequence: UInt64?
}

/// Immutable view of bounded history and currently-active dispatches.
public struct StoreDiagnosticsSnapshot: Sendable, Equatable {
  public let records: [DispatchDiagnosticRecord]
  public let activeDispatches: [ActiveDispatchSnapshot]
  public let droppedRecordCount: UInt64
}

/// Opt-in, bounded, payload-free Store diagnostics.
///
/// Passing this object to `Store.init(..., diagnostics:)` enables recording.
/// A Store created without one allocates no diagnostic history.
public final class StoreDiagnostics: Sendable {
  private struct ActiveState: Sendable {
    var activeRunCount = 0
    var queuedRunTokens: Set<UUID> = []
    var isCancellationRequested = false
    var lastSequence: UInt64?
  }

  private struct State: Sendable {
    var nextIndex: UInt64 = 0
    var records: [DispatchDiagnosticRecord] = []
    var active: [DispatchID: ActiveState] = [:]
    var droppedRecordCount: UInt64 = 0
  }

  public let capacity: Int
  private let state = OSAllocatedUnfairLock(initialState: State())

  public init(capacity: Int = 256) {
    precondition(capacity >= 0, "StoreDiagnostics capacity must be non-negative")
    self.capacity = capacity
  }

  public func snapshot(activeLimit: Int? = nil) -> StoreDiagnosticsSnapshot {
    state.withLock { state in
      let limit = max(0, activeLimit ?? state.active.count)
      let active = state.active
        .map { dispatchID, value in
          ActiveDispatchSnapshot(
            dispatchID: dispatchID,
            activeRunCount: value.activeRunCount,
            queuedRunCount: value.queuedRunTokens.count,
            isCancellationRequested: value.isCancellationRequested,
            lastSequence: value.lastSequence
          )
        }
        .sorted { $0.dispatchID.description < $1.dispatchID.description }
      return StoreDiagnosticsSnapshot(
        records: state.records,
        activeDispatches: Array(active.prefix(limit)),
        droppedRecordCount: state.droppedRecordCount
      )
    }
  }

  package func recordSubmitted(_ dispatchID: DispatchID) {
    record(dispatchID: dispatchID, kind: .submitted)
  }

  package func recordTerminated(_ dispatchID: DispatchID) {
    record(dispatchID: dispatchID, kind: .terminated)
  }

  package func recordCancellationRequested(
    _ dispatchID: DispatchID,
    sequence: UInt64? = nil,
    hasEffectID: Bool = false
  ) {
    record(
      dispatchID: dispatchID,
      kind: .cancellationRequested,
      sequence: sequence,
      hasEffectID: hasEffectID
    )
  }

  package func recordAdmission(
    _ admission: EffectAdmission,
    dispatchID: DispatchID?,
    sequence: UInt64?,
    scheduledToken: UUID? = nil
  ) {
    guard let dispatchID else { return }
    record(
      dispatchID: dispatchID,
      kind: .admission(admission),
      sequence: sequence,
      runToken: scheduledToken,
      hasEffectID: true
    )
  }

  /// Removes one request that left a scheduler queue without ever starting.
  /// This is intentionally aggregate-only: the public diagnostic event surface
  /// remains source compatible while active snapshots track the real queue.
  package func recordQueuedRunRemoved(
    dispatchID: DispatchID?,
    sequence: UInt64?,
    scheduledToken: UUID
  ) {
    guard let dispatchID else { return }
    state.withLock { state in
      guard var active = state.active[dispatchID] else { return }
      active.lastSequence = sequence ?? active.lastSequence
      active.queuedRunTokens.remove(scheduledToken)
      state.active[dispatchID] = active
    }
  }

  package func instrumentation<Action: Sendable>() -> StoreInstrumentation<Action> {
    .init(
      didStartRun: { [weak self] event in
        self?.record(
          dispatchID: event.dispatchID,
          kind: .runStarted,
          sequence: event.sequence,
          runToken: event.token,
          hasEffectID: event.cancellationID != nil
        )
      },
      didFinishRun: { [weak self] event in
        self?.record(
          dispatchID: event.dispatchID,
          kind: .runFinished,
          sequence: event.sequence,
          runToken: event.token,
          hasEffectID: event.cancellationID != nil
        )
      },
      didFailRun: { [weak self] event in
        self?.record(
          dispatchID: event.dispatchID,
          kind: .runFailed,
          sequence: event.sequence,
          runToken: event.token,
          hasEffectID: event.cancellationID != nil
        )
      },
      didEmitAction: { [weak self] event in
        self?.record(
          dispatchID: event.dispatchID,
          kind: .actionEmitted,
          sequence: event.sequence,
          hasEffectID: event.cancellationID != nil
        )
      },
      didDropAction: { [weak self] event in
        self?.record(
          dispatchID: event.dispatchID,
          kind: .actionDropped(event.reason),
          sequence: event.sequence,
          hasEffectID: event.cancellationID != nil
        )
      },
      didDeliverOutput: { [weak self] event in
        self?.record(
          dispatchID: event.dispatchID,
          kind: .outputDelivered(
            suppressedByCancellation: event.wasSuppressedByCancellation
          ),
          sequence: event.sequence
        )
      },
      // Cancellation instrumentation describes the command issuer. Diagnostics
      // records the affected dispatches directly from StoreEffectBridge.
      didCancelEffects: { _ in }
    )
  }

  private func record(
    dispatchID: DispatchID?,
    kind: DispatchDiagnosticKind,
    sequence: UInt64? = nil,
    runToken: UUID? = nil,
    hasEffectID: Bool = false
  ) {
    guard let dispatchID else { return }
    state.withLock { state in
      if kind == .cancellationRequested {
        guard let current = state.active[dispatchID] else { return }
        guard current.isCancellationRequested == false else { return }
      }
      var active = state.active[dispatchID]
      if kind == .submitted, active == nil {
        active = ActiveState()
      }
      if var current = active {
        current.lastSequence = sequence ?? current.lastSequence
        active = current
      }
      switch kind {
      case .submitted:
        break
      case .admission(.queued):
        if let runToken {
          active?.queuedRunTokens.insert(runToken)
        }
      case .admission(.started):
        if let runToken {
          active?.queuedRunTokens.remove(runToken)
        }
      case .admission(.rejected):
        break
      case .runStarted:
        active?.activeRunCount += 1
      case .runFinished, .runFailed:
        if let activeRunCount = active?.activeRunCount {
          active?.activeRunCount = max(0, activeRunCount - 1)
        }
      case .cancellationRequested:
        active?.isCancellationRequested = true
      case .terminated:
        state.active.removeValue(forKey: dispatchID)
      case .actionEmitted, .actionDropped, .outputDelivered:
        break
      }
      if kind != .terminated, let active {
        state.active[dispatchID] = active
      }

      state.nextIndex &+= 1
      let record = DispatchDiagnosticRecord(
        index: state.nextIndex,
        dispatchID: dispatchID,
        kind: kind,
        sequence: sequence,
        runToken: runToken,
        hasEffectID: hasEffectID
      )
      guard capacity > 0 else {
        state.droppedRecordCount &+= 1
        return
      }
      if state.records.count == capacity {
        state.records.removeFirst()
        state.droppedRecordCount &+= 1
      }
      state.records.append(record)
    }
  }
}
