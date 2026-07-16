// MARK: - EffectDriver.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

/// Ownership metadata for delayed debounce and throttle work.
///
/// A timing identifier owns the delayed work directly. Cancellation identifiers
/// inherited from enclosing effect scopes also own it, so cancelling any member
/// can tear the delayed state down without waiting for a nested `.run` to start.
package struct DelayedEffectScope: Sendable {
  package let ownerID: AnyEffectID
  package let inheritedCancellationIDs: [AnyEffectID]
  package let sequence: UInt64

  package init(
    ownerID: AnyEffectID,
    inheritedCancellationIDs: [AnyEffectID] = [],
    sequence: UInt64? = nil
  ) {
    self.ownerID = ownerID
    self.inheritedCancellationIDs = inheritedCancellationIDs
    self.sequence = sequence ?? 0
  }

  package func contains(_ id: AnyEffectID) -> Bool {
    ownerID == id || inheritedCancellationIDs.contains(id)
  }
}

package func shouldAdmitDelayedScope(
  _ candidate: DelayedEffectScope,
  replacing current: DelayedEffectScope?
) -> Bool {
  guard let current else { return true }
  return candidate.sequence >= current.sequence
}

@MainActor
package final class ThrottleStateMap<Action: Sendable> {
  private struct AdmissionState {
    var latestSequence: UInt64
    var outstandingCount: Int
  }

  package struct PendingTrailing: Sendable {
    package let effect: EffectTask<Action>
    package let context: EffectExecutionContext?
    package let requiresAwaitedCompletion: Bool
  }

  private var windowEndByID: [AnyEffectID: ContinuousClock.Instant] = [:]
  private var pendingByID: [AnyEffectID: PendingTrailing] = [:]
  private var trailingTaskByID: [AnyEffectID: Task<Void, Never>] = [:]
  private var generationByID: [AnyEffectID: UInt64] = [:]
  private var scopeByID: [AnyEffectID: DelayedEffectScope] = [:]
  private var admissionStateByID: [AnyEffectID: AdmissionState] = [:]
  private var nextGenerationValue: UInt64 = 0

  package init() {}

  package func windowEnd(for id: AnyEffectID) -> ContinuousClock.Instant? {
    windowEndByID[id]
  }

  package func setWindowEnd(_ instant: ContinuousClock.Instant, for id: AnyEffectID) {
    windowEndByID[id] = instant
  }

  package func storePending(
    _ effect: EffectTask<Action>,
    context: EffectExecutionContext?,
    requiresAwaitedCompletion: Bool = false,
    for id: AnyEffectID
  ) {
    let requiresAwaitedCompletion =
      pendingByID[id]?.requiresAwaitedCompletion == true || requiresAwaitedCompletion
    pendingByID[id] = .init(
      effect: effect,
      context: context,
      requiresAwaitedCompletion: requiresAwaitedCompletion
    )
  }

  package func pending(for id: AnyEffectID) -> PendingTrailing? {
    pendingByID[id]
  }

  package func setTrailingTask(_ task: Task<Void, Never>, for id: AnyEffectID) {
    trailingTaskByID[id] = task
  }

  package func scope(for id: AnyEffectID) -> DelayedEffectScope? {
    scopeByID[id]
  }

  package func trailingTask(for id: AnyEffectID) -> Task<Void, Never>? {
    trailingTaskByID[id]
  }

  package func latestAdmissionSequence(for id: AnyEffectID) -> UInt64? {
    admissionStateByID[id]?.latestSequence
  }

  /// Registers a throttle request before its asynchronous clock read.
  ///
  /// The short-lived ledger prevents an older suspended clock read from
  /// recreating state after a newer request overtakes and finishes. Entries are
  /// removed when every overlapping clock read completes, so dynamic timing IDs
  /// are not retained for the lifetime of the store.
  @discardableResult
  package func beginAdmission(_ scope: DelayedEffectScope) -> Bool {
    let activeSequence = scopeByID[scope.ownerID]?.sequence
    let pendingSequence = admissionStateByID[scope.ownerID]?.latestSequence
    if let latest = [activeSequence, pendingSequence].compactMap({ $0 }).max(),
      scope.sequence < latest
    {
      return false
    }

    if var state = admissionStateByID[scope.ownerID] {
      state.latestSequence = max(state.latestSequence, scope.sequence)
      state.outstandingCount += 1
      admissionStateByID[scope.ownerID] = state
    } else {
      admissionStateByID[scope.ownerID] = .init(
        latestSequence: scope.sequence,
        outstandingCount: 1
      )
    }
    return true
  }

  package func admit(_ scope: DelayedEffectScope) -> Bool {
    guard let state = admissionStateByID[scope.ownerID] else { return false }
    guard scope.sequence >= state.latestSequence else { return false }
    guard let activeScope = scopeByID[scope.ownerID] else { return true }
    return shouldAdmitDelayedScope(scope, replacing: activeScope)
  }

  package func endAdmission(for id: AnyEffectID) {
    guard var state = admissionStateByID[id] else { return }
    state.outstandingCount -= 1
    if state.outstandingCount == 0 {
      admissionStateByID.removeValue(forKey: id)
    } else {
      admissionStateByID[id] = state
    }
  }

  /// Assigns ownership to work that actually occupies the active window.
  @discardableResult
  package func setScope(_ scope: DelayedEffectScope) -> Bool {
    guard admissionStateByID[scope.ownerID]?.latestSequence == scope.sequence else {
      return false
    }
    scopeByID[scope.ownerID] = scope
    return true
  }

  package func cancelTrailingTask(for id: AnyEffectID) {
    trailingTaskByID.removeValue(forKey: id)?.cancel()
  }

  package func generation(for id: AnyEffectID) -> UInt64? {
    generationByID[id]
  }

  @discardableResult
  package func nextGeneration(for id: AnyEffectID) -> UInt64 {
    nextGenerationValue &+= 1
    generationByID[id] = nextGenerationValue
    return nextGenerationValue
  }

  package func resetWindow(for id: AnyEffectID) {
    cancelTrailingTask(for: id)
    generationByID.removeValue(forKey: id)
    pendingByID.removeValue(forKey: id)
  }

  @discardableResult
  package func clearState(
    for id: AnyEffectID,
    where shouldClear: (DelayedEffectScope) -> Bool
  ) -> Bool {
    guard let scope = scopeByID[id], shouldClear(scope) else { return false }
    resetWindow(for: id)
    windowEndByID.removeValue(forKey: id)
    scopeByID.removeValue(forKey: id)
    return true
  }

  package func clearStates(where shouldClear: (DelayedEffectScope) -> Bool) {
    for id in Array(scopeByID.keys) {
      _ = clearState(for: id, where: shouldClear)
    }
  }

  @discardableResult
  package func finishState(for id: AnyEffectID, generation: UInt64) -> Bool {
    guard generationByID[id] == generation else { return false }
    trailingTaskByID.removeValue(forKey: id)
    generationByID.removeValue(forKey: id)
    pendingByID.removeValue(forKey: id)
    windowEndByID.removeValue(forKey: id)
    scopeByID.removeValue(forKey: id)
    return true
  }

  package func clearAll() {
    for task in trailingTaskByID.values {
      task.cancel()
    }
    trailingTaskByID.removeAll(keepingCapacity: true)
    pendingByID.removeAll(keepingCapacity: true)
    windowEndByID.removeAll(keepingCapacity: true)
    generationByID.removeAll(keepingCapacity: true)
    scopeByID.removeAll(keepingCapacity: true)
    admissionStateByID.removeAll(keepingCapacity: true)
  }
}

