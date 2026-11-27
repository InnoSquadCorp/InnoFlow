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
  /// a `latest` lane held for a request a reduction turn accepted, while
  /// that request can still proceed.
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
  /// The lane, also one that was closed, is held for the request until it is
  /// admitted or can no longer proceed, so a request with another policy
  /// cannot open it first.
  ///
  /// The acceptance is complete in this turn, like `cancelInFlight: true`, so
  /// nothing is left half-cancelled when the request itself never reaches
  /// admission (its dispatch is cancelled before the interpreter runs).
  func acceptLatestReplacementInReductionTurn(id: AnyEffectID, context: EffectExecutionContext)
}

extension ReductionTurnCancellationAcceptor {
  /// Accepts every cancellation the interpreter reaches without awaiting
  /// asynchronous work, in whatever order it runs `merge` children.
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
  ///
  /// The pass walks `merge` children in declaration order, but the
  /// interpreter runs them in any order. Work whose outcome another branch
  /// of an enclosing `merge` can change is therefore order-dependent, and
  /// the pass decides nothing for it: it treats that work as awaiting, so the
  /// scan of its branch stops there and the interpreter decides it. That
  /// covers work whose context another branch can cancel (`.cancel` of one
  /// of its IDs), and a lane request that shares its lane with a lane request
  /// in another branch, whose IDs another branch cancels, or whose lane
  /// answers differently once another branch has requested the cancellation
  /// of a request that holds it: the request that owns a `latest` lane (its
  /// running request, or the request a held lane waits for), without which a
  /// request with another policy meets no lane, or a pending request of a
  /// full serial lane, without which a serial request is queued. A request
  /// the lane admits or rejects either way is decided. A cancellation request
  /// is a `.cancel`, `cancelInFlight: true`, a debounce or a `latest` lane
  /// request; a throttle decides only its own window and requests none. All
  /// but `.cancel` cancel in flight: their ID cancellation covers only
  /// sequences issued before their own, so under a lane request's own IDs
  /// they cannot cancel the request, while they can release a request that
  /// holds its lane. Within one sequence a debounce still replaces a pending
  /// debounce under its ID and a `latest` request displaces its own lane's
  /// requests, but the pass decides no work inside a debounce and no request
  /// whose lane another branch requests. Another branch's work counts
  /// wherever it is in that branch, also behind asynchronous work.
  /// Everything the pass does decide therefore holds in every order the
  /// interpreter may pick.
  package func acceptSynchronousCancellations(
    in effect: ReducerEffect<Action, Output>,
    context: EffectExecutionContext
  ) {
    var turn = ReductionTurnState()
    _ = acceptSynchronousCancellations(
      in: effect, context: context, siblings: MergeSiblings(), turn: &turn)
  }

