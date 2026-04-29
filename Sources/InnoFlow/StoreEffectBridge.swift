// MARK: - StoreEffectBridge.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

/// StoreEffectBridge keeps store-local cancellation boundaries and shared timing state.
///
/// Concurrency: every mutating and reading method on this type is `@MainActor`-isolated
/// (see the class attribute below). Read-modify-write sequences such as
/// `cancelledUpToByID[id] = max(existing, new)` are therefore atomic with respect to all
/// other accesses on the bridge — Swift's actor isolation provides the mutual exclusion,
/// so no CAS, lock, or atomic primitive is needed. Callers do not need to add
/// synchronization when invoking these methods from MainActor-bound contexts.
///
/// Invariants:
/// - issued sequences are strictly increasing
/// - `cancelledUpTo*` values are monotonic and gate future emissions
/// - throttle state must be cleared whenever the owning Store shuts down
@MainActor
package final class StoreEffectBridge<Action: Sendable> {
  package let runtime = EffectRuntime<Action>()
  package let throttleState = ThrottleStateMap<Action>()

  private var lastIssuedSequence: UInt64 = 0
  private var cancelledUpToAll: UInt64 = 0
  private var cancelledUpToByID: [EffectID: UInt64] = [:]

  package init() {}

  package var currentSequence: UInt64 {
    lastIssuedSequence
  }

  package func nextSequence() -> UInt64 {
    lastIssuedSequence &+= 1
    return lastIssuedSequence
  }

  package func shouldStart(sequence: UInt64, cancellationID: EffectID?) -> Bool {
    if sequence <= cancelledUpToAll {
      return false
    }
    guard let cancellationID else { return true }
    let boundary = cancelledUpToByID[cancellationID] ?? 0
    return sequence > boundary
  }

  package func shouldProceed(context: EffectExecutionContext?) -> Bool {
    guard let sequence = context?.sequence else { return true }
    return shouldStart(sequence: sequence, cancellationID: context?.cancellationID)
  }

  @discardableResult
  package func markCancelled(id: EffectID, upTo sequence: UInt64? = nil) -> UInt64 {
    let sequence = sequence ?? lastIssuedSequence
    cancelledUpToByID[id] = max(cancelledUpToByID[id] ?? 0, sequence)
    return sequence
  }

  /// Cancels every prior sequence for `id` while leaving the in-flight effect at
  /// exactly `sequence` alive. Used by `cancelInFlight: true` semantics.
  ///
  /// - Parameters:
  ///   - id: cancellation key for the effect group.
  ///   - sequence: the sequence to keep alive (defaults to the most recent issued
  ///     sequence). Sequences strictly less than this become cancelled.
  /// - Returns: the boundary written to `cancelledUpToByID[id]` — i.e.
  ///   `sequence - 1` (saturating at `0`).
  ///
  /// Concurrency: this read-modify-write is atomic by virtue of the class-level
  /// `@MainActor` isolation. Callers do not need additional synchronization.
  @discardableResult
  package func markCancelledInFlight(id: EffectID, upTo sequence: UInt64? = nil) -> UInt64 {
    let sequence = sequence ?? lastIssuedSequence
    let previousSequence = sequence == 0 ? 0 : sequence - 1
    cancelledUpToByID[id] = max(cancelledUpToByID[id] ?? 0, previousSequence)
    return previousSequence
  }

  @discardableResult
  package func markCancelledAll(upTo sequence: UInt64? = nil) -> UInt64 {
    let sequence = sequence ?? lastIssuedSequence
    cancelledUpToAll = max(cancelledUpToAll, sequence)
    cancelledUpToByID.removeAll(keepingCapacity: true)
    return sequence
  }

  @discardableResult
  package func enqueueRunActionIfAllowed(
    _ action: Action,
    context: EffectExecutionContext?,
    enqueue: (Action, EffectAnimation?) -> Void
  ) -> Bool {
    guard shouldProceed(context: context) else { return false }
    enqueue(action, context?.animation)
    return true
  }

  package func cancelEffects(id: EffectID, upTo sequence: UInt64) async {
    await runtime.cancel(id: id, upTo: sequence)
    throttleState.clearState(for: id)
  }

  package func cancelInFlightEffects(id: EffectID, upTo sequence: UInt64) async {
    await runtime.cancelInFlight(id: id, upTo: sequence)
    throttleState.clearState(for: id)
  }

  package func cancelAllEffects(upTo sequence: UInt64) async {
    await runtime.cancelAll(upTo: sequence)
    throttleState.clearAll()
  }

  /// Clears store-local timing state and triggers best-effort runtime cancellation.
  ///
  /// The owning `Store` cannot await runtime teardown from `deinit`, so this method
  /// synchronously freezes local bookkeeping and then kicks off asynchronous
  /// cancellation of in-flight effect tasks. The returned sequence is the release
  /// boundary used for instrumentation and tests.
  @discardableResult
  package func shutdown() -> UInt64 {
    throttleState.clearAll()
    let runtime = self.runtime
    let sequence = self.currentSequence
    Task {
      await runtime.cancelAll(upTo: sequence)
    }
    return sequence
  }
}
