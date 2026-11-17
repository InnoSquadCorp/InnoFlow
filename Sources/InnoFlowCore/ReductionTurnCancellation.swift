// MARK: - ReductionTurnCancellation.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

/// A runtime that accepts reducer-returned cancellation in the MainActor turn
/// of the reduction that returned it.
///
/// `Store` and `TestStore` interpret an effect tree in a later task. Without
/// this pass an emission from work the reducer has just cancelled — or
/// replaced through `cancelInFlight: true`, a newer debounce request or a
/// `latest` lane request — can still be reduced in the gap between that
/// reduction and the interpreter task. Both runtimes share one traversal so
/// a test observes the ordering production code has.
@MainActor
package protocol ReductionTurnCancellationAcceptor: AnyObject {
  associatedtype Action: Sendable
  associatedtype Output: Sendable

  /// Accepts `request` for every effect sequence issued before `context`'s
  /// own, and records that the interpreter must not accept that part again.
  ///
  /// The sequence that issued the request is deliberately left alone: its own
  /// effect tree is interpreted in declaration order, so an earlier sibling
  /// of a `.cancel` still runs before that cancel takes effect.
  func acceptInReductionTurn(
    _ request: EffectCancellationRequest,
    context: EffectExecutionContext
  )

  /// The run lane a request under `id` meets now, if any: an open lane, or
  /// a `latest` lane displaced for a replacement that can still proceed.
  ///
  /// The pass decides each lane request it reaches against this lane, with
  /// the same rule admission applies. A `latest` request that a lane with
  /// another policy rejects replaces nothing, and a request the lane rejects
  /// completes without awaiting.
  func runLane(for id: AnyEffectID) -> EffectRunLaneView?

  /// Accepts a `latest` lane request that its lane will admit, for every
  /// effect sequence issued before `context`'s own, exactly as admitting it
  /// would: the lane's earlier requests are displaced and reported as
  /// superseded, and every other effect under `id` is released and recorded.
  ///
  /// The acceptance is complete in this turn, like `cancelInFlight: true`, so
  /// nothing is left half-cancelled when the request itself never reaches
  /// admission (its dispatch is cancelled before the interpreter runs).
  func acceptLatestReplacementInReductionTurn(id: AnyEffectID, context: EffectExecutionContext)
}

extension ReductionTurnCancellationAcceptor {
  /// Accepts every cancellation the interpreter would reach without awaiting
  /// asynchronous work.
  ///
  /// The traversal mirrors `EffectWalker`'s admission guards with the real
  /// execution context, and simulates the cancellations this same tree
  /// applies to itself on the way: a subtree the interpreter will skip
  /// because an earlier sibling cancelled its ID completes without awaiting,
  /// so a later sibling is still reached in this turn.
  ///
  /// A lane request the pass reaches is admitted against the lane state of
  /// this turn. A request the lane rejects, or one whose own tree cancelled
  /// its lane ID first, completes without awaiting; the pass records that
  /// outcome and keeps scanning, and the interpreter reports exactly that
  /// outcome later, whatever the lane looks like by then. A request the lane
  /// admits awaits its run, so the scan stops there.
  package func acceptSynchronousCancellations(
    in effect: ReducerEffect<Action, Output>,
    context: EffectExecutionContext
  ) {
    var turn = ReductionTurnState()
    _ = acceptSynchronousCancellations(in: effect, context: context, turn: &turn)
  }