  /// - Returns: `true` when the subtree completes without asynchronous work,
  ///   which is what lets an enclosing `concatenate` reach its next child.
  private func acceptSynchronousCancellations(
    in effect: ReducerEffect<Action, Output>,
    context: EffectExecutionContext,
    siblings: MergeSiblings,
    turn: inout ReductionTurnState
  ) -> Bool {
    /// Whether the interpreter will still admit work in `context` once it has
    /// applied the cancellations this tree issued before reaching it, or
    /// `nil` when that depends on the order it runs `merge` children in.
    ///
    /// An ID this tree cancelled on the way stops the work only when no other
    /// branch of an enclosing `merge` cancels it: such a cancel may have been
    /// recorded by a branch the interpreter reaches after this work.
    func proceeds(_ context: EffectExecutionContext) -> Bool? {
      guard context.shouldProceed else { return false }
      let ids = context.cancellationIDs
      if ids.contains(where: { turn.cancelledBySelf.contains($0) && !siblings.cancel($0) }) {
        return false
      }
      if ids.contains(where: siblings.cancel) { return nil }
      return true
    }

    switch effect.operation {
    case .none, .send, .output, .diagnosticDrop:
      return true

    case .run, .throttle:
      // An admitted run or throttle awaits; a skipped one returns at its
      // admission guard.
      return proceeds(context) == false

    case .scheduledRun(let id, let policy, _, _, _):
      // The interpreter skips a request whose enclosing context it will not
      // admit before the lane sees it.
      guard let enclosingProceeds = proceeds(context) else { return false }
      guard enclosingProceeds else { return true }
      let scheduledContext = EffectExecutionContext.withCancellation(id, on: context)
      // Another branch can change the lane, or cancel the request, before
      // the interpreter admits it or after: only admission can decide it.
      guard
        !siblings.mayReorder(laneRequest: id, cancellationIDs: scheduledContext.cancellationIDs),
        let requestProceeds = proceeds(scheduledContext)
      else { return false }
      let lane = runLane(for: id)
      // So can a branch that cancels a request holding the lane, when the
      // lane answers this request differently without it. A request its own
      // tree cancelled completes whatever the lane is.
      if requestProceeds,
        siblings.mayChangeAdmission(
          policy: policy.kind, sequence: scheduledContext.sequence ?? 0, lane: lane)
      {
        return false
      }
      let admission = admitInReductionTurn(
        id: id,
        policy: policy.kind,
        context: scheduledContext,
        proceeds: requestProceeds,
        lane: lane
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
      guard let proceeding = proceeds(context) else { return false }
      guard proceeding else { return true }
      acceptInReductionTurn(.all(id), context: context)
      turn.cancelledBySelf.insert(id)
      return true

    case .cancellable(let nested, let id, let cancelInFlight):
      guard let proceeding = proceeds(context) else { return false }
      guard proceeding else { return true }
      if cancelInFlight {
        acceptInReductionTurn(.inFlight(id), context: context)
      }
      return acceptSynchronousCancellations(
        in: nested,
        context: .withCancellation(id, on: context),
        siblings: siblings,
        turn: &turn
      )

    case .debounce(_, let id, _):
      guard let proceeding = proceeds(context) else { return false }
      guard proceeding else { return true }
      // A newer debounce request supersedes its predecessors when it is
      // returned, not when its timer is eventually scheduled.
      acceptInReductionTurn(.inFlight(id), context: .withCancellation(id, on: context))
      return false

    case .merge(let children):
      guard let proceeding = proceeds(context) else { return false }
      guard proceeding else { return true }
      let branches = MergeBranches(children)
      var completesSynchronously = true
      for (index, child) in children.enumerated() {
        let childCompletes = acceptSynchronousCancellations(
          in: child,
          context: context,
          siblings: siblings.entering(branch: index, of: branches),
          turn: &turn
        )
        completesSynchronously = completesSynchronously && childCompletes
      }
      return completesSynchronously

    case .concatenate(let children):
      for child in children {
        guard let proceeding = proceeds(context) else { return false }
        guard proceeding else { return true }
        guard
          acceptSynchronousCancellations(
            in: child, context: context, siblings: siblings, turn: &turn)
        else {
          return false
        }
      }
      return true

    case .animation(let nested, _):
      return acceptSynchronousCancellations(
        in: nested, context: context, siblings: siblings, turn: &turn)

    case .owned(let owner, let nested):
      return acceptSynchronousCancellations(
        in: nested,
        context: .withOwner(owner, on: context),
        siblings: siblings,
        turn: &turn
      )

    case .optionalChild, .lifetimeScope:
      preconditionFailure("Child lifetime metadata must be prepared synchronously after reduction")
    }
  }

  /// Decides a lane request against `lane`, the lane it meets now, with the
  /// rule admission applies.
  ///
  /// The request is order-independent, so no other lane request or
  /// cancellation of this tree can change its admission first: an earlier
  /// request on the same lane in the same branch either completed without
  /// changing the lane or was admitted, which stops the scan before this
  /// one, and no other branch requests the lane or cancels a request whose
  /// loss changes what the lane answers.
  private func admitInReductionTurn(
    id: AnyEffectID,
    policy: EffectExecutionPolicy.Kind,
    context: EffectExecutionContext,
    proceeds: Bool,
    lane: EffectRunLaneView?
  ) -> ReductionTurnLaneAdmission {
    // The request's own tree cancelled its lane ID on the way.
    guard proceeds else { return .completed(.cancelledBeforeStart) }
    let sequence = context.sequence ?? 0
    switch EffectRunScheduler.decide(policy: policy, sequence: sequence, lane: lane) {
    case .open, .replace:
      if case .latest = policy {
        // A `latest` request supersedes its predecessors when it is returned,
        // not when the lane eventually admits it.
        acceptLatestReplacementInReductionTurn(id: id, context: context)
      }
      return .admitted
    case .queue:
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
}

/// The IDs one subtree touches anywhere: work the interpreter reaches only
/// after awaiting, and delayed work, count as much as work it reaches at once.
private struct EffectFootprint {
  /// Lanes the subtree requests.
  var laneIDs: Set<AnyEffectID> = []
  /// IDs the subtree cancels, its own sequence included (`.cancel`).
  var cancelledIDs: Set<AnyEffectID> = []
  /// IDs the subtree requests any cancellation of, which can release work
  /// another effect owns under them: `.cancel`, `cancelInFlight: true`, a
  /// `latest` lane request or a debounce request. A throttle request decides
  /// only its own window and releases nothing.
  var releasedIDs: Set<AnyEffectID> = []

  mutating func collect<Action, Output>(_ effect: ReducerEffect<Action, Output>) {
    switch effect.operation {
    case .none, .send, .output, .run, .diagnosticDrop:
      return
    case .scheduledRun(let id, let policy, _, _, _):
      laneIDs.insert(id)
      if case .latest = policy {
        releasedIDs.insert(id)
      }
    case .cancel(let id):
      cancelledIDs.insert(id)
      releasedIDs.insert(id)
    case .cancellable(let nested, let id, let cancelInFlight):
      if cancelInFlight {
        releasedIDs.insert(id)
      }
      collect(nested)
    case .debounce(let nested, let id, _):
      releasedIDs.insert(id)
      collect(nested)
    case .throttle(let nested, _, _, _, _):
      collect(nested)
    case .merge(let children), .concatenate(let children):
      for child in children {
        collect(child)
      }
    case .animation(let nested, _), .owned(_, let nested), .lifetimeScope(_, let nested):
      collect(nested)
    case .optionalChild(_, _, _, let child, let parent):
      collect(child)
      collect(parent)
    }
  }
}

/// Which branches of one `merge` touch each ID.
private struct MergeBranches {
  private enum Holders {
    case one(Int)
    case several
  }

  private var lanes: [AnyEffectID: Holders] = [:]
  private var cancelled: [AnyEffectID: Holders] = [:]
  private var released: [AnyEffectID: Holders] = [:]

  init<Action, Output>(_ branches: [ReducerEffect<Action, Output>]) {
    for (index, branch) in branches.enumerated() {
      var footprint = EffectFootprint()
      footprint.collect(branch)
      Self.add(footprint.laneIDs, branch: index, to: &lanes)
      Self.add(footprint.cancelledIDs, branch: index, to: &cancelled)
      Self.add(footprint.releasedIDs, branch: index, to: &released)
    }
  }

  var isEmpty: Bool {
    lanes.isEmpty && released.isEmpty
  }

  private static func add(
    _ ids: Set<AnyEffectID>, branch: Int, to holders: inout [AnyEffectID: Holders]
  ) {
    for id in ids {
      switch holders[id] {
      case nil:
        holders[id] = .one(branch)
      case .one(let holder) where holder != branch:
        holders[id] = .several
      case .one, .several:
        break
      }
    }
  }

  private static func another(
    than branch: Int, in holders: [AnyEffectID: Holders], holds id: AnyEffectID
  ) -> Bool {
    switch holders[id] {
    case nil: return false
    case .one(let holder): return holder != branch
    case .several: return true
    }
  }

  /// Whether a branch other than `branch` requests the lane `id`.
  func otherBranch(than branch: Int, requestsLane id: AnyEffectID) -> Bool {
    Self.another(than: branch, in: lanes, holds: id)
  }

  /// Whether a branch other than `branch` cancels `id`, its own sequence
  /// included.
  func otherBranch(than branch: Int, cancels id: AnyEffectID) -> Bool {
    Self.another(than: branch, in: cancelled, holds: id)
  }

  /// Whether a branch other than `branch` requests any cancellation of `id`,
  /// which can release work another effect owns under it.
  func otherBranch(than branch: Int, releasesWorkUnder id: AnyEffectID) -> Bool {
    Self.another(than: branch, in: released, holds: id)
  }
}

/// What the other branches of the `merge` nodes enclosing a node touch: work
/// the interpreter may run before that node or after it.
private struct MergeSiblings {
  private var levels: [(branches: MergeBranches, branch: Int)] = []

  /// The siblings of `branch`'s subtree in a `merge` whose branches are
  /// `branches`.
  func entering(branch: Int, of branches: MergeBranches) -> MergeSiblings {
    guard !branches.isEmpty else { return self }
    var siblings = self
    siblings.levels.append((branches, branch))
    return siblings
  }

  /// Whether another branch cancels `id`, its own sequence included.
  func cancel(_ id: AnyEffectID) -> Bool {
    levels.contains { $0.branches.otherBranch(than: $0.branch, cancels: id) }
  }

  /// Whether another branch can decide a lane request first or last: it
  /// requests the same lane, or cancels one of the request's IDs. The ID
  /// cancellation of a request that cancels in flight (`cancelInFlight:
  /// true`, a debounce, a `latest` lane request) covers only sequences issued
  /// before its own, and a throttle decides only its own window, so neither
  /// cancels the request. The `.cancel` check restates `proceeds`: the pass
  /// has checked the enclosing IDs with `proceeds(context)` already, and
  /// checks the lane ID with `proceeds(scheduledContext)` in the same guard.
  func mayReorder(laneRequest lane: AnyEffectID, cancellationIDs: [AnyEffectID]) -> Bool {
    levels.contains { level in
      level.branches.otherBranch(than: level.branch, requestsLane: lane)
        || cancellationIDs.contains { level.branches.otherBranch(than: level.branch, cancels: $0) }
    }
  }

  /// Whether another branch requests any cancellation of `id`, which can
  /// release work another effect owns under it.
  func releaseWork(under id: AnyEffectID) -> Bool {
    levels.contains { $0.branches.otherBranch(than: $0.branch, releasesWorkUnder: id) }
  }

  /// Whether another branch can change what `lane` answers a request with
  /// `policy`: it can release an ID carried by a request that holds the lane
  /// (a `.cancel`, `cancelInFlight: true`, a debounce or a `latest` lane
  /// request under that ID; a throttle releases nothing), and the lane admits
  /// or rejects the request differently once that request is gone.
  func mayChangeAdmission(
    policy: EffectExecutionPolicy.Kind, sequence: UInt64, lane: EffectRunLaneView?
  ) -> Bool {
    guard let lane, !levels.isEmpty else { return false }
    let laneWithoutCancelledHolders = lane.afterCancellation(of: releaseWork(under:))
    guard laneWithoutCancelledHolders != lane else { return false }
    return !EffectRunScheduler.decide(policy: policy, sequence: sequence, lane: lane)
      .hasSameOutcome(
        as: EffectRunScheduler.decide(
          policy: policy, sequence: sequence, lane: laneWithoutCancelledHolders))
  }
}
