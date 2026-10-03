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

package enum EffectRunCancellationCause: Sendable, Equatable {
  case explicit
  case superseded
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
    case terminal(EffectAdmission)
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
    let onCancellation: @MainActor @Sendable (DispatchID, UInt64) -> Void
    let onAdmissionLifecycle: @MainActor @Sendable (UUID?, EffectAdmission) -> Void
    let onCancellationEvent: @MainActor @Sendable (EffectRunCancellationCause) -> Void
    var hasStarted = false
    var cancellationReported = false
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
    onPendingExit: @escaping @MainActor @Sendable (UUID) -> Void,
    context: EffectExecutionContext? = nil,
    onAdmissionLifecycle: @escaping @MainActor @Sendable (UUID?, EffectAdmission) -> Void = { _, _ in },
    onCancellationEvent: @escaping @MainActor @Sendable (EffectRunCancellationCause) -> Void = { _ in }
  ) async -> Plan {
    // Check the exact tokens introduced by the scheduled node, not just its
    // enclosing structural context. A cancelled deferred request must never
    // reserve capacity or supersede a newer live request.
    guard !Task.isCancelled, context?.shouldProceed != false else {
      onAdmissionLifecycle(nil, .cancelledBeforeStart)
      return .terminal(.cancelledBeforeStart)
    }

    let kind = policy.kind
    if let lane = lanes[id], lane.policy != kind {
      onAdmissionLifecycle(nil, .rejected(.conflictingPolicy))
      return .rejected(.conflictingPolicy)
    }
    if case .latest = kind,
      let lane = lanes[id], let current = requests[lane.running], sequence < current.sequence
    {
      onAdmissionLifecycle(nil, .superseded)
      return .terminal(.superseded)
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
      onCancellation: onCancellation,
      onAdmissionLifecycle: onAdmissionLifecycle,
      onCancellationEvent: onCancellationEvent,
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
          displacedRequest.onAdmissionLifecycle(displacedRequest.token, .superseded)
          if !displacedRequest.cancellationReported {
            displacedRequest.onCancellationEvent(.superseded)
          }
          if let dispatchID = displacedRequest.dispatchID {
            displacedRequest.onCancellation(dispatchID, displacedRequest.sequence)
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
      guard lanes[id] == nil else {
        onAdmissionLifecycle(nil, .rejected(.busy))
        return .rejected(.busy)
      }
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
      guard UInt(lane.pending.count) < maxPending else {
        onAdmissionLifecycle(nil, .rejected(.queueFull(maxPending: maxPending)))
        return .rejected(.queueFull(maxPending: maxPending))
      }
      lane.pending.append(token)
      lanes[id] = lane
      register(request)
      onAdmissionLifecycle(token, .queued(position: lane.pending.count))
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
    guard !task.isCancelled, !request.cancellationState.isCancelled else {
      cancel(token: ticket.token)
      await request.gate.reject()
      return false
    }
    await startIfAttached(ticket.token)
    return true
  }

  private func startIfAttached(_ token: UUID) async {
    guard var request = requests[token], let task = request.task,
      !request.hasStarted, lanes[request.id]?.running == token else { return }
    guard !task.isCancelled, !request.cancellationState.isCancelled else {
      cancel(token: token)
      await request.gate.reject()
      return
    }
    request.hasStarted = true
    requests[token] = request
    request.onAdmissionLifecycle(token, .started)
    request.onStart(token)
    // Callbacks may re-enter cancellation. Never open a now-invalid gate.
    guard requests[token] != nil, !request.cancellationState.isCancelled else {
      await request.gate.reject()
      return
    }
    await request.gate.start()
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
      guard case .serial = lane.policy else {
        lanes.removeValue(forKey: request.id)
        return
      }
      // Skip missing/cancelled reservations directly. Recursing through
      // finish(missingToken) cannot remove a lane whose request is absent.
      while !lane.pending.isEmpty {
        let next = lane.pending.removeFirst()
        guard let nextRequest = requests[next] else { continue }
        if nextRequest.cancellationState.isCancelled {
          _ = removeRequest(next)
          nextRequest.task?.cancel()
          if !nextRequest.cancellationReported {
            nextRequest.onAdmissionLifecycle(next, .cancelledBeforeStart)
            nextRequest.onCancellationEvent(.explicit)
          }
          nextRequest.onPendingExit(next)
          Task { await nextRequest.gate.reject() }
          continue
        }
        lane.running = next
        lanes[request.id] = lane
        // A promoted reservation can still be awaiting attachment. The
        // attachment and promotion paths share exactly-once start admission.
        await startIfAttached(next)
        return
      }
      lanes.removeValue(forKey: request.id)
      return
    }

    lane.pending.removeAll { $0 == token }
    lanes[request.id] = lane
    if !request.hasStarted, !request.cancellationReported {
      request.onAdmissionLifecycle(token, .cancelledBeforeStart)
    }
    request.onPendingExit(token)
  }

  /// Cancels matching requests. A running serial/drop lane is retained until
  /// its operation physically returns, so cancellation cannot create overlap.
  @discardableResult
  package func cancel(id: AnyEffectID, upTo sequence: UInt64) -> Set<DispatchID> {
    var dispatchIDs: Set<DispatchID> = []
    for token in Array(requestTokensByCancellationID[id] ?? []) {
      guard let request = requests[token], request.sequence <= sequence else { continue }
      if let dispatchID = request.dispatchID { dispatchIDs.insert(dispatchID) }
      cancel(token: token)
    }
    return dispatchIDs
  }

  package func cancel(token: UUID) {
    guard var request = requests[token] else { return }
    request.cancellationState.cancel()
    request.operationTask?.cancel()
    request.task?.cancel()
    let reportCancellation = !request.cancellationReported
    request.cancellationReported = true
    let lane = lanes[request.id]
    if lane?.running == token, lane?.policy != .latest {
      // Keep the physical slot, including a not-yet-attached reservation.
      requests[token] = request
    } else {
      _ = removeRequest(token)
      if var lane {
        if lane.running == token {
          lanes.removeValue(forKey: request.id)
        } else {
          lane.pending.removeAll { $0 == token }
          lanes[request.id] = lane
        }
      }
      Task { await request.gate.reject() }
    }
    if reportCancellation {
      if !request.hasStarted {
        request.onAdmissionLifecycle(token, .cancelledBeforeStart)
      }
      request.onCancellationEvent(.explicit)
    }
    if let lane, lane.running != token { request.onPendingExit(token) }
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
      if !request.cancellationReported {
        if !request.hasStarted {
          request.onAdmissionLifecycle(request.token, .cancelledBeforeStart)
        }
        request.onCancellationEvent(.explicit)
      }
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
