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

/// The lane a scheduled request meets at admission.
package struct EffectRunLaneView: Sendable, Equatable {
  package var policy: EffectExecutionPolicy.Kind
  /// The sequence of the request that holds the lane: its running request, or
  /// the `latest` request a reduction turn accepted and the lane has not
  /// admitted yet.
  package var holderSequence: UInt64
  /// Pending requests that can still proceed.
  package var pendingCount: Int
  /// The IDs of the request whose cancellation closes the lane at once: a
  /// `latest` lane's running request, or the `latest` request a held lane
  /// waits for. Empty for a serial or drop lane, whose running request keeps
  /// its slot when it is cancelled.
  package var ownerCancellationIDs: Set<AnyEffectID>
  /// The IDs of each pending request that can still proceed. Cancelling one
  /// of them frees its slot at once.
  package var pendingCancellationIDs: [Set<AnyEffectID>]

  package init(
    policy: EffectExecutionPolicy.Kind,
    holderSequence: UInt64,
    pendingCount: Int,
    ownerCancellationIDs: Set<AnyEffectID> = [],
    pendingCancellationIDs: [Set<AnyEffectID>] = []
  ) {
    self.policy = policy
    self.holderSequence = holderSequence
    self.pendingCount = pendingCount
    self.ownerCancellationIDs = ownerCancellationIDs
    self.pendingCancellationIDs = pendingCancellationIDs
  }

  /// The lane a request meets once every ID `isCancelled` selects has been
  /// cancelled: no lane when the request that owns the lane carries one, and
  /// otherwise the lane without the pending requests that carry one.
  package func afterCancellation(of isCancelled: (AnyEffectID) -> Bool) -> EffectRunLaneView? {
    guard !ownerCancellationIDs.contains(where: isCancelled) else { return nil }
    let remaining = pendingCancellationIDs.filter { !$0.contains(where: isCancelled) }
    guard remaining.count != pendingCancellationIDs.count else { return self }
    var lane = self
    lane.pendingCount -= pendingCancellationIDs.count - remaining.count
    lane.pendingCancellationIDs = remaining
    return lane
  }
}

/// What a lane does with a request whose own context can still proceed.
package enum EffectRunLaneDecision: Sendable, Equatable {
  /// No lane is open: the request opens one and starts.
  case open
  /// A `latest` request replaces the lane's requests and keeps its identity.
  case replace
  /// A serial request waits behind `position` earlier requests.
  case queue(position: Int)
  case reject(EffectAdmissionRejection)
  /// An older `latest` request meets a lane a newer request holds.
  case superseded

  /// Whether the lane admits the request, which then awaits its run.
  package var admitsRequest: Bool {
    switch self {
    case .open, .replace, .queue: true
    case .reject, .superseded: false
    }
  }

  /// Whether both decisions give the request the same outcome: the lane
  /// admits it, rejects it for the same reason, or a newer request holds it.
  package func hasSameOutcome(as other: EffectRunLaneDecision) -> Bool {
    (admitsRequest && other.admitsRequest) || self == other
  }
}

