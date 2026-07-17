// MARK: - EffectRuntime.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

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
    origin: EffectOrigin? = nil
  ) -> EffectExecutionContext {
    let ownedScope = scopes.makeScopeAndInterpreterLease(
      sequence: sequence,
      potentialCancellationIDs: potentialCancellationIDs.union(cancellationIDs)
    )
    var context = EffectExecutionContext.managedRoot(
      cancellationScope: ownedScope.scope,
      interpreterLease: ownedScope.lease,
      animation: animation,
      sequence: sequence,
      origin: origin
    )
    for id in cancellationIDs {
      context = .withCancellation(id, on: context)
    }
    return context
  }

  package func nextContext(
    potentialCancellationIDs: Set<AnyEffectID> = [],
    animation: EffectAnimation? = nil,
    origin: EffectOrigin? = nil
  ) -> EffectExecutionContext {
    makeContext(
      sequence: nextSequence(),
      potentialCancellationIDs: potentialCancellationIDs,
      animation: animation,
      origin: origin
    )
  }

  package func shouldProceed(context: EffectExecutionContext?) -> Bool {
    context?.shouldProceed ?? true
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

/// EffectRuntime owns token/task bookkeeping for cancellable `.run` effects.
///
/// Invariants:
/// - every prepared token must be either attached to a task or finished/removed
/// - `tokensByID`, `idsByToken`, and `tasks` must stay symmetric for live tokens
/// - cancellation admission comes from the run's frozen sequence scope/tokens
package actor EffectRuntime<Action: Sendable> {
  private struct TrackedRun {
    let task: Task<Void, Never>
    let sequence: UInt64
    let context: EffectExecutionContext?
  }

  package struct MetricsSnapshot: Sendable, Equatable {
    package let preparedRuns: UInt64
    package let attachedRuns: UInt64
    package let finishedRuns: UInt64
    package let emissionDecisions: UInt64
    package let cancellations: UInt64
  }

  private var activeTokens: Set<UUID> = []
  private var tasks: [UUID: TrackedRun] = [:]
  private var tokensByID: [AnyEffectID: Set<UUID>] = [:]
  private var idsByToken: [UUID: Set<AnyEffectID>] = [:]
  private var cancelledTokensAwaitingFinish: Set<UUID> = []
  private var preparedRuns: UInt64 = 0
  private var attachedRuns: UInt64 = 0
  private var finishedRuns: UInt64 = 0
  private var emissionDecisionCount: UInt64 = 0
  private var cancellationCount: UInt64 = 0

  package func registerAndStart(
    token: UUID,
    id: AnyEffectID?,
    sequence: UInt64,
    context: EffectExecutionContext? = nil,
    task: Task<Void, Never>,
    gate: RunStartGate
  ) async {
    await registerAndStart(
      token: token,
      ids: id.map { [$0] } ?? [],
      sequence: sequence,
      context: context,
      task: task,
      gate: gate
    )
  }

  package func registerAndStart(
    token: UUID,
    ids: [AnyEffectID],
    sequence: UInt64,
    context: EffectExecutionContext? = nil,
    task: Task<Void, Never>,
    gate: RunStartGate
  ) async {
    preparedRuns &+= 1
    attachedRuns &+= 1
    activeTokens.insert(token)
    tasks[token] = .init(task: task, sequence: sequence, context: context)
    let uniqueIDs = Set(ids)
    if uniqueIDs.isEmpty == false {
      idsByToken[token] = uniqueIDs
      for id in uniqueIDs {
        tokensByID[id, default: []].insert(token)
      }
    }
    await gate.open()
  }

  package func finish(token: UUID) {
    if activeTokens.contains(token) {
      finishedRuns &+= 1
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
    cancelTrackedTasks(for: id, upTo: sequence)
  }

  package func cancelInFlight(id: AnyEffectID, upTo sequence: UInt64) {
    cancellationCount &+= 1
    cancelTrackedTasks(for: id, upTo: sequence)
  }

  package func cancelAll(upTo sequence: UInt64) {
    cancellationCount &+= 1
    let snapshot = Array(activeTokens)
    for token in snapshot {
      guard let trackedRun = tasks[token] else {
        cancelTrackedTask(token)
        continue
      }
      if trackedRun.sequence <= sequence || trackedRun.context?.shouldProceed == false {
        cancelTrackedTask(token)
      }
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
    return cancellationDecision(token: token, ids: ids, sequence: sequence)
  }

  package func canStartOperation(
    token: UUID,
    id: AnyEffectID?,
    sequence: UInt64
  ) -> Bool {
    canStartOperation(token: token, ids: id.map { [$0] } ?? [], sequence: sequence)
  }

  package func canStartOperation(
    token: UUID,
    ids: [AnyEffectID],
    sequence: UInt64
  ) -> Bool {
    if Task.isCancelled {
      return false
    }
    switch cancellationDecision(token: token, ids: ids, sequence: sequence) {
    case .allow:
      return true
    case .drop:
      return false
    }
  }

  private func cancellationDecision(
    token: UUID,
    ids: [AnyEffectID],
    sequence: UInt64
  ) -> EffectEmissionDecision {
    guard activeTokens.contains(token) else { return .drop(.inactiveToken) }
    if tasks[token]?.context?.shouldProceed == false {
      return .drop(.cancellationBoundary)
    }
    let registeredIDs = idsByToken[token] ?? []
    if Set(ids).isSubset(of: registeredIDs) == false {
      return .drop(.inactiveToken)
    }
    return .allow
  }

  package func checkCancellation(
    token: UUID,
    id: AnyEffectID?,
    sequence: UInt64
  ) throws {
    try checkCancellation(token: token, ids: id.map { [$0] } ?? [], sequence: sequence)
  }

  package func checkCancellation(
    token: UUID,
    ids: [AnyEffectID],
    sequence: UInt64
  ) throws {
    if Task.isCancelled {
      throw CancellationError()
    }
    switch emissionDecision(token: token, ids: ids, sequence: sequence) {
    case .allow:
      return
    case .drop:
      throw CancellationError()
    }
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

  private func removeToken(_ token: UUID) {
    activeTokens.remove(token)
    _ = tasks.removeValue(forKey: token)
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

  private func cancelTrackedTasks(for id: AnyEffectID, upTo sequence: UInt64) {
    guard let tokens = tokensByID[id] else { return }

    for token in Array(tokens) {
      guard let trackedRun = tasks[token] else {
        cancelTrackedTask(token)
        continue
      }
      if trackedRun.sequence <= sequence || trackedRun.context?.isCancelled(id: id) == true {
        cancelTrackedTask(token)
      }
    }
  }

  private func cancelTrackedTask(_ token: UUID) {
    tasks[token]?.task.cancel()
    if activeTokens.contains(token) {
      cancelledTokensAwaitingFinish.insert(token)
    }
    removeToken(token)
  }
}

package enum EffectEmissionDecision {
  case allow
  case drop(ActionDropReason)
}
