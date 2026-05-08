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
/// - delayed debounce/throttle state must be cleared whenever the owning Store shuts down
@MainActor
package final class StoreEffectBridge<Action: Sendable> {
  package let runtime = EffectRuntime<Action>()
  package let throttleState = ThrottleStateMap<Action>()
  private let boundaries = EffectCancellationBoundaries()

  private var debounceDelayTasksByID: [AnyEffectID: Task<Void, Never>] = [:]
  private var debounceGenerationByID: [AnyEffectID: UInt64] = [:]
  private var nextDebounceGenerationValue: UInt64 = 0
  private var compositeTasksByToken: [UUID: Task<Void, Never>] = [:]
  private var compositeTokensByID: [AnyEffectID: Set<UUID>] = [:]
  private var compositeIDsByToken: [UUID: Set<AnyEffectID>] = [:]

  package init() {}

  package var currentSequence: UInt64 {
    boundaries.currentSequence
  }

  package func nextSequence() -> UInt64 {
    boundaries.nextSequence()
  }

  package func shouldStart(sequence: UInt64, cancellationID: AnyEffectID?) -> Bool {
    boundaries.shouldStart(sequence: sequence, cancellationID: cancellationID)
  }

  package func shouldProceed(context: EffectExecutionContext?) -> Bool {
    boundaries.shouldProceed(context: context)
  }

  @discardableResult
  package func markCancelled(id: AnyEffectID, upTo sequence: UInt64? = nil) -> UInt64 {
    boundaries.markCancelled(id: id, upTo: sequence)
  }

  /// Cancels every prior sequence for `id` while leaving the in-flight effect at
  /// exactly `sequence` alive. Used by `cancelInFlight: true` semantics.
  ///
  /// - Parameters:
  ///   - id: cancellation key for the effect group.
  ///   - sequence: the sequence to keep alive (defaults to the most recent issued
  ///     sequence). Sequences strictly less than this become cancelled.
  /// - Returns: the computed in-flight boundary for this call, i.e.
  ///   `sequence - 1` (saturating at `0`). The stored `cancelledUpToByID[id]`
  ///   boundary remains monotonic as `max(existingBoundary, returnedBoundary)`.
  ///
  /// Concurrency: this read-modify-write is atomic by virtue of the class-level
  /// `@MainActor` isolation. Callers do not need additional synchronization.
  @discardableResult
  package func markCancelledInFlight(id: AnyEffectID, upTo sequence: UInt64? = nil) -> UInt64 {
    boundaries.markCancelledInFlight(id: id, upTo: sequence)
  }

  @discardableResult
  package func markCancelledAll(upTo sequence: UInt64? = nil) -> UInt64 {
    boundaries.markCancelledAll(upTo: sequence)
  }

  @discardableResult
  package func nextDebounceGeneration(for id: AnyEffectID) -> UInt64 {
    nextDebounceGenerationValue &+= 1
    debounceGenerationByID[id] = nextDebounceGenerationValue
    return nextDebounceGenerationValue
  }

  package func debounceGeneration(for id: AnyEffectID) -> UInt64? {
    debounceGenerationByID[id]
  }

  package func setDebounceDelayTask(
    _ task: Task<Void, Never>,
    for id: AnyEffectID,
    generation: UInt64
  ) {
    guard debounceGenerationByID[id] == generation else { return }
    debounceDelayTasksByID[id] = task
  }

  package func clearDebounceState(for id: AnyEffectID, generation: UInt64? = nil) {
    if let generation, debounceGenerationByID[id] != generation {
      return
    }
    debounceDelayTasksByID.removeValue(forKey: id)?.cancel()
    debounceGenerationByID.removeValue(forKey: id)
  }

  @discardableResult
  package func finishDebounceState(for id: AnyEffectID, generation: UInt64) -> Bool {
    guard debounceGenerationByID[id] == generation else { return false }
    debounceDelayTasksByID.removeValue(forKey: id)
    debounceGenerationByID.removeValue(forKey: id)
    return true
  }

  package func clearAllDelayedState() {
    for task in debounceDelayTasksByID.values {
      task.cancel()
    }
    debounceDelayTasksByID.removeAll(keepingCapacity: true)
    debounceGenerationByID.removeAll(keepingCapacity: true)
    throttleState.clearAll()
  }

  package func registerCompositeTask(
    token: UUID,
    id: AnyEffectID?,
    task: Task<Void, Never>
  ) {
    registerCompositeTask(token: token, ids: id.map { [$0] } ?? [], task: task)
  }

  package func registerCompositeTask(
    token: UUID,
    ids: [AnyEffectID],
    task: Task<Void, Never>
  ) {
    compositeTasksByToken[token] = task
    let uniqueIDs = Set(ids)
    if uniqueIDs.isEmpty == false {
      compositeIDsByToken[token] = uniqueIDs
    }
    for id in uniqueIDs {
      compositeTokensByID[id, default: []].insert(token)
    }
  }

  package func finishCompositeTask(token: UUID) {
    compositeTasksByToken.removeValue(forKey: token)
    let ids = compositeIDsByToken.removeValue(forKey: token) ?? []

    for id in ids {
      guard var tokens = compositeTokensByID[id] else { continue }
      tokens.remove(token)
      if tokens.isEmpty {
        compositeTokensByID.removeValue(forKey: id)
      } else {
        compositeTokensByID[id] = tokens
      }
    }
  }

  package func cancelCompositeTasks(id: AnyEffectID) {
    guard let tokens = compositeTokensByID[id] else { return }
    for token in tokens {
      compositeTasksByToken[token]?.cancel()
      finishCompositeTask(token: token)
    }
  }

  package func cancelAllCompositeTasks() {
    for task in compositeTasksByToken.values {
      task.cancel()
    }
    compositeTasksByToken.removeAll(keepingCapacity: true)
    compositeTokensByID.removeAll(keepingCapacity: true)
    compositeIDsByToken.removeAll(keepingCapacity: true)
  }

  package func cancelEffects(id: AnyEffectID, upTo sequence: UInt64) async {
    cancelCompositeTasks(id: id)
    await runtime.cancel(id: id, upTo: sequence)
    clearDebounceState(for: id)
    throttleState.clearState(for: id)
  }

  package func cancelInFlightEffects(id: AnyEffectID, upTo sequence: UInt64) async {
    cancelCompositeTasks(id: id)
    await runtime.cancelInFlight(id: id, upTo: sequence)
    clearDebounceState(for: id)
    throttleState.clearState(for: id)
  }

  package func cancelAllEffects(upTo sequence: UInt64) async {
    cancelAllCompositeTasks()
    await runtime.cancelAll(upTo: sequence)
    clearAllDelayedState()
  }

  /// Clears store-local timing state and triggers best-effort runtime cancellation.
  ///
  /// The owning `Store` cannot await runtime teardown from `deinit`, so this method
  /// synchronously freezes local bookkeeping and then kicks off asynchronous
  /// cancellation of in-flight effect tasks. The returned sequence is the release
  /// boundary used for instrumentation and tests.
  @discardableResult
  package func shutdown() -> UInt64 {
    cancelAllCompositeTasks()
    clearAllDelayedState()
    let runtime = self.runtime
    let sequence = self.currentSequence
    Task {
      await runtime.cancelAll(upTo: sequence)
    }
    return sequence
  }
}
