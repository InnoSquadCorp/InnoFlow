// MARK: - EffectRuntime.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import Synchronization

package actor RunStartGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  package init() {}

  package func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  package func open() {
    guard !isOpen else { return }
    isOpen = true
    let pendingWaiters = waiters
    waiters.removeAll(keepingCapacity: false)
    for waiter in pendingWaiters {
      waiter.resume()
    }
  }
}

@MainActor
package final class EffectCancellationBoundaries {
  private var lastIssuedSequence: UInt64 = 0
  private let scopes = EffectCancellationScopeRegistry()

  package init() {}

  package var currentSequence: UInt64 {
    lastIssuedSequence
  }

  package var retainedCancellationIDCount: Int {
    scopes.retainedCancellationIDCount
  }

  package var liveScopeCount: Int {
    scopes.liveScopeCount
  }

  package var liveInterpreterCount: Int {
    scopes.liveInterpreterCount
  }

  package var retainedPotentialIDCount: Int {
    scopes.retainedPotentialIDCount
  }

  package var liveExactTokenCount: Int {
    scopes.liveExactTokenCount
  }

  package func nextSequence() -> UInt64 {
    lastIssuedSequence &+= 1
    return lastIssuedSequence
  }

  package func makeContext(
    sequence: UInt64,
    cancellationIDs: [AnyEffectID] = [],
    potentialCancellationIDs: Set<AnyEffectID> = [],
    animation: EffectAnimation? = nil,
    origin: EffectOrigin? = nil,
    flowTaskTracker: FlowTaskTracker? = nil
  ) -> EffectExecutionContext {
    let ownedScope = scopes.makeScopeAndInterpreterLease(
      sequence: sequence,
      potentialCancellationIDs: potentialCancellationIDs.union(cancellationIDs)
    )
    flowTaskTracker?.registerCancellationScope(ownedScope.scope)
    ownedScope.scope.bindDispatch(flowTaskTracker?.dispatchID)
    var context = EffectExecutionContext.managedRoot(
      cancellationScope: ownedScope.scope,
      interpreterLease: ownedScope.lease,
      animation: animation,
      sequence: sequence,
      origin: origin,
      flowTaskTracker: flowTaskTracker
    )
    for id in cancellationIDs {
      context = .withCancellation(id, on: context)
    }
    return context
  }

  package func nextContext(
    potentialCancellationIDs: Set<AnyEffectID> = [],
    animation: EffectAnimation? = nil,
    origin: EffectOrigin? = nil,
    flowTaskTracker: FlowTaskTracker? = nil
  ) -> EffectExecutionContext {
    makeContext(
      sequence: nextSequence(),
      potentialCancellationIDs: potentialCancellationIDs,
      animation: animation,
      origin: origin,
      flowTaskTracker: flowTaskTracker
    )
  }

  package func shouldProceed(context: EffectExecutionContext?) -> Bool {
    context?.shouldProceed ?? true
  }

  /// Dispatches whose effect has not been interpreted yet and would lose
  /// work to a cancellation of `id` (of everything when `id` is `nil`).
  package func uninterpretedDispatchIDs(
    declaring id: AnyEffectID?,
    upTo sequence: UInt64
  ) -> Set<DispatchID> {
    scopes.uninterpretedDispatchIDs(declaring: id, upTo: sequence)
  }

  @discardableResult
  package func markCancelled(id: AnyEffectID, upTo sequence: UInt64? = nil) -> UInt64 {
    let sequence = sequence ?? lastIssuedSequence
    scopes.cancel(id: id, upTo: sequence)
    return sequence
  }

  @discardableResult
  package func markCancelledInFlight(id: AnyEffectID, upTo sequence: UInt64? = nil) -> UInt64 {
    let sequence = sequence ?? lastIssuedSequence
    let previousSequence = sequence == 0 ? 0 : sequence - 1
    scopes.cancel(id: id, upTo: previousSequence)
    return previousSequence
  }

  @discardableResult
  package func markCancelledAll(upTo sequence: UInt64? = nil) -> UInt64 {
    let sequence = sequence ?? lastIssuedSequence
    scopes.cancelAll(upTo: sequence)
    return sequence
  }
}

/// Whether one run may still emit, readable from the run's own task.
///
/// The runtime is the only writer. A run reads this without hopping to the
/// MainActor when it checks for cancellation; the authoritative emission
/// decision is still made on the MainActor together with action delivery.
package final class EffectRunLiveness: Sendable {
  private let active = Mutex(true)

  package init() {}

  package var isActive: Bool {
    active.withLock { $0 }
  }

  fileprivate func deactivate() {
    active.withLock { $0 = false }
  }
}

