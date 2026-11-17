// MARK: - Store+CancellationAcceptance.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

extension Store {
  /// Accepts an ID cancellation and releases everything it owns.
  ///
  /// Exact-ID tokens are marked, instrumentation is recorded, and every piece
  /// of owned work — pending scheduled requests, composite tasks, delayed
  /// state and run tasks — is released before this call returns. No
  /// suspension point separates acceptance from release, with or without
  /// diagnostics, so the cancelled work cannot have an action reduced and
  /// lane capacity is returned immediately.
  @discardableResult
  package func acceptCancellation(
    _ request: EffectCancellationRequest,
    context: EffectExecutionContext?
  ) -> UInt64 {
    let id = request.id
    let sequence: UInt64
    switch request {
    case .all:
      sequence = effectBridge.markCancelled(id: id, upTo: context?.sequence)
    case .inFlight:
      sequence = effectBridge.markCancelledInFlight(id: id, upTo: context?.sequence)
    }
    recordCancellation(id: id, sequence: sequence, dispatchID: context?.dispatchID)
    if diagnostics != nil {
      let targets = effectBridge.cancellationTargetDispatchIDs(id: id, upTo: sequence)
      recordDiagnosticCancellations(targets, sequence: sequence, hasEffectID: true)
    }
    effectBridge.cancelEffects(id: id, upTo: sequence)
    return sequence
  }

  /// Accepts cancellation of every effect and releases everything it owns.
  @discardableResult
  package func acceptCancellationOfAllEffects() -> UInt64 {
    let sequence = effectBridge.markCancelledAll()
    recordCancellation(id: nil, sequence: sequence)
    if diagnostics != nil {
      let targets = effectBridge.cancellationTargetDispatchIDs(upTo: sequence)
      recordDiagnosticCancellations(targets, sequence: sequence, hasEffectID: false)
    }
    effectBridge.cancelAllEffects(upTo: sequence)
    return sequence
  }

  /// Applies a cancellation the interpreter reached.
  ///
  /// When the reduction turn already accepted the request for every earlier
  /// sequence, only the part it left alone remains: an ID cancellation also
  /// covers the sequence that issued it, and that part is applied here, in
  /// declaration order, without recording the request a second time.
  package func applyCancellation(
    _ request: EffectCancellationRequest,
    context: EffectExecutionContext?
  ) {
    guard context?.cancellationScope?.consumeAcceptedCancellation(request) == true else {
      acceptCancellation(request, context: context)
      return
    }
    guard case .all(let id) = request else { return }

    // Dispatches released in the reduction turn were recorded there; what is
    // left is the work of the issuing sequence. Read it before marking: once
    // marked, that work also matches the earlier boundary through its
    // cancelled token and would be subtracted with the rest.
    var ownTargets: Set<DispatchID> = []
    if diagnostics != nil, let ownSequence = context?.sequence {
      ownTargets = effectBridge.cancellationTargetDispatchIDs(id: id, upTo: ownSequence)
      if ownSequence > 0 {
        ownTargets.subtract(
          effectBridge.cancellationTargetDispatchIDs(id: id, upTo: ownSequence - 1))
      }
    }
    let sequence = effectBridge.markCancelled(id: id, upTo: context?.sequence)
    if diagnostics != nil {
      recordDiagnosticCancellations(ownTargets, sequence: sequence, hasEffectID: true)
    }
    effectBridge.cancelEffects(id: id, upTo: sequence)
  }
}

extension Store: ReductionTurnCancellationAcceptor {
  package func acceptInReductionTurn(
    _ request: EffectCancellationRequest,
    context: EffectExecutionContext
  ) {
    guard let scope = context.cancellationScope else { return }
    switch request {
    case .inFlight:
      // An in-flight request never covers its own sequence.
      acceptCancellation(request, context: context)

    case .all(let id):
      // Release every earlier sequence now. The request is reported once,
      // with the boundary it will have when the interpreter completes it.
      let boundary = effectBridge.markCancelledInFlight(id: id, upTo: context.sequence)
      recordCancellation(
        id: id,
        sequence: context.sequence ?? boundary,
        dispatchID: context.dispatchID
      )
      if diagnostics != nil {
        let targets = effectBridge.cancellationTargetDispatchIDs(id: id, upTo: boundary)
        recordDiagnosticCancellations(targets, sequence: boundary, hasEffectID: true)
      }
      effectBridge.cancelEffects(id: id, upTo: boundary)
    }
    scope.recordAcceptedCancellation(request)
  }

  package func runLane(for id: AnyEffectID) -> EffectRunLaneView? {
    effectBridge.runScheduler.laneView(for: id)
  }

  package func acceptLatestReplacementInReductionTurn(
    id: AnyEffectID,
    context: EffectExecutionContext
  ) {
    guard context.cancellationScope != nil else { return }
    // Admission order: the lane's own requests are displaced and reported as
    // superseded first, then everything else under `id` is released. The
    // interpreter's admission later consumes the recorded acceptance instead
    // of repeating it.
    effectBridge.runScheduler.displaceLatestLane(id: id, successor: context)
    acceptInReductionTurn(.inFlight(id), context: context)
  }
}
