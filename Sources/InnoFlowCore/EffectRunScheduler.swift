// MARK: - EffectRunScheduler.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

/// Cancellation-aware gate between Store admission and physical run start.
package actor EffectAdmissionGate {
  private var result: Bool?
  private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

  package func wait() async -> Bool {
    if let result { return result }
    let waiterID = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if let result {
          continuation.resume(returning: result)
        } else {
          waiters[waiterID] = continuation
        }
      }
    } onCancel: {
      Task { await self.cancelWaiter(waiterID) }
    }
  }

  package func start() {
    resolve(true)
  }

  package func reject() {
    resolve(false)
  }

  private func resolve(_ value: Bool) {
    guard result == nil else { return }
    result = value
    let continuations = waiters.values
    waiters.removeAll(keepingCapacity: false)
    for continuation in continuations {
      continuation.resume(returning: value)
    }
  }

  private func cancelWaiter(_ id: UUID) {
    guard let continuation = waiters.removeValue(forKey: id) else { return }
    continuation.resume(returning: false)
  }
}

/// Store-local admission state shared by production and testing drivers.
@MainActor
package final class EffectRunScheduler {
  package struct Ticket: Sendable {
    package let token: UUID
    package let id: AnyEffectID
    package let sequence: UInt64
    package let gate: EffectAdmissionGate
    package let admission: EffectAdmission
    package let cancellationState: EffectRunCancellationState
  }

  package enum Plan: Sendable {
    case accepted(Ticket)
    case rejected(EffectAdmissionRejection)
  }

  private struct Request {
    let token: UUID
    let id: AnyEffectID
    let cancellationIDs: Set<AnyEffectID>
    let sequence: UInt64
    let policy: EffectExecutionPolicy.Kind
    let gate: EffectAdmissionGate
    let cancellationState: EffectRunCancellationState
    let dispatchID: DispatchID?
    let onStart: @MainActor @Sendable (UUID) -> Void
    let onPendingExit: @MainActor @Sendable (UUID) -> Void
    var task: Task<Void, Never>?
    var operationTask: Task<Void, Never>?
  }

  private struct Lane {
    let policy: EffectExecutionPolicy.Kind
    var running: UUID
    var pending: [UUID]
  }

  private var requests: [UUID: Request] = [:]
  private var lanes: [AnyEffectID: Lane] = [:]
  private var requestTokensByCancellationID: [AnyEffectID: Set<UUID>] = [:]

  package init() {}

  package var activeRequestCount: Int {
    requests.count
  }

  package func admit(
    id: AnyEffectID,
    policy: EffectExecutionPolicy,
    cancellationIDs: [AnyEffectID],
    sequence: UInt64,
    dispatchID: DispatchID?,
    onCancellation: @escaping @MainActor @Sendable (DispatchID, UInt64) -> Void,
    onStart: @escaping @MainActor @Sendable (UUID) -> Void,
    onPendingExit: @escaping @MainActor @Sendable (UUID) -> Void
  ) async -> Plan {
    if case .serial(let maxPending) = policy, maxPending < 0 {
      return .rejected(.invalidCapacity(maxPending))
    }

    let kind = policy.kind
    if let lane = lanes[id], lane.policy != kind {
      return .rejected(.conflictingPolicy)
    }

    let token = UUID()
    let gate = EffectAdmissionGate()
    let cancellationState = EffectRunCancellationState()
    let request = Request(
      token: token,
      id: id,
      cancellationIDs: Set(cancellationIDs + [id]),
      sequence: sequence,
      policy: kind,
      gate: gate,
      cancellationState: cancellationState,
      dispatchID: dispatchID,
      onStart: onStart,
      onPendingExit: onPendingExit,
      task: nil,
      operationTask: nil
    )
    switch kind {
    case .latest:
      var displacedRequests: [Request] = []
      if let lane = lanes.removeValue(forKey: id) {
        let displaced = [lane.running] + lane.pending
        for displacedToken in displaced {
          guard let displacedRequest = removeRequest(displacedToken) else {
            continue
          }
          displacedRequest.cancellationState.cancel()
          if let dispatchID = displacedRequest.dispatchID {
            onCancellation(dispatchID, displacedRequest.sequence)
          }
          displacedRequest.task?.cancel()
          displacedRequest.operationTask?.cancel()
          if lane.pending.contains(displacedToken) {
            displacedRequest.onPendingExit(displacedRequest.token)
          }
          displacedRequests.append(displacedRequest)
        }
      }
      register(request)
      lanes[id] = Lane(policy: kind, running: token, pending: [])
      // Publish the replacement before crossing an actor boundary. Otherwise a
      // reentrant admission can install a newer lane while this call is
      // suspended, only to have that lane overwritten when this call resumes.
      for displacedRequest in displacedRequests {
        await displacedRequest.gate.reject()
      }
      return .accepted(
        Ticket(
          token: token,
          id: id,
          sequence: sequence,
          gate: gate,
          admission: .started,
          cancellationState: cancellationState
        )
      )

    case .dropWhileRunning:
      guard lanes[id] == nil else { return .rejected(.busy) }
      register(request)
      lanes[id] = Lane(policy: kind, running: token, pending: [])
      return .accepted(
        Ticket(
          token: token,
          id: id,
          sequence: sequence,
          gate: gate,
          admission: .started,
          cancellationState: cancellationState
        )
      )

    case .serial(let maxPending):
      guard var lane = lanes[id] else {
        register(request)
        lanes[id] = Lane(policy: kind, running: token, pending: [])
        return .accepted(
          Ticket(
            token: token,
            id: id,
            sequence: sequence,
            gate: gate,
            admission: .started,
            cancellationState: cancellationState
          )
        )
      }
      guard lane.pending.count < maxPending else {
        return .rejected(.queueFull(maxPending: maxPending))
      }
      lane.pending.append(token)
      lanes[id] = lane
      register(request)
      return .accepted(
        Ticket(
          token: token,
          id: id,
          sequence: sequence,
          gate: gate,
          admission: .queued(position: lane.pending.count),
          cancellationState: cancellationState
        )
      )
    }
  }

  /// Attaches lifecycle ownership before a request is allowed to start.
  @discardableResult
  package func attach(_ task: Task<Void, Never>, to ticket: Ticket) async -> Bool {
    guard var request = requests[ticket.token] else {
      task.cancel()
      await ticket.gate.reject()
      return false
    }
    request.task = task
    requests[ticket.token] = request

    guard lanes[ticket.id]?.running == ticket.token else { return true }
    request.onStart(request.token)
    await request.gate.start()
    return true
  }

  /// Attaches the physical operation task to its scheduler request.
  @discardableResult
  package func attachOperation(_ task: Task<Void, Never>, to ticket: Ticket) -> Bool {
    guard var request = requests[ticket.token], request.cancellationState.isCancelled == false
    else {
      task.cancel()
      return false
    }
    request.operationTask = task
    requests[ticket.token] = request
    return true
  }

  /// Marks physical completion and advances a serial lane if one is waiting.
  package func finish(_ token: UUID) async {
    guard let request = removeRequest(token) else { return }
    guard var lane = lanes[request.id] else { return }

    if lane.running == token {
      guard case .serial = lane.policy, let next = lane.pending.first else {
        lanes.removeValue(forKey: request.id)
        return
      }

      lane.pending.removeFirst()
      lane.running = next
      lanes[request.id] = lane
      guard let nextRequest = requests[next] else {
        await finish(next)
        return
      }
      nextRequest.onStart(nextRequest.token)
      await nextRequest.gate.start()
      return
    }

    lane.pending.removeAll { $0 == token }
    lanes[request.id] = lane
    request.onPendingExit(request.token)
  }

  /// Cancels matching requests. A running serial/drop lane is retained until
  /// its operation physically returns, so cancellation cannot create overlap.
  @discardableResult
  package func cancel(id: AnyEffectID, upTo sequence: UInt64) -> Set<DispatchID> {
    var dispatchIDs: Set<DispatchID> = []
    let tokens = Array(requestTokensByCancellationID[id] ?? [])
    for token in tokens {
      guard let request = requests[token], request.sequence <= sequence else { continue }
      request.cancellationState.cancel()
      request.operationTask?.cancel()
      if let dispatchID = request.dispatchID {
        dispatchIDs.insert(dispatchID)
      }

      guard let lane = lanes[request.id] else {
        _ = removeRequest(token)
        request.task?.cancel()
        Task { await request.gate.reject() }
        continue
      }

      if token == lane.running {
        request.task?.cancel()
        if case .latest = lane.policy {
          _ = removeRequest(token)
          if lanes[request.id]?.running == token {
            lanes.removeValue(forKey: request.id)
          }
          Task { await request.gate.reject() }
        }
      } else {
        _ = removeRequest(token)
        if var currentLane = lanes[request.id] {
          currentLane.pending.removeAll { $0 == token }
          lanes[request.id] = currentLane
        }
        request.task?.cancel()
        request.onPendingExit(request.token)
        Task { await request.gate.reject() }
      }
    }
    return dispatchIDs
  }

  package func cancel(token: UUID) {
    guard let request = requests[token], let lane = lanes[request.id] else { return }
    if lane.running == token {
      request.cancellationState.cancel()
      request.operationTask?.cancel()
      request.task?.cancel()
      if case .latest = lane.policy {
        _ = removeRequest(token)
        lanes.removeValue(forKey: request.id)
        Task { await request.gate.reject() }
      }
      return
    }

    _ = removeRequest(token)
    request.cancellationState.cancel()
    request.operationTask?.cancel()
    var updatedLane = lane
    updatedLane.pending.removeAll { $0 == token }
    lanes[request.id] = updatedLane
    request.task?.cancel()
    request.onPendingExit(request.token)
    Task { await request.gate.reject() }
  }

  @discardableResult
  package func cancelAll(upTo sequence: UInt64) -> Set<DispatchID> {
    var dispatchIDs: Set<DispatchID> = []
    for id in Array(lanes.keys) {
      dispatchIDs.formUnion(cancel(id: id, upTo: sequence))
    }
    return dispatchIDs
  }

  /// Cancels and removes every request during driver shutdown.
  package func cancelAll() {
    let liveRequests = Array(requests.values)
    let pendingTokens = Set(lanes.values.flatMap(\.pending))
    requests.removeAll(keepingCapacity: false)
    lanes.removeAll(keepingCapacity: false)
    requestTokensByCancellationID.removeAll(keepingCapacity: false)
    for request in liveRequests {
      request.cancellationState.cancel()
      request.task?.cancel()
      request.operationTask?.cancel()
      if pendingTokens.contains(request.token) {
        request.onPendingExit(request.token)
      }
      Task { await request.gate.reject() }
    }
  }

  package func cancellationTargetDispatchIDs(
    id: AnyEffectID,
    upTo sequence: UInt64
  ) -> Set<DispatchID> {
    return Set(
      (requestTokensByCancellationID[id] ?? []).compactMap { token in
        guard let request = requests[token], request.sequence <= sequence else { return nil }
        return request.dispatchID
      }
    )
  }

  package func cancellationTargetDispatchIDs(upTo sequence: UInt64) -> Set<DispatchID> {
    Set(
      requests.values.compactMap { request in
        request.sequence <= sequence ? request.dispatchID : nil
      }
    )
  }

  private func register(_ request: Request) {
    requests[request.token] = request
    for id in request.cancellationIDs {
      requestTokensByCancellationID[id, default: []].insert(request.token)
    }
  }

  private func removeRequest(_ token: UUID) -> Request? {
    guard let request = requests.removeValue(forKey: token) else { return nil }
    for id in request.cancellationIDs {
      requestTokensByCancellationID[id]?.remove(token)
      if requestTokensByCancellationID[id]?.isEmpty == true {
        requestTokensByCancellationID.removeValue(forKey: id)
      }
    }
    return request
  }
}
