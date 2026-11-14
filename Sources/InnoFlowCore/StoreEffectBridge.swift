// MARK: - StoreEffectBridge.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

/// StoreEffectBridge keeps store-local cancellation scopes and shared timing state.
///
/// Concurrency: every mutating and reading method on this type is `@MainActor`-isolated
/// (see the class attribute below). Scope creation and cancellation acceptance are
/// therefore ordered with effect issuance. Each scope owns thread-safe exact-ID tokens
/// so detached run emissions can recheck cancellation off the main actor.
///
/// Invariants:
/// - issued sequences are strictly increasing
/// - only live scopes and exact-ID tokens retain cancellation state
/// - an active interpreter retains pending cancellation only for IDs its tree may discover
/// - delayed debounce/throttle state must be cleared whenever the owning Store shuts down
@MainActor
package final class StoreEffectBridge<Action: Sendable, Output: Sendable> {
  private struct DebounceState {
    let scope: DelayedEffectScope
    let generation: UInt64
    var task: Task<Void, Never>?
  }

  private struct TrackedCompositeTask {
    let task: Task<Void, Never>
    let sequence: UInt64
    let context: EffectExecutionContext?
  }

  package let childLifetimeRegistry = ChildLifetimeRegistry()
  package let runtime = EffectRuntime<Action>()
  package let throttleState = ThrottleStateMap<Action, Output>()
  package let runScheduler = EffectRunScheduler()
  private let boundaries = EffectCancellationBoundaries()

  private var debounceStateByID: [AnyEffectID: DebounceState] = [:]
  private var nextDebounceGenerationValue: UInt64 = 0
  private var compositeTasksByToken: [UUID: TrackedCompositeTask] = [:]
  private var compositeTokensByID: [AnyEffectID: Set<UUID>] = [:]
  private var compositeIDsByToken: [UUID: Set<AnyEffectID>] = [:]

  package init() {}

  package var currentSequence: UInt64 {
    boundaries.currentSequence
  }

  package var retainedCancellationIDCount: Int {
    boundaries.retainedCancellationIDCount
  }

  package var cancellationScopeMetrics: EffectCancellationScopeMetrics {
    .init(
      liveScopes: boundaries.liveScopeCount,
      liveInterpreters: boundaries.liveInterpreterCount,
      retainedPotentialIDs: boundaries.retainedPotentialIDCount,
      pendingCancellationIDs: boundaries.retainedCancellationIDCount,
      liveExactTokens: boundaries.liveExactTokenCount
    )
  }

  package func nextSequence() -> UInt64 {
    boundaries.nextSequence()
  }

  package func makeEffectContext(
    sequence: UInt64,
    cancellationIDs: [AnyEffectID] = [],
    potentialCancellationIDs: Set<AnyEffectID> = [],
    animation: EffectAnimation? = nil,
    origin: EffectOrigin? = nil,
    flowTaskTracker: FlowTaskTracker? = nil
  ) -> EffectExecutionContext {
    boundaries.makeContext(
      sequence: sequence,
      cancellationIDs: cancellationIDs,
      potentialCancellationIDs: potentialCancellationIDs,
      animation: animation,
      origin: origin,
      flowTaskTracker: flowTaskTracker
    )
  }

  /// Applies lifetime boundaries before any same-reduction output/effect can run.
  package func prepareLifetimes<State>(_ effect: ReducerEffect<Action, Output>, state: State)
    -> ReducerEffect<
      Action, Output
    >
  {
    childLifetimeRegistry.prepare(effect, state: state) { id in
      let sequence = markCancelled(id: id)
      cancelEffects(id: id, upTo: sequence)
    }
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
  ///   `sequence - 1` (saturating at `0`). Live scopes at or below that boundary
  ///   receive the cancellation; the current sequence remains eligible.
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

  /// Atomically accepts a debounce request and reserves its generation.
  ///
  /// Lower-sequence continuations are rejected after a newer request has won.
  /// Equal sequences retain debounce's latest-wins behavior and cancel the
  /// previously registered sleeper before reserving the replacement.
  package func beginDebounce(_ scope: DelayedEffectScope) -> UInt64? {
    if shouldAdmitDelayedScope(scope, replacing: debounceStateByID[scope.ownerID]?.scope) == false {
      return nil
    }

    debounceStateByID[scope.ownerID]?.task?.cancel()
    nextDebounceGenerationValue &+= 1
    debounceStateByID[scope.ownerID] = .init(
      scope: scope,
      generation: nextDebounceGenerationValue,
      task: nil
    )
    return nextDebounceGenerationValue
  }

  package func debounceGeneration(for id: AnyEffectID) -> UInt64? {
    debounceStateByID[id]?.generation
  }

  package func debounceScope(for id: AnyEffectID) -> DelayedEffectScope? {
    debounceStateByID[id]?.scope
  }

  @discardableResult
  package func setDebounceDelayTask(
    _ task: Task<Void, Never>,
    for id: AnyEffectID,
    generation: UInt64
  ) -> Bool {
    guard var state = debounceStateByID[id], state.generation == generation else {
      task.cancel()
      return false
    }
    state.task?.cancel()
    state.task = task
    debounceStateByID[id] = state
    return true
  }

  package func clearDebounceStates(where shouldClear: (DelayedEffectScope) -> Bool) {
    for (id, state) in Array(debounceStateByID) where shouldClear(state.scope) {
      debounceStateByID.removeValue(forKey: id)?.task?.cancel()
    }
  }

  @discardableResult
  package func finishDebounceState(for id: AnyEffectID, generation: UInt64) -> Bool {
    guard debounceStateByID[id]?.generation == generation else { return false }
    debounceStateByID.removeValue(forKey: id)
    return true
  }

  package func clearAllDelayedState() {
    for state in debounceStateByID.values {
      state.task?.cancel()
    }
    debounceStateByID.removeAll(keepingCapacity: true)
    throttleState.clearAll()
  }

  package func registerCompositeTask(
    token: UUID,
    id: AnyEffectID?,
    sequence: UInt64,
    context: EffectExecutionContext? = nil,
    task: Task<Void, Never>
  ) {
    registerCompositeTask(
      token: token,
      ids: id.map { [$0] } ?? [],
      sequence: sequence,
      context: context,
      task: task
    )
  }

  package func registerCompositeTask(
    token: UUID,
    ids: [AnyEffectID],
    sequence: UInt64,
    context: EffectExecutionContext? = nil,
    task: Task<Void, Never>
  ) {
    compositeTasksByToken[token] = .init(
      task: task,
      sequence: sequence,
      context: context
    )
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

  package func cancelCompositeTasks(id: AnyEffectID, upTo sequence: UInt64) {
    guard let tokens = compositeTokensByID[id] else { return }
    for token in Array(tokens) {
      guard let tracked = compositeTasksByToken[token] else {
        finishCompositeTask(token: token)
        continue
      }
      guard
        tracked.sequence <= sequence
          || tracked.context?.isCancelled(id: id) == true
      else {
        continue
      }
      tracked.task.cancel()
      finishCompositeTask(token: token)
    }
  }

  package func cancelAllCompositeTasks(upTo sequence: UInt64) {
    for (token, tracked) in Array(compositeTasksByToken) {
      guard
        tracked.sequence <= sequence
          || tracked.context?.shouldProceed == false
      else {
        continue
      }
      tracked.task.cancel()
      finishCompositeTask(token: token)
    }
  }

  package func cancelAllCompositeTasks() {
    for tracked in compositeTasksByToken.values {
      tracked.task.cancel()
    }
    compositeTasksByToken.removeAll(keepingCapacity: true)
    compositeTokensByID.removeAll(keepingCapacity: true)
    compositeIDsByToken.removeAll(keepingCapacity: true)
  }

  private func cancelDelayedState(id: AnyEffectID, upTo sequence: UInt64) {
    let shouldCancel: (DelayedEffectScope) -> Bool = { scope in
      guard scope.contains(id) else { return false }
      return scope.sequence <= sequence
        || scope.shouldProceed == false
    }
    clearDebounceStates(where: shouldCancel)
    throttleState.clearStates(where: shouldCancel)
  }

  private func cancelAllDelayedState(upTo sequence: UInt64) {
    let shouldCancel: (DelayedEffectScope) -> Bool = { scope in
      scope.sequence <= sequence
        || scope.shouldProceed == false
    }
    clearDebounceStates(where: shouldCancel)
    throttleState.clearStates(where: shouldCancel)
  }

  /// Dispatches owning work that an ID cancellation releases.
  ///
  /// Must be read before ``cancelEffects(id:upTo:)`` because that call
  /// releases the tracked work.
  package func cancellationTargetDispatchIDs(
    id: AnyEffectID,
    upTo sequence: UInt64
  ) -> Set<DispatchID> {
    var dispatchIDs = runScheduler.cancellationTargetDispatchIDs(id: id, upTo: sequence)

    if let tokens = compositeTokensByID[id] {
      for token in tokens {
        guard let tracked = compositeTasksByToken[token] else { continue }
        guard
          tracked.sequence <= sequence
            || tracked.context?.isCancelled(id: id) == true
        else { continue }
        if let dispatchID = tracked.context?.dispatchID {
          dispatchIDs.insert(dispatchID)
        }
      }
    }

    for state in debounceStateByID.values {
      let scope = state.scope
      guard scope.contains(id) else { continue }
      guard scope.sequence <= sequence || scope.shouldProceed == false else { continue }
      if let dispatchID = scope.cancellationContext?.dispatchID {
        dispatchIDs.insert(dispatchID)
      }
    }
    dispatchIDs.formUnion(
      throttleState.cancellationTargetDispatchIDs { scope in
        scope.contains(id)
          && (scope.sequence <= sequence || scope.shouldProceed == false)
      }
    )
    dispatchIDs.formUnion(runtime.cancellationTargetDispatchIDs(id: id, upTo: sequence))
    // An effect returned in this MainActor turn has registered nothing yet;
    // its declared work under `id` will be skipped all the same.
    dispatchIDs.formUnion(boundaries.uninterpretedDispatchIDs(declaring: id, upTo: sequence))
    return dispatchIDs
  }

  package func cancellationTargetDispatchIDs(upTo sequence: UInt64) -> Set<DispatchID> {
    var dispatchIDs = runScheduler.cancellationTargetDispatchIDs(upTo: sequence)

    for tracked in compositeTasksByToken.values {
      guard
        tracked.sequence <= sequence
          || tracked.context?.shouldProceed == false
      else { continue }
      if let dispatchID = tracked.context?.dispatchID {
        dispatchIDs.insert(dispatchID)
      }
    }

    for state in debounceStateByID.values {
      let scope = state.scope
      guard scope.sequence <= sequence || scope.shouldProceed == false else { continue }
      if let dispatchID = scope.cancellationContext?.dispatchID {
        dispatchIDs.insert(dispatchID)
      }
    }
    dispatchIDs.formUnion(
      throttleState.cancellationTargetDispatchIDs { scope in
        scope.sequence <= sequence || scope.shouldProceed == false
      }
    )
    dispatchIDs.formUnion(runtime.cancellationTargetDispatchIDs(upTo: sequence))
    dispatchIDs.formUnion(boundaries.uninterpretedDispatchIDs(declaring: nil, upTo: sequence))
    return dispatchIDs
  }

  /// Releases every piece of work owned by an accepted ID cancellation:
  /// pending scheduled requests, composite orchestration tasks, delayed
  /// debounce/throttle state and run tasks.
  ///
  /// All of this state is MainActor-isolated, so acceptance and release are
  /// one synchronous step. Nothing can be reduced, admitted or started
  /// between them.
  package func cancelEffects(id: AnyEffectID, upTo sequence: UInt64) {
    runScheduler.cancel(id: id, upTo: sequence)
    cancelCompositeTasks(id: id, upTo: sequence)
    cancelDelayedState(id: id, upTo: sequence)
    runtime.cancel(id: id, upTo: sequence)
  }

  package func cancelAllEffects(upTo sequence: UInt64) {
    runScheduler.cancelAll(upTo: sequence)
    cancelAllCompositeTasks(upTo: sequence)
    cancelAllDelayedState(upTo: sequence)
    runtime.cancelAll(upTo: sequence)
  }

  /// Clears store-local timing state and cancels every in-flight effect task.
  ///
  /// Called from `Store.deinit`. All effect bookkeeping is MainActor-isolated,
  /// so teardown is synchronous: cancellation has been delivered to every
  /// tracked task when this returns. The returned sequence is the release
  /// boundary used for instrumentation and tests.
  @discardableResult
  package func shutdown() -> UInt64 {
    childLifetimeRegistry.removeAll()
    let sequence = boundaries.markCancelledAll()
    runScheduler.cancelAll()
    cancelAllCompositeTasks()
    clearAllDelayedState()
    runtime.cancelAll(upTo: sequence)
    return sequence
  }
}
