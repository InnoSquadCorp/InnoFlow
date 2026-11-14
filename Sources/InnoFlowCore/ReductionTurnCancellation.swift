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

  /// Marks every effect sequence issued before `context`'s own as superseded
  /// under `id`, so its work can no longer have an action reduced.
  ///
  /// Used for a `latest` lane request. Only the marking happens here: the
  /// lane itself displaces and releases the superseded run when it admits
  /// the replacement, which is what reports it as superseded rather than
  /// cancelled.
  func markSupersededInReductionTurn(id: AnyEffectID, context: EffectExecutionContext)
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
  package func acceptSynchronousCancellations(
    in effect: ReducerEffect<Action, Output>,
    context: EffectExecutionContext
  ) {
    var cancelledBySelf: Set<AnyEffectID> = []
    _ = acceptSynchronousCancellations(
      in: effect,
      context: context,
      cancelledBySelf: &cancelledBySelf
    )
  }

  /// - Returns: `true` when the subtree completes without asynchronous work,
  ///   which is what lets an enclosing `concatenate` reach its next child.
  private func acceptSynchronousCancellations(
    in effect: ReducerEffect<Action, Output>,
    context: EffectExecutionContext,
    cancelledBySelf: inout Set<AnyEffectID>
  ) -> Bool {
    /// Whether the interpreter will still admit work in `context` once it has
    /// applied the cancellations this tree issued before reaching it.
    func proceeds(_ context: EffectExecutionContext) -> Bool {
      guard context.shouldProceed else { return false }
      return cancelledBySelf.isEmpty
        || !context.cancellationIDs.contains(where: cancelledBySelf.contains)
    }

    switch effect.operation {
    case .none, .send, .output, .diagnosticDrop:
      return true

    case .run, .throttle:
      // An admitted run or throttle awaits; a skipped one returns at its
      // admission guard.
      return !proceeds(context)

    case .scheduledRun(let id, let policy, _, _, _):
      guard proceeds(context) else { return true }
      if case .latest = policy {
        // A `latest` request supersedes its predecessors when it is
        // returned, not when the lane eventually admits it. The lane rejects
        // a request whose own context is already cancelled, and such a
        // request replaces nothing.
        let scheduledContext = EffectExecutionContext.withCancellation(id, on: context)
        if proceeds(scheduledContext) {
          markSupersededInReductionTurn(id: id, context: scheduledContext)
        }
      }
      return false

    case .cancel(let id):
      guard proceeds(context) else { return true }
      acceptInReductionTurn(.all(id), context: context)
      cancelledBySelf.insert(id)
      return true

    case .cancellable(let nested, let id, let cancelInFlight):
      guard proceeds(context) else { return true }
      if cancelInFlight {
        acceptInReductionTurn(.inFlight(id), context: context)
      }
      return acceptSynchronousCancellations(
        in: nested,
        context: .withCancellation(id, on: context),
        cancelledBySelf: &cancelledBySelf
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
          in: child, context: context, cancelledBySelf: &cancelledBySelf)
        completesSynchronously = completesSynchronously && childCompletes
      }
      return completesSynchronously

    case .concatenate(let children):
      for child in children {
        guard proceeds(context) else { return true }
        guard
          acceptSynchronousCancellations(
            in: child, context: context, cancelledBySelf: &cancelledBySelf)
        else {
          return false
        }
      }
      return true

    case .animation(let nested, _):
      return acceptSynchronousCancellations(
        in: nested, context: context, cancelledBySelf: &cancelledBySelf)

    case .owned(let owner, let nested):
      return acceptSynchronousCancellations(
        in: nested,
        context: .withOwner(owner, on: context),
        cancelledBySelf: &cancelledBySelf
      )

    case .optionalChild, .lifetimeScope:
      preconditionFailure("Child lifetime metadata must be prepared synchronously after reduction")
    }
  }
}