// MARK: - Effect Driver Protocol

/// Runtime-specific primitives for effect interpretation.
///
/// The walker (`EffectWalker`) owns the recursive tree-traversal and structural rules.
/// The driver provides leaf operations that differ between `Store` and `TestStore`.
@MainActor
package protocol EffectDriver<Action>: AnyObject {
  associatedtype Action: Sendable

  // MARK: - Leaf Operations

  /// Deliver an action back to the reduce cycle.
  func deliverAction(_ action: Action, context: EffectExecutionContext?)

  /// Surface a structural action drop (e.g., `IfLet` child state missing)
  /// without re-delivering the action. Stores route this to
  /// `StoreInstrumentation.didDropAction`; test runtimes may no-op.
  func reportActionDrop(
    _ action: Action,
    reason: ActionDropReason,
    context: EffectExecutionContext?
  )

  /// Starts and registers a `.run` effect, returning its tracked task.
  /// The walker decides whether to await completion after the driver's strong
  /// reference has left scope.
  @discardableResult
  func startRun(
    priority: TaskPriority?,
    operation: @escaping @Sendable (Send<Action>, EffectContext) async -> Void,
    context: EffectExecutionContext?
  ) async -> Task<Void, Never>

  // MARK: - Cancellation

  /// Cancel all effects for the given id.
  /// Used by `.cancel(id)` — includes the current sequence in the boundary.
  func cancelEffects(id: AnyEffectID, context: EffectExecutionContext?) async

  /// Cancel in-flight effects for the given id, preserving the current
  /// sequence's eligibility.
  /// Used by `.cancellable(cancelInFlight: true)` and `.debounce`.
  func cancelInFlightEffects(id: AnyEffectID, context: EffectExecutionContext?) async

  /// Whether execution should proceed for the given context.
  /// Store and TestStore both check sequence boundaries for cancellable effects.
  func shouldProceed(context: EffectExecutionContext?) -> Bool

  // MARK: - Debounce

  /// Schedules a debounced effect and returns its registered delay task.
  /// The driver owns timer and generation tracking. When the timer fires, it
  /// interprets the nested effect using the requested awaited semantics.
  ///
  /// The walker decides whether to await the returned task after the driver's
  /// strong reference has left scope.
  @discardableResult
  func scheduleDebounce(
    _ nested: EffectTask<Action>,
    id: AnyEffectID,
    interval: Duration,
    context: EffectExecutionContext?,
    scope: DelayedEffectScope,
    nestedAwaited: Bool,
    recurse:
      @escaping @MainActor @Sendable (
        EffectTask<Action>, EffectExecutionContext?, Bool
      ) async -> Void
  ) async -> Task<Void, Never>?

  // MARK: - Throttle State

  /// Shared throttle bookkeeping for the driver.
  var throttleState: ThrottleStateMap<Action> { get }

  /// Schedules the trailing drain task for the throttle id.
  ///
  /// `awaited` records whether the call that opened the window needs the
  /// trailing window to complete. Later pending replacements can only promote
  /// that requirement through `PendingTrailing.requiresAwaitedCompletion`.
  /// `schedulingContext` identifies the effect frame that created the sleeper;
  /// a successful drain still recurses with the latest pending context.
  @discardableResult
  func scheduleTrailingDrain(
    for id: AnyEffectID,
    interval: Duration,
    schedulingContext: EffectExecutionContext,
    awaited: Bool,
    recurse:
      @escaping @MainActor @Sendable (
        EffectTask<Action>, EffectExecutionContext?, Bool
      ) async -> Void
  ) -> Task<Void, Never>

  /// Refreshes runtime-specific ownership when an active trailing drain is
  /// reused by a newer pending effect. Production Store ownership lives in
  /// `throttleState`; TestStore also reindexes its finish/cancellation task.
  func refreshTrailingDrainOwnership(
    for id: AnyEffectID,
    context: EffectExecutionContext
  )

  /// Current clock instant for throttle window comparison.
  var now: ContinuousClock.Instant { get async }

  // MARK: - Concurrency Primitives

  /// Run children concurrently (merge).
  func runConcurrently(
    _ children: [EffectTask<Action>],
    context: EffectExecutionContext?,
    awaited: Bool,
    recurse:
      @escaping @MainActor @Sendable (
        EffectTask<Action>, EffectExecutionContext?, Bool
      ) async -> Void
  ) async

  /// Run children sequentially (concatenate).
  func runSequentially(
    _ children: [EffectTask<Action>],
    context: EffectExecutionContext?,
    awaited: Bool,
    recurse:
      @escaping @MainActor @Sendable (
        EffectTask<Action>, EffectExecutionContext?, Bool
      ) async -> Void
  ) async
}