  /// - Returns: `true` when the subtree completes without asynchronous work,
  ///   which is what lets an enclosing `concatenate` reach its next child.
  private func acceptSynchronousCancellations(
    in effect: ReducerEffect<Action, Output>,
    context: EffectExecutionContext,
    turn: inout ReductionTurnState
  ) -> Bool {
    /// Whether the interpreter will still admit work in `context` once it has
    /// applied the cancellations this tree issued before reaching it.
    func proceeds(_ context: EffectExecutionContext) -> Bool {
      guard context.shouldProceed else { return false }
      return turn.cancelledBySelf.isEmpty
        || !context.cancellationIDs.contains(where: turn.cancelledBySelf.contains)
    }

    switch effect.operation {
    case .none, .send, .output, .diagnosticDrop:
      return true

    case .run, .throttle:
      // An admitted run or throttle awaits; a skipped one returns at its
      // admission guard.
      return !proceeds(context)

    case .scheduledRun(let id, let policy, _, _, _):
      // The interpreter skips a request whose enclosing context it will not
      // admit before the lane sees it.
      guard proceeds(context) else { return true }
      let scheduledContext = EffectExecutionContext.withCancellation(id, on: context)
      let admission = admitInReductionTurn(
        id: id,
        policy: policy.kind,
        context: scheduledContext,
        proceeds: proceeds(scheduledContext),
        turn: &turn
      )
      scheduledContext.cancellationScope?.recordTurnLaneAdmission(
        admission,
        cancellationIDs: scheduledContext.cancellationIDs,
        policy: policy.kind
      )
      // A request the lane does not admit awaits nothing, so a later
      // `concatenate` sibling is still reached in this turn.
      if case .completed = admission { return true }
      return false

    case .cancel(let id):
      guard proceeds(context) else { return true }
      acceptInReductionTurn(.all(id), context: context)
      turn.cancelledBySelf.insert(id)
      return true

    case .cancellable(let nested, let id, let cancelInFlight):
      guard proceeds(context) else { return true }
      if cancelInFlight {
        acceptInReductionTurn(.inFlight(id), context: context)
      }
      return acceptSynchronousCancellations(
        in: nested,
        context: .withCancellation(id, on: context),
        turn: &turn
      )

    case .debounce(_, let id, _):
      guard proceeds(context) else { return true }
      // A newer debounce request supersedes its predecessors when it is
      // returned, not when its timer is eventually scheduled.
      acceptInReductionTurn(.inFlight(id), context: .withCancellation(id, on: context))
      return false

    case .merge(let children):
      guard proceeds(context) else { return true }
      var completesSynchronously = true
      for child in children {
        let childCompletes = acceptSynchronousCancellations(
          in: child, context: context, turn: &turn)
        completesSynchronously = completesSynchronously && childCompletes
      }
      return completesSynchronously

    case .concatenate(let children):
      for child in children {
        guard proceeds(context) else { return true }
        guard
          acceptSynchronousCancellations(
            in: child, context: context, turn: &turn)
        else {
          return false
        }
      }
      return true

    case .animation(let nested, _):
      return acceptSynchronousCancellations(
        in: nested, context: context, turn: &turn)

    case .owned(let owner, let nested):
      return acceptSynchronousCancellations(
        in: nested,
        context: .withOwner(owner, on: context),
        turn: &turn
      )

    case .optionalChild, .lifetimeScope:
      preconditionFailure("Child lifetime metadata must be prepared synchronously after reduction")
    }
  }

  /// Decides a lane request against the lane state of this turn, with the
  /// rule admission applies: the lane open now, as changed by the requests
  /// this tree admitted before it.
  private func admitInReductionTurn(
    id: AnyEffectID,
    policy: EffectExecutionPolicy.Kind,
    context: EffectExecutionContext,
    proceeds: Bool,
    turn: inout ReductionTurnState
  ) -> ReductionTurnLaneAdmission {
    // The request's own tree cancelled its lane ID on the way.
    guard proceeds else { return .completed(.cancelledBeforeStart) }
    let sequence = context.sequence ?? 0
    let lane = turn.lane(for: id, current: runLane(for: id))
    switch EffectRunScheduler.decide(policy: policy, sequence: sequence, lane: lane) {
    case .open, .replace:
      if case .latest = policy {
        // A `latest` request supersedes its predecessors when it is returned,
        // not when the lane eventually admits it.
        acceptLatestReplacementInReductionTurn(id: id, context: context)
      }
      turn.openedLanes[id] = EffectRunLaneView(
        policy: policy, holderSequence: sequence, pendingCount: 0)
      return .admitted
    case .queue:
      turn.queue(on: id)
      return .admitted
    case .reject(let reason):
      return .completed(.rejected(reason))
    case .superseded:
      return .completed(.superseded)
    }
  }
}

/// What one reduction-turn pass has simulated so far.
private struct ReductionTurnState {
  /// IDs this tree cancelled on the way; the interpreter skips their work.
  var cancelledBySelf: Set<AnyEffectID> = []
  /// Lanes a request of this tree opened or took over on the way.
  var openedLanes: [AnyEffectID: EffectRunLaneView] = [:]
  /// Requests of this tree queued on a lane it did not open.
  var queuedOnOpenLanes: [AnyEffectID: Int] = [:]

  /// The lane a later request of this tree meets: one the tree opened, or
  /// the lane open now with the requests this tree queued on it. The lane is
  /// read again for every request, because a cancellation the pass accepted
  /// on the way can have released part of it.
  func lane(for id: AnyEffectID, current: EffectRunLaneView?) -> EffectRunLaneView? {
    if let opened = openedLanes[id] { return opened }
    guard var lane = current else { return nil }
    lane.pendingCount += queuedOnOpenLanes[id] ?? 0
    return lane
  }

  mutating func queue(on id: AnyEffectID) {
    if openedLanes[id] != nil {
      openedLanes[id]?.pendingCount += 1
    } else {
      queuedOnOpenLanes[id, default: 0] += 1
    }
  }
}
