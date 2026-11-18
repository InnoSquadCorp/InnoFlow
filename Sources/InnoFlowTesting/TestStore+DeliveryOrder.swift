// MARK: - TestStore+DeliveryOrder.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
package import InnoFlowCore

// A `Store` reduces an effect action, and publishes an output, the moment an
// effect delivers it: an interpreter `.send` is reduced in the interpreter's
// MainActor turn, and a run's `await send(action)` returns only after the
// reduction. A test store buffers the value at the same points instead and
// reduces an action when the test receives it. The test store models the
// `Store` schedule in which every value was handled at its delivery, and the
// values the synchronous part of a received action's effect walk delivers
// were handled right after that action:
//
// - Those values go to the front of the buffer, right behind the received
//   action, in delivery order. For a bare `.send` this is the only order a
//   `Store` has; for any other effect it is one a `Store` can produce.
//   Outputs stay in the order they are delivered.
// - A cancellation applied while the test reduces a received action — its
//   reduction, the reduction-turn acceptance and the synchronous part of its
//   effect walk — removes the covered values a `Store` would have delivered
//   after that action, except the ones its own walk delivered.
// - A cancellation the test issues itself removes every value it covers, as
//   if it landed first: `cancelEffects(identifiedBy:)`, `cancelAllEffects()`,
//   the cancellation of a dispatch, and the cancellation of all remaining
//   work when a drain times out or `finish()` fails.
//
// No other cancellation removes a delivered value; a `Store` has already
// reduced or published it.

/// The buffered action a test store is reducing, while that reduction lasts.
@MainActor
package final class TestStoreReceivedReduction {
  /// Where a `Store` handles the received action in the modeled schedule.
  let storeOrder: UInt64
  /// The sequence of the effect the reduction returned, once it exists.
  var effectSequence: UInt64?
  /// The last value the walk placed at the front of the buffer; the next one
  /// goes behind it.
  var lastFollowUp: TestStoreDelivery?
  /// Whether the reduction and the walk of its effect are still in the
  /// MainActor turn in which they started.
  var isSynchronous = true

  init(storeOrder: UInt64) {
    self.storeOrder = storeOrder
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

    let reduction = TestStoreReceivedReduction(storeOrder: entry.delivery.storeOrder)
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

  /// The received reduction whose synchronous walk is delivering a value of
  /// `context`. Work queued on the MainActor before the reduction began can
  /// run at the walk's first suspension; its values belong to other effects.
  private func followedReduction(
    deliveringIn context: EffectExecutionContext?
  ) -> TestStoreReceivedReduction? {
    guard let reduction = receivedReduction, reduction.isSynchronous,
      let sequence = reduction.effectSequence, context?.sequence == sequence
    else { return nil }
    return reduction
  }

  /// Buffers an effect action. One the synchronous part of a received
  /// action's walk delivers goes right behind that action, after the ones
  /// that walk delivered before it.
  func enqueueDeliveredAction(_ action: R.Action, context: EffectExecutionContext?) {
    guard let reduction = followedReduction(deliveringIn: context) else {
      queue.enqueue(action, context: context)
      return
    }
    reduction.lastFollowUp = queue.enqueue(
      action, context: context, storeOrder: reduction.storeOrder,
      placement: .front(behind: reduction.lastFollowUp))
  }

  /// Buffers an output in delivery order, recording where a `Store` handles it.
  func enqueueDeliveredOutput(_ output: R.Output, context: EffectExecutionContext?) {
    outputQueue.enqueue(
      output, context: context, tracksActivity: false,
      storeOrder: followedReduction(deliveringIn: context)?.storeOrder)
  }

  /// Removes the delivered values a cancellation covers when the test applies
  /// it while reducing a received action: a `Store` reduced that action
  /// before it delivered them. The values the reduction's own walk delivered
  /// stay, as do the outputs a `Store` published before the action.
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
      let isOwnDelivery =
        reduction.effectSequence != nil && entry.context?.sequence == reduction.effectSequence
      return !isOwnDelivery && entry.isCovered(byCancellationOf: id, upTo: boundary)
    }
    // A buffered action is behind the received one, which was the oldest; a
    // value handed to a waiter, and an output, may be ahead of it.
    queue.withdraw { entry, isBuffered in
      (isBuffered || entry.delivery.storeOrder > reduction.storeOrder) && isCovered(entry)
    }
    outputQueue.withdraw { entry, _ in
      entry.delivery.storeOrder > reduction.storeOrder && isCovered(entry)
    }
  }

  /// Removes every delivered value a cancellation the test issues covers: the
  /// test chooses the `Store` schedule in which that cancellation lands first.
  package func purgeDeliveries(cancelledBy id: AnyEffectID?, upTo boundary: UInt64) {
    queue.withdraw { entry, _ in entry.isCovered(byCancellationOf: id, upTo: boundary) }
    outputQueue.withdraw { entry, _ in entry.isCovered(byCancellationOf: id, upTo: boundary) }
  }
}

// MARK: - Receiving

extension TestStore {
  package func popBufferedQueuedAction() -> ActionQueue<R.Action>.QueuedAction? {
    while let entry = queue.popBuffered() {
      guard entry.isDeliverable else {
        entry.finish()
        continue
      }
      return entry
    }
    return nil
  }

  package func popBufferedAction() async -> R.Action? {
    guard let entry = popBufferedQueuedAction() else { return nil }
    defer { entry.finish() }
    return entry.action
  }

  package func discardInvalidatedActions() {
    queue.removeBuffered { !$0.isDeliverable }
    outputQueue.removeBuffered { !$0.isDeliverable }
    finishActivity.noteProgress()
  }
}
