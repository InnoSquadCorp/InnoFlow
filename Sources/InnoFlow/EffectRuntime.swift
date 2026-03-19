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

/// EffectRuntime owns token/task bookkeeping for cancellable `.run` effects.
///
/// Invariants:
/// - every prepared token must be either attached to a task or finished/removed
/// - `tokensByID` and `idByToken` must stay symmetric for live tokens
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
  private var tokensByID: [EffectID: Set<UUID>] = [:]
  private var idByToken: [UUID: EffectID] = [:]
  private var cancelledUpToAll: UInt64 = 0
  private var cancelledUpToByID: [EffectID: UInt64] = [:]
  private var preparedRuns: UInt64 = 0
  private var attachedRuns: UInt64 = 0
  private var finishedRuns: UInt64 = 0
  private var emissionDecisionCount: UInt64 = 0
  private var cancellationCount: UInt64 = 0

  package func registerAndStart(
    token: UUID,
    id: EffectID?,
    task: Task<Void, Never>,
    gate: RunStartGate
  ) async {
    preparedRuns &+= 1
    attachedRuns &+= 1
    activeTokens.insert(token)
    tasks[token] = task
    if let id {
      idByToken[token] = id
      tokensByID[id, default: []].insert(token)
    }
    await gate.open()
  }

  package func finish(token: UUID) {
    finishedRuns &+= 1
    removeToken(token)
  }

  package func cancel(id: EffectID, upTo sequence: UInt64) {
    cancellationCount &+= 1
    cancelledUpToByID[id] = max(cancelledUpToByID[id] ?? 0, sequence)
    cancelTrackedTasks(for: id)
  }

  package func cancelInFlight(id: EffectID, upTo sequence: UInt64) {
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
      tasks[token]?.cancel()
      removeToken(token)
    }
  }

  package func emissionDecision(
    token: UUID,
    id: EffectID?,
    sequence: UInt64
  ) -> EffectEmissionDecision {
    emissionDecisionCount &+= 1
    guard activeTokens.contains(token) else { return .drop(.inactiveToken) }
    if sequence <= cancelledUpToAll {
      return .drop(.cancellationBoundary)
    }
    if let id, sequence <= (cancelledUpToByID[id] ?? 0) {
      return .drop(.cancellationBoundary)
    }
    if let id, idByToken[token] != id {
      return .drop(.inactiveToken)
    }
    return .allow
  }

  package func checkCancellation(
    token: UUID,
    id: EffectID?,
    sequence: UInt64
  ) throws {
    if Task.isCancelled {
      throw CancellationError()
    }
    switch emissionDecision(token: token, id: id, sequence: sequence) {
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

  private func removeToken(_ token: UUID, id explicitID: EffectID? = nil) {
    activeTokens.remove(token)
    _ = tasks.removeValue(forKey: token)
    let id = explicitID ?? idByToken[token]
    idByToken.removeValue(forKey: token)

    guard let id, var ids = tokensByID[id] else { return }
    ids.remove(token)
    if ids.isEmpty {
      tokensByID.removeValue(forKey: id)
    } else {
      tokensByID[id] = ids
    }
  }

  private func cancelTrackedTasks(for id: EffectID) {
    guard let tokens = tokensByID[id] else { return }

    for token in tokens {
      tasks[token]?.cancel()
      removeToken(token, id: id)
    }
  }
}

package enum EffectEmissionDecision {
  case allow
  case drop(ActionDropReason)
}
