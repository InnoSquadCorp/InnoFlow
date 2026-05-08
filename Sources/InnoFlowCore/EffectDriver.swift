// MARK: - EffectDriver.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

@MainActor
package final class ThrottleStateMap<Action: Sendable> {
  package struct PendingTrailing: Sendable {
    package let effect: EffectTask<Action>
    package let context: EffectExecutionContext?
  }

  private var windowEndByID: [AnyEffectID: ContinuousClock.Instant] = [:]
  private var pendingByID: [AnyEffectID: PendingTrailing] = [:]
  private var trailingTaskByID: [AnyEffectID: Task<Void, Never>] = [:]
  private var generationByID: [AnyEffectID: UInt64] = [:]
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
    for id: AnyEffectID
  ) {
    pendingByID[id] = .init(effect: effect, context: context)
  }

  package func pending(for id: AnyEffectID) -> PendingTrailing? {
    pendingByID[id]
  }

  package func setTrailingTask(_ task: Task<Void, Never>, for id: AnyEffectID) {
    trailingTaskByID[id] = task
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

  package func clearState(for id: AnyEffectID) {
    resetWindow(for: id)
    windowEndByID.removeValue(forKey: id)
  }

  @discardableResult
  package func finishState(for id: AnyEffectID, generation: UInt64) -> Bool {
    guard generationByID[id] == generation else { return false }
    trailingTaskByID.removeValue(forKey: id)
    generationByID.removeValue(forKey: id)
    pendingByID.removeValue(forKey: id)
    windowEndByID.removeValue(forKey: id)
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

  /// Start a `.run` effect. If `awaited`, blocks until the operation completes.
  func startRun(
    priority: TaskPriority?,
    operation: @escaping @Sendable (Send<Action>, EffectContext) async -> Void,
    context: EffectExecutionContext?,
    awaited: Bool
  ) async

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

  /// Schedule a debounced effect. Driver owns the timer and generation tracking.
  /// When the timer fires, calls `recurse(nested, context, awaited)`.
  func debounce(
    _ nested: EffectTask<Action>,
    id: AnyEffectID,
    interval: Duration,
    context: EffectExecutionContext?,
    awaited: Bool,
    recurse:
      @escaping @MainActor @Sendable (
        EffectTask<Action>, EffectExecutionContext?, Bool
      ) async -> Void
  ) async

  // MARK: - Throttle State

  /// Shared throttle bookkeeping for the driver.
  var throttleState: ThrottleStateMap<Action> { get }

  /// Schedules the trailing drain task for the throttle id.
  func scheduleTrailingDrain(
    for id: AnyEffectID,
    interval: Duration,
    recurse:
      @escaping @MainActor @Sendable (
        EffectTask<Action>, EffectExecutionContext?, Bool
      ) async -> Void
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
