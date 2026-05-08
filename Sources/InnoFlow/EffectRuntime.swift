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
  private var cancelledUpToAll: UInt64 = 0
  private var cancelledUpToByID: [AnyEffectID: UInt64] = [:]

  package init() {}

  package var currentSequence: UInt64 {
    lastIssuedSequence
  }

  package func nextSequence() -> UInt64 {
    lastIssuedSequence &+= 1
    return lastIssuedSequence
  }

  package func shouldStart(sequence: UInt64, cancellationID: AnyEffectID?) -> Bool {
    shouldStart(sequence: sequence, cancellationIDs: cancellationID.map { [$0] } ?? [])
  }

  package func shouldStart(sequence: UInt64, cancellationIDs: [AnyEffectID]) -> Bool {
    if sequence <= cancelledUpToAll {
      return false
    }
    return cancellationIDs.allSatisfy { id in
      sequence > (cancelledUpToByID[id] ?? 0)
    }
  }

  package func shouldProceed(context: EffectExecutionContext?) -> Bool {
    guard let sequence = context?.sequence else { return true }
    return shouldStart(sequence: sequence, cancellationIDs: context?.cancellationIDs ?? [])
  }

  @discardableResult
  package func markCancelled(id: AnyEffectID, upTo sequence: UInt64? = nil) -> UInt64 {
    let sequence = sequence ?? lastIssuedSequence
    cancelledUpToByID[id] = max(cancelledUpToByID[id] ?? 0, sequence)
    return sequence
  }

  @discardableResult
  package func markCancelledInFlight(id: AnyEffectID, upTo sequence: UInt64? = nil) -> UInt64 {
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
}

/// EffectRuntime owns token/task bookkeeping for cancellable `.run` effects.
///
/// Invariants:
/// - every prepared token must be either attached to a task or finished/removed
/// - `tokensByID` and `idsByToken` must stay symmetric for live tokens
/// - cancellation boundaries are monotonic and never move backward
package actor EffectRuntime<Action: Sendable> {
  package struct MetricsSnapshot: Sendable, Equatable {
    package let preparedRuns: UInt64
    package let attachedRuns: UInt64
    package let finishedRuns: UInt64
    package let emissionDecisions: UInt64
    package let cancellations: UInt64
  }

  private var activeTokens: Set<UUID> = []
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var tokensByID: [AnyEffectID: Set<UUID>] = [:]
  private var idsByToken: [UUID: Set<AnyEffectID>] = [:]
  private var cancelledTokensAwaitingFinish: Set<UUID> = []
  private var cancelledUpToAll: UInt64 = 0
  private var cancelledUpToByID: [AnyEffectID: UInt64] = [:]
  private var preparedRuns: UInt64 = 0
  private var attachedRuns: UInt64 = 0
  private var finishedRuns: UInt64 = 0
  private var emissionDecisionCount: UInt64 = 0
  private var cancellationCount: UInt64 = 0

  package func registerAndStart(
    token: UUID,
    id: AnyEffectID?,
    task: Task<Void, Never>,
    gate: RunStartGate
  ) async {
    await registerAndStart(
      token: token,
      ids: id.map { [$0] } ?? [],
      task: task,
      gate: gate
    )
  }

  package func registerAndStart(
    token: UUID,
    ids: [AnyEffectID],
    task: Task<Void, Never>,
    gate: RunStartGate
  ) async {
    preparedRuns &+= 1
    attachedRuns &+= 1
    activeTokens.insert(token)
    tasks[token] = task
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
    cancelledUpToByID[id] = max(cancelledUpToByID[id] ?? 0, sequence)
    cancelTrackedTasks(for: id)
  }

  package func cancelInFlight(id: AnyEffectID, upTo sequence: UInt64) {
    cancellationCount &+= 1
    cancelledUpToByID[id] = max(cancelledUpToByID[id] ?? 0, sequence)
    cancelTrackedTasks(for: id)
  }

  package func cancelAll(upTo sequence: UInt64) {
    cancellationCount &+= 1
    cancelledUpToAll = max(cancelledUpToAll, sequence)
    cancelledUpToByID.removeAll(keepingCapacity: true)
    let snapshot = Array(activeTokens)
    for token in snapshot {
      cancelTrackedTask(token)
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
    if sequence <= cancelledUpToAll {
      return .drop(.cancellationBoundary)
    }
    for id in ids {
      if sequence <= (cancelledUpToByID[id] ?? 0) {
        return .drop(.cancellationBoundary)
      }
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

  private func cancelTrackedTasks(for id: AnyEffectID) {
    guard let tokens = tokensByID[id] else { return }

    for token in tokens {
      cancelTrackedTask(token)
    }
  }

  private func cancelTrackedTask(_ token: UUID) {
    tasks[token]?.cancel()
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
