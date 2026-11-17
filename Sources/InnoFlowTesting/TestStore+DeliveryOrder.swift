// MARK: - TestStore+DeliveryOrder.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
package import InnoFlowCore

// A `Store` reduces an effect action the moment an effect delivers it: an
// interpreter `.send` is reduced in the interpreter's MainActor turn, and a
// run's `await send(action)` returns only after the reduction, once the
// reduced action's effect job is queued. A test store buffers the action at
// the same points instead and reduces it when the test receives it. A
// buffered action is therefore one a `Store` would already have reduced, and
// the bookkeeping below keeps a later cancellation, and the order of
// follow-up work, consistent with that:
//
// - The continuation of the effect sequence that delivered a value does not
//   remove it with a cancellation it applies later. Once that continuation has
//   applied one, the value is settled: a `Store` has certainly handled it, and
//   later cancellation of its effect no longer removes it.
// - A cancellation applied while the test reduces a received action — its
//   reduction, the reduction-turn acceptance and the synchronous part of its
//   effect walk — removes every covered value behind it, settled or not: a
//   `Store` reduced that action before any of them was delivered.
// - The actions the synchronous part of that walk delivers go ahead of the
//   actions the received action's run emitted after it.
//
// Every other cancellation keeps removing the covered values it finds, which
// is the `Store` schedule where the cancellation lands first; interleavings a
// `Store` does not order stay in delivery order.

/// The buffered action a test store is reducing, while that reduction lasts.
@MainActor
package final class TestStoreReceivedReduction {
  /// The delivery order of the received action.
  let receivedOrder: UInt64
  /// Every value delivered before this reduction began has a lower order.
  let startOrder: UInt64
  /// The run that emitted the received action.
  let emittingRun: UUID?
  /// The sequence of the effect the reduction returned, once it exists.
  var effectSequence: UInt64?
  /// Whether the reduction and the walk of its effect are still in the
  /// MainActor turn in which they started.
  var isSynchronous = true

  init(receivedOrder: UInt64, emittingRun: UUID?) {
    self.receivedOrder = receivedOrder
    startOrder = TestStoreDelivery.nextOrder
    self.emittingRun = emittingRun
  }
}

extension TestStore {
  /// Reduces an action received from the buffer and walks its effect.
  ///
  /// - Parameters:
  ///   - willReduce: Runs with the current state once the action is known to
  ///     be deliverable, before it is reduced.
  ///   - didReduce: Runs with the state before the reduction, right after it.
  package func reduceReceivedAction(
    _ entry: ActionQueue<R.Action>.QueuedAction,
    source: TestStoreReductionSource,
    location: TestStoreSourceLocation,
    willReduce: (R.State) -> Void,
    didReduce: (R.State) -> Void
  ) async {
    defer { entry.finish() }
    guard entry.isDeliverable else { return }
    let previousState = state
    willReduce(previousState)

    let reduction = TestStoreReceivedReduction(
      receivedOrder: entry.delivery.order,
      emittingRun: entry.delivery.runToken
    )
    receivedReduction = reduction
    // MainActor jobs run in the order they are queued: this one runs at the
    // walk's first suspension, before the walk resumes and before any work
    // the walk started, which ends the synchronous part.
    Task { @MainActor [weak reduction] in
      reduction?.isSynchronous = false
    }
    defer {
      reduction.isSynchronous = false
      if receivedReduction === reduction { receivedReduction = nil }
    }

    let effect = reduceAction(entry.action, source: source, location: location)
    didReduce(previousState)
    let context = reductionTurnContext(
      for: effect, location: location, flowTaskTracker: entry.context?.flowTaskTracker)
    reduction.effectSequence = context.sequence
    await walker.walk(effect, context: context, awaited: false)
  }

  /// Buffers an effect action, ahead of the received action's later run
  /// emissions when the synchronous part of its walk delivers it.
  func enqueueDeliveredAction(_ action: R.Action, context: EffectExecutionContext?) {
    var anchor: UUID?
    if let reduction = receivedReduction, reduction.isSynchronous,
      let sequence = reduction.effectSequence, context?.sequence == sequence
    {
      anchor = reduction.emittingRun
    }
    queue.enqueue(action, context: context, aheadOfRun: anchor)
  }

  /// Settles every pending value the sequence of `context` delivered: its
  /// continuation is about to apply a cancellation, so it has moved past them.
  package func settleDeliveries(of context: EffectExecutionContext?) {
    guard let sequence = context?.sequence else { return }
    func settle<Value>(_ entry: ActionQueue<Value>.QueuedAction) {
      guard entry.context?.sequence == sequence, !entry.delivery.isSettled else { return }
      guard entry.isDeliverable else { return }
      entry.delivery.isSettled = true
    }
    queue.forEachPending(settle)
    outputQueue.forEachPending(settle)
  }

  /// Removes the buffered values a cancellation covers when the test applies
  /// it while reducing a received action: they come after that action, which
  /// a `Store` reduced before they were delivered.
  ///
  /// - Parameters:
  ///   - id: The cancelled identifier; `nil` cancels every effect.
  ///   - boundary: The last sequence the cancellation covers.
  ///   - issuer: The sequence that requested the cancellation, if any.
  package func withdrawDeliveries(
    cancelledBy id: AnyEffectID?,
    upTo boundary: UInt64,
    issuedBy issuer: UInt64?
  ) {
    guard let reduction = receivedReduction, reduction.isSynchronous else { return }
    // Once the walk runs, only its own cancellations belong to the reduction.
    if let sequence = reduction.effectSequence, issuer != sequence { return }

    func isCovered<Value>(_ entry: ActionQueue<Value>.QueuedAction) -> Bool {
      guard entry.delivery.order < reduction.startOrder, !entry.delivery.isWithdrawn,
        let scope = entry.context?.cancellationScope, scope.sequence <= boundary
      else { return false }
      return id.map { entry.context?.cancellationIDs.contains($0) == true } ?? true
    }
    func withdraw<Value>(_ entry: ActionQueue<Value>.QueuedAction) -> Bool {
      entry.delivery.isWithdrawn = true
      return true
    }
    // The received action was the oldest buffered one, so every buffered
    // action is behind it; outputs are behind it when delivered after it.
    queue.removeBuffered { isCovered($0) && withdraw($0) }
    outputQueue.removeBuffered {
      $0.delivery.order > reduction.receivedOrder && isCovered($0) && withdraw($0)
    }
  }
}