/// The admission a reduction turn decided for one lane request that the
/// interpreter reaches without awaiting asynchronous work.
package enum ReductionTurnLaneAdmission: Sendable, Equatable {
  /// The lane admits the request. Its run is awaited, so the interpreter
  /// admits it against the lane it meets then.
  case admitted
  /// The request completes without awaiting. The interpreter reports exactly
  /// this admission without consulting the lane again, so the cancellations
  /// the turn accepted behind it stay consistent with what the interpreter
  /// does.
  case completed(EffectAdmission)
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
    let context: EffectExecutionContext?
    let onStart: @MainActor @Sendable (UUID) -> Void
    let onPendingExit: @MainActor @Sendable (UUID) -> Void
    let onCancellation: @MainActor @Sendable (DispatchID, UInt64) -> Void
    let onAdmissionLifecycle: @MainActor @Sendable (UUID?, EffectAdmission) -> Void
    let onCancellationEvent: @MainActor @Sendable (EffectRunCancellationCause) -> Void
    var hasStarted = false
    var cancellationReported = false
    var task: Task<Void, Never>?
    var operationTask: Task<Void, Never>?

    /// Whether the request can still start. A request whose dispatch or
    /// owning ID was cancelled can no longer proceed even before that
    /// cancellation reaches the scheduler.
    var canProceed: Bool {
      !cancellationState.isCancelled
        && context?.shouldProceed != false
        && task?.isCancelled != true
    }
  }

  private struct Lane {
    let diagnosticID: EffectRunLaneID
    let policy: EffectExecutionPolicy.Kind
    var running: UUID
    var pending: [UUID]
  }

  /// A `latest` lane that a reduction turn holds for a request it accepted
  /// and the lane has not admitted yet.
  private struct HeldLatestLane {
    /// The identity of the lane the turn displaced; `nil` when no lane was
    /// open, so the request opens a new one.
    let diagnosticID: EffectRunLaneID?
    /// The sequence and IDs of the newest request accepted for the lane.
    let sequence: UInt64
    let cancellationIDs: Set<AnyEffectID>
    /// Whether that request can still be admitted. The check keeps nothing
    /// of the request alive, so a lane held for a request that was cancelled
    /// or abandoned retains neither its dispatch nor its cancellation scope.
    let canStillBeAdmitted: @Sendable () -> Bool

    init(diagnosticID: EffectRunLaneID?, successor: EffectExecutionContext, sequence: UInt64) {
      self.diagnosticID = diagnosticID
      self.sequence = sequence
      self.cancellationIDs = Set(successor.cancellationIDs)
      self.canStillBeAdmitted = successor.makeUnretainedProceedCheck()
    }
  }

  private var requests: [UUID: Request] = [:]
  private var lanes: [AnyEffectID: Lane] = [:]
  private var requestTokensByCancellationID: [AnyEffectID: Set<UUID>] = [:]
  /// `latest` lanes held in a reduction turn: one the turn displaced, or one
  /// that was closed when the turn accepted its request. Until that request
  /// is admitted, such a lane is the open `latest` lane under its ID: the
  /// request opens it, under the displaced lane's identity if there was one,
  /// and a request with another policy meets a conflicting lane. Once the
  /// request can no longer be admitted — it was cancelled, its dispatch
  /// finished without reaching it, or its admission turned it away — the
  /// lane is closed, and the next lane under that ID is new.
  private var heldLatestLanes: [AnyEffectID: HeldLatestLane] = [:]

  package init() {}

  /// Decides a request's admission from the lane it meets.
  ///
  /// Side-effect free: the reduction turn predicts admission with it and
  /// ``admit(id:policy:cancellationIDs:sequence:dispatchID:onCancellation:onStart:onPendingExit:context:onAdmissionLifecycle:onCancellationEvent:)``
  /// acts on it, so both apply one rule.
  package nonisolated static func decide(
    policy: EffectExecutionPolicy.Kind,
    sequence: UInt64,
    lane: EffectRunLaneView?
  ) -> EffectRunLaneDecision {
    guard let lane else { return .open }
    guard lane.policy == policy else { return .reject(.conflictingPolicy) }
    switch policy {
    case .latest:
      return sequence < lane.holderSequence ? .superseded : .replace
    case .dropWhileRunning:
      return .reject(.busy)
    case .serial(let maxPending):
      guard UInt(lane.pendingCount) < maxPending else {
        return .reject(.queueFull(maxPending: maxPending))
      }
      return .queue(position: lane.pendingCount + 1)
    }
  }

  /// The lane a request under `id` meets now: an open lane, or a `latest`
  /// lane held for a request that can still proceed. Pending requests that
  /// can no longer proceed are not counted. Side-effect free.
  package func laneView(for id: AnyEffectID) -> EffectRunLaneView? {
    if let lane = lanes[id] {
      let running = requests[lane.running]
      let pendingCancellationIDs = lane.pending.compactMap { token -> Set<AnyEffectID>? in
        guard let request = requests[token], request.canProceed else { return nil }
        return request.cancellationIDs
      }
      return EffectRunLaneView(
        policy: lane.policy,
        holderSequence: running?.sequence ?? 0,
        pendingCount: pendingCancellationIDs.count,
        ownerCancellationIDs: lane.policy == .latest ? running?.cancellationIDs ?? [] : [],
        pendingCancellationIDs: pendingCancellationIDs
      )
    }
    if let held = heldLatestLanes[id], held.canStillBeAdmitted() {
      return EffectRunLaneView(
        policy: .latest,
        holderSequence: held.sequence,
        pendingCount: 0,
        ownerCancellationIDs: held.cancellationIDs
      )
    }
    return nil
  }

  /// Holds the `latest` lane under `id` for a `latest` request that the
  /// reduction which returned it has accepted, exactly as admitting that
  /// request does: an open lane's running request is cancelled and reported
  /// superseded, and until the request is admitted the lane is its own, so
  /// no request with another policy can open it first.
  ///
  /// `successor` is the accepted request's context. A lane whose running
  /// request was issued in or after the successor's sequence belongs to a
  /// newer request and is left alone, as is a lane with another policy.
  package func holdLatestLane(id: AnyEffectID, successor: EffectExecutionContext) {
    guard let sequence = successor.sequence else { return }
    if !heldLatestLanes.isEmpty {
      heldLatestLanes = heldLatestLanes.filter { $0.value.canStillBeAdmitted() }
    }
    guard let lane = lanes[id] else {
      // No lane is open. A newer request, accepted before the previous one
      // was admitted, carries the held lane's identity on; the first request
      // for a closed lane holds a lane with no identity yet.
      heldLatestLanes[id] = HeldLatestLane(
        diagnosticID: heldLatestLanes[id]?.diagnosticID,
        successor: successor,
        sequence: sequence
      )
      return
    }
    guard lane.policy == .latest,
      let running = requests[lane.running], running.sequence < sequence
    else { return }
    lanes.removeValue(forKey: id)
    heldLatestLanes[id] = HeldLatestLane(
      diagnosticID: lane.diagnosticID,
      successor: successor,
      sequence: sequence
    )
    let displacedRequests = displace(lane)
    deliverCancellation(to: displacedRequests)
    guard !displacedRequests.isEmpty else { return }
    // The displaced requests are already cancelled; rejecting their gates
    // only wakes tasks still waiting to start, which then finish.
    let gates = displacedRequests.map(\.gate)
    Task { @MainActor in
      for gate in gates {
        await gate.reject()
      }
    }
  }

  /// Removes and reports every request of a lane that a `latest` request
  /// replaces. The caller has already removed the lane. It delivers task
  /// cancellation once the scheduler state is final, and rejects the
  /// returned requests' gates.
  private func displace(_ lane: Lane) -> [Request] {
    let displacedRequests = ([lane.running] + lane.pending).compactMap { removeRequest($0) }
    for displacedRequest in displacedRequests {
      displacedRequest.cancellationState.cancel()
      displacedRequest.onAdmissionLifecycle(displacedRequest.token, .superseded)
      if !displacedRequest.cancellationReported {
        displacedRequest.onCancellationEvent(.superseded)
      }
      if let dispatchID = displacedRequest.dispatchID {
        displacedRequest.onCancellation(dispatchID, displacedRequest.sequence)
      }
      if lane.pending.contains(displacedRequest.token) {
        displacedRequest.onPendingExit(displacedRequest.token)
      }
    }
    return displacedRequests
  }

  /// Cancels the tasks of requests the scheduler no longer tracks. Task
  /// cancellation runs cancellation handlers synchronously, and a handler may
  /// re-enter the scheduler, so this always comes after every state update.
  private func deliverCancellation(to requests: [Request]) {
    for request in requests {
      request.operationTask?.cancel()
      request.task?.cancel()
    }
  }

  package var activeRequestCount: Int {
    requests.count
  }

  /// Snapshot work is paid only by the explicit diagnostic reader.
  package func snapshots(limit: Int) -> [EffectRunLaneSnapshot] {
    guard limit > 0 else { return [] }
    return lanes.values.sorted { $0.diagnosticID.description < $1.diagnosticID.description }
      .prefix(limit).compactMap { lane in
        guard let head = requests[lane.running] else { return nil }
        let policy: EffectExecutionPolicy
        switch lane.policy {
        case .latest: policy = .latest
        case .dropWhileRunning: policy = .dropWhileRunning
        case .serial(let capacity): policy = .serial(maxPending: capacity)
        }
        return EffectRunLaneSnapshot(
          id: lane.diagnosticID,
          policy: policy,
          isStartAdmitted: head.hasStarted,
          pendingRequestCount: livePendingCount(of: lane),
          isCancellationRequested: head.cancellationState.isCancelled
            || head.context?.shouldProceed == false
            || head.task?.isCancelled == true
        )
      }
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
    onAdmissionLifecycle: @escaping @MainActor @Sendable (UUID?, EffectAdmission) -> Void = {
      _, _ in
    },
    onCancellationEvent: @escaping @MainActor @Sendable (EffectRunCancellationCause) -> Void = {
      _ in
    }
  ) async -> Plan {
    let kind = policy.kind
    // A request the reduction turn passed without awaiting keeps the
    // admission that turn gave it; the turn may have accepted cancellations
    // behind it on that basis.
    if let context,
      case .completed(let admission) = context.cancellationScope?.consumeTurnLaneAdmission(
        cancellationIDs: context.cancellationIDs, policy: kind)
    {
      onAdmissionLifecycle(nil, admission)
      if case .rejected(let reason) = admission {
        return .rejected(reason)
      }
      return .terminal(admission)
    }

    // Check the exact tokens introduced by the scheduled node, not just its
    // enclosing structural context. A cancelled deferred request must never
    // reserve capacity or supersede a newer live request.
    guard !Task.isCancelled, context?.shouldProceed != false else {
      // The request a lane is held for is turned away: the lane is closed.
      if kind == .latest, let held = heldLatestLanes[id], held.sequence == sequence,
        held.cancellationIDs == Set(cancellationIDs + [id])
      {
        heldLatestLanes.removeValue(forKey: id)
      }
      onAdmissionLifecycle(nil, .cancelledBeforeStart)
      return .terminal(.cancelledBeforeStart)
    }

    // A pending request that can no longer proceed never counts toward
    // capacity, even before its cancellation reaches the scheduler.
    releasePendingRequestsThatCannotProceed(in: id)
    let decision = Self.decide(policy: kind, sequence: sequence, lane: laneView(for: id))
    switch decision {
    case .reject(let reason):
      onAdmissionLifecycle(nil, .rejected(reason))
      return .rejected(reason)
    case .superseded:
      onAdmissionLifecycle(nil, .superseded)
      return .terminal(.superseded)
    case .open, .replace, .queue:
      break
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
      context: context?.frozenForExecution(),
      onStart: onStart,
      onPendingExit: onPendingExit,
      onCancellation: onCancellation,
      onAdmissionLifecycle: onAdmissionLifecycle,
      onCancellationEvent: onCancellationEvent,
      task: nil,
      operationTask: nil
    )
    let ticket = { (admission: EffectAdmission) in
      Ticket(
        token: token,
        id: id,
        sequence: sequence,
        gate: gate,
        admission: admission,
        cancellationState: cancellationState
      )
    }

    switch decision {
    case .queue(let position):
      lanes[id]?.pending.append(token)
      register(request)
      onAdmissionLifecycle(token, .queued(position: position))
      return .accepted(ticket(.queued(position: position)))

    case .replace:
      // The request keeps the identity of the lane it replaces, whether that
      // lane is still open or was displaced in a reduction turn. A lane the
      // turn held for the first request of a closed lane has none yet.
      let heldLane = heldLatestLanes.removeValue(forKey: id)
      let replacedLane = lanes.removeValue(forKey: id)
      let diagnosticID =
        replacedLane?.diagnosticID ?? heldLane?.diagnosticID ?? EffectRunLaneID(token)
      let displacedRequests = replacedLane.map { displace($0) } ?? []
      register(request)
      lanes[id] = Lane(diagnosticID: diagnosticID, policy: kind, running: token, pending: [])
      // Publish the replacement before cancellation handlers run and before
      // crossing an actor boundary. Otherwise a reentrant admission can
      // install a newer lane only to have it overwritten here.
      deliverCancellation(to: displacedRequests)
      for displacedRequest in displacedRequests {
        await displacedRequest.gate.reject()
      }
      return .accepted(ticket(.started))

    case .open:
      // A held lane whose request can no longer proceed is closed.
      heldLatestLanes.removeValue(forKey: id)
      register(request)
      lanes[id] = Lane(
        diagnosticID: EffectRunLaneID(token), policy: kind, running: token, pending: [])
      return .accepted(ticket(.started))

    case .reject, .superseded:
      preconditionFailure("A request the lane does not admit returns above")
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
      !request.hasStarted, lanes[request.id]?.running == token
    else { return }
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

    guard lane.running == token else {
      lane.pending.removeAll { $0 == token }
      lanes[request.id] = lane
      if !request.hasStarted, !request.cancellationReported {
        request.onAdmissionLifecycle(token, .cancelledBeforeStart)
      }
      request.onPendingExit(token)
      return
    }
    guard case .serial = lane.policy else {
      lanes.removeValue(forKey: request.id)
      return
    }
    // A reservation that can no longer proceed is released, never promoted.
    releasePendingRequestsThatCannotProceed(in: request.id)
    guard var promoted = lanes[request.id], !promoted.pending.isEmpty else {
      lanes.removeValue(forKey: request.id)
      return
    }
    let next = promoted.pending.removeFirst()
    promoted.running = next
    lanes[request.id] = promoted
    // A promoted reservation can still be awaiting attachment. The
    // attachment and promotion paths share exactly-once start admission.
    await startIfAttached(next)
  }

  /// Releases the pending requests of the lane under `id` that can no longer
  /// proceed — their dispatch or an ID they carry was cancelled, but that
  /// cancellation has not reached the scheduler yet — through the same
  /// terminal path as an explicit cancellation. The cancellation that later
  /// reaches the scheduler finds nothing left to do.
  private func releasePendingRequestsThatCannotProceed(in id: AnyEffectID) {
    guard let pending = lanes[id]?.pending, !pending.isEmpty else { return }
    for token in pending {
      if let request = requests[token] {
        if !request.canProceed { cancel(token: token) }
      } else {
        // Skip missing reservations directly; finishing a missing token
        // cannot remove it from its lane.
        lanes[id]?.pending.removeAll { $0 == token }
      }
    }
  }

  private func livePendingCount(of lane: Lane) -> Int {
    lane.pending.count { requests[$0]?.canProceed == true }
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
    let reportCancellation = !request.cancellationReported
    request.cancellationReported = true
    let lane = lanes[request.id]
    // A running serial or drop request keeps its physical slot, including a
    // not-yet-attached reservation, until its operation returns.
    let keepsSlot = lane?.running == token && lane?.policy != .latest
    if keepsSlot {
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
    }
    if reportCancellation {
      if !request.hasStarted {
        request.onAdmissionLifecycle(token, .cancelledBeforeStart)
      }
      request.onCancellationEvent(.explicit)
    }
    if let lane, lane.running != token { request.onPendingExit(token) }
    // The scheduler state is final before any cancellation handler runs: a
    // handler that re-enters finds this request already cancelled.
    deliverCancellation(to: [request])
    if !keepsSlot {
      Task { await request.gate.reject() }
    }
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
    heldLatestLanes.removeAll(keepingCapacity: false)
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