/// EffectRuntime owns task bookkeeping for `.run` effects.
///
/// The runtime is isolated to the MainActor, like every other piece of Store
/// effect state. Registration, cancellation and the emission decision are
/// therefore ordered with reduction and with each other without an actor hop:
/// cancelling an identifier marks its tokens, cancels its run tasks and
/// retires their liveness in one synchronous step.
///
/// Invariants:
/// - a registered token is removed exactly once, by `finish` or by cancellation
/// - `tokensByID`, `idsByToken` and `runs` stay symmetric for registered tokens
/// - cancellation admission comes from the run's frozen sequence scope/tokens
@MainActor
package final class EffectRuntime<Action: Sendable> {
  private struct TrackedRun {
    let task: Task<Void, Never>
    let sequence: UInt64
    let context: EffectExecutionContext?
    let liveness: EffectRunLiveness
  }

  package struct MetricsSnapshot: Sendable, Equatable {
    package let preparedRuns: UInt64
    package let attachedRuns: UInt64
    package let finishedRuns: UInt64
    package let emissionDecisions: UInt64
    package let cancellations: UInt64
  }

  private var runs: [UUID: TrackedRun] = [:]
  private var tokensByID: [AnyEffectID: Set<UUID>] = [:]
  private var idsByToken: [UUID: Set<AnyEffectID>] = [:]
  private var cancelledTokensAwaitingFinish: Set<UUID> = []
  private var preparedRuns: UInt64 = 0
  private var attachedRuns: UInt64 = 0
  private var finishedRuns: UInt64 = 0
  private var emissionDecisionCount: UInt64 = 0
  private var cancellationCount: UInt64 = 0

  package init() {}

  /// Registers a run in the same MainActor turn that created its task, so no
  /// cancellation can be accepted between the two.
  package func register(
    token: UUID,
    id: AnyEffectID?,
    sequence: UInt64,
    context: EffectExecutionContext? = nil,
    task: Task<Void, Never>,
    liveness: EffectRunLiveness = .init()
  ) {
    register(
      token: token,
      ids: id.map { [$0] } ?? [],
      sequence: sequence,
      context: context,
      task: task,
      liveness: liveness
    )
  }

  package func register(
    token: UUID,
    ids: [AnyEffectID],
    sequence: UInt64,
    context: EffectExecutionContext? = nil,
    task: Task<Void, Never>,
    liveness: EffectRunLiveness = .init()
  ) {
    preparedRuns &+= 1
    attachedRuns &+= 1
    runs[token] = .init(task: task, sequence: sequence, context: context, liveness: liveness)
    let uniqueIDs = Set(ids)
    if uniqueIDs.isEmpty == false {
      idsByToken[token] = uniqueIDs
      for id in uniqueIDs {
        tokensByID[id, default: []].insert(token)
      }
    }
  }

  package func finish(token: UUID) {
    if let run = runs[token] {
      finishedRuns &+= 1
      run.liveness.deactivate()
      cancelledTokensAwaitingFinish.remove(token)
      removeToken(token)
      return
    }

    if cancelledTokensAwaitingFinish.remove(token) != nil {
      finishedRuns &+= 1
    }
  }

  package func cancel(id: AnyEffectID, upTo sequence: UInt64) {
    cancellationCount &+= 1
    guard let tokens = tokensByID[id] else { return }

    for token in Array(tokens) {
      guard let run = runs[token] else {
        cancelTrackedRun(token)
        continue
      }
      if run.sequence <= sequence || run.context?.isCancelled(id: id) == true {
        cancelTrackedRun(token)
      }
    }
  }

  package func cancelAll(upTo sequence: UInt64) {
    cancellationCount &+= 1
    for (token, run) in runs
    where run.sequence <= sequence || run.context?.shouldProceed == false {
      cancelTrackedRun(token)
    }
  }

  package func emissionDecision(
    token: UUID,
    id: AnyEffectID?,
    sequence: UInt64
  ) -> EffectEmissionDecision {
    emissionDecision(token: token, ids: id.map { [$0] } ?? [], sequence: sequence)
  }

  package func emissionDecision(
    token: UUID,
    ids: [AnyEffectID],
    sequence: UInt64
  ) -> EffectEmissionDecision {
    emissionDecisionCount &+= 1
    guard let run = runs[token] else { return .drop(.inactiveToken) }
    if run.context?.shouldProceed == false {
      return .drop(.cancellationBoundary)
    }
    let registeredIDs = idsByToken[token] ?? []
    if Set(ids).isSubset(of: registeredIDs) == false {
      return .drop(.inactiveToken)
    }
    return .allow
  }

  package func metricsSnapshot() -> MetricsSnapshot {
    .init(
      preparedRuns: preparedRuns,
      attachedRuns: attachedRuns,
      finishedRuns: finishedRuns,
      emissionDecisions: emissionDecisionCount,
      cancellations: cancellationCount
    )
  }

  package func activeCancellationIDCount() -> Int {
    tokensByID.count
  }

  package func cancellationTargetDispatchIDs(
    id: AnyEffectID,
    upTo sequence: UInt64
  ) -> Set<DispatchID> {
    guard let tokens = tokensByID[id] else { return [] }
    return Set(
      tokens.compactMap { token in
        guard let run = runs[token] else { return nil }
        guard
          run.sequence <= sequence
            || run.context?.isCancelled(id: id) == true
        else { return nil }
        return run.context?.dispatchID
      }
    )
  }

  package func cancellationTargetDispatchIDs(upTo sequence: UInt64) -> Set<DispatchID> {
    Set(
      runs.values.compactMap { run in
        guard
          run.sequence <= sequence
            || run.context?.shouldProceed == false
        else { return nil }
        return run.context?.dispatchID
      }
    )
  }

  private func removeToken(_ token: UUID) {
    _ = runs.removeValue(forKey: token)
    let ids = idsByToken.removeValue(forKey: token) ?? []

    for id in ids {
      guard var tokens = tokensByID[id] else { continue }
      tokens.remove(token)
      if tokens.isEmpty {
        tokensByID.removeValue(forKey: id)
      } else {
        tokensByID[id] = tokens
      }
    }
  }

  private func cancelTrackedRun(_ token: UUID) {
    if let run = runs[token] {
      run.task.cancel()
      run.liveness.deactivate()
      cancelledTokensAwaitingFinish.insert(token)
    }
    removeToken(token)
  }
}

package enum EffectEmissionDecision {
  case allow
  case drop(ActionDropReason)
}
