// MARK: - TestStore+DeliveryOrder.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
package import InnoFlowCore

// A `Store` reduces an effect action, and publishes an output, the moment an
// effect delivers it: an interpreter `.send` is reduced in the interpreter's
// MainActor job, and a run's `await send(action)` returns only after the
// reduction. A test store buffers the value at the same points instead,
// reduces an action when the test receives it, and keeps each buffer in the
// order in which a `Store` handles the values in the schedule it models,
// where every value was handled at its delivery:
//
// - A test store's deliveries form turns: the ones it records before a
//   MainActor job, queued at the turn's first delivery, runs. A `Store`
//   handles them in the jobs that deliver them.
// - A `Store` drains the effect a received action's reduction returns with
//   the reduction when it is a plain `.send` or `.output`, also under
//   ownership metadata: its value is handled right behind the action, in
//   delivery order, at every depth.
// - A `Store` hands any other effect to an interpreter job it queues while it
//   handles the action: after the jobs that deliver the rest of the action's
//   turn and before those of every later turn, such as a run's next emission
//   or the step of a `concatenate` after a run. The values the synchronous
//   part of the walk delivers are handled at the end of the turn of the
//   action, or of the first action of its plain chain, in delivery order;
//   the interpreter job of their own reduction ends one turn later.
// - Values delivered after the walk first suspends are handled at their
//   delivery.
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

/// Where a `Store` handles a delivered value in the schedule a test store
/// models.
///
/// Values handled at their delivery are ordered by delivery. A value an
/// interpreter delivers is handled at the end of a turn: after every value
/// delivered in that turn, before every value delivered in a later one, and
/// in delivery order among the values handled at the end of the same turn.
package struct TestStoreOrder: Comparable, Sendable {
  /// Twice the delivery turn; one more at the end of that turn.
  fileprivate let slot: UInt64
  /// The delivery order within the slot.
  fileprivate let order: UInt64

  package static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.slot, lhs.order) < (rhs.slot, rhs.order)
  }
}

/// The MainActor delivery batches every test store shares: the values
/// delivered before a MainActor job, queued at a batch's first delivery,
/// runs. They are the values of the job that opened the batch and of the jobs
/// queued before that job, which a `Store` handles before an interpreter job
/// it queues while it handles one of them.
@MainActor
private enum TestStoreDeliveryBatch {
  private static var last: UInt64 = 0
  private static var isOpen = false

  /// The batch a value delivered now belongs to.
  static func current() -> UInt64 {
    guard !isOpen else { return last }
    last &+= 1
    isOpen = true
    let batch = last
    Task { @MainActor in
      if batch == last { isOpen = false }
    }
    return batch
  }
}

/// The delivery turns of one test store: its deliveries in one delivery
/// batch. A `Store` handles the values of a turn before an interpreter job it
/// queues while it handles one of them, and the values of every later turn of
/// the same store after it.
@MainActor
package final class TestStoreDeliveryTurns {
  private var batch: UInt64 = 0
  private var isEnded = false
  /// The latest turn.
  private(set) var last: UInt64 = 0

  package init() {}

  /// The turn a value the store delivers now belongs to.
  func current() -> UInt64 {
    let batch = TestStoreDeliveryBatch.current()
    if batch != self.batch || isEnded {
      self.batch = batch
      isEnded = false
      last &+= 1
    }
    return last
  }

  /// The turn, at most `turn`, at whose end a value an interpreter delivers
  /// now is handled. Every value the store delivers from now on belongs to a
  /// later turn.
  func ending(atMost turn: UInt64) -> UInt64 {
    let ending = min(turn, last)
    if ending == last { isEnded = true }
    return ending
  }
}

/// What a test store knows about one delivered effect action or output.
///
/// A `Store` reduces an effect action, and publishes an output, the moment an
/// effect delivers it. A test store buffers the value until the test receives
/// it; this record places the value in the `Store` schedule the test store
/// models, so the buffer keeps the order in which a `Store` handles values,
/// and a cancellation applied in between can tell whether a `Store` would
/// have handled the value before that cancellation.
@MainActor
package final class TestStoreDelivery {
  private static var lastOrder: UInt64 = 0

  /// The order every buffered action and output of every test store shares.
  package let order: UInt64
  /// Where a `Store` handles the value in the modeled schedule.
  package let storeOrder: TestStoreOrder
  /// The turn at whose end a `Store` handles the values an interpreter
  /// delivers for the reduction of this action.
  let interpreterTurn: UInt64
  /// A cancellation removed the value before the test received it.
  package var isWithdrawn = false

  private init(storeOrder: (_ order: UInt64) -> TestStoreOrder, interpreterTurn: UInt64) {
    Self.lastOrder &+= 1
    order = Self.lastOrder
    self.storeOrder = storeOrder(order)
    self.interpreterTurn = interpreterTurn
  }

  /// A value a `Store` handles at its delivery.
  static func delivered(in turns: TestStoreDeliveryTurns) -> TestStoreDelivery {
    let turn = turns.current()
    return .init(storeOrder: { TestStoreOrder(slot: 2 * turn, order: $0) }, interpreterTurn: turn)
  }

  /// A value the reduction of `received` delivers in its queue drain: a
  /// `Store` handles it right behind `received`.
  static func drained(after received: TestStoreDelivery) -> TestStoreDelivery {
    .init(storeOrder: { _ in received.storeOrder }, interpreterTurn: received.interpreterTurn)
  }

  /// A value the interpreter of `received`'s reduction delivers: a `Store`
  /// handles it at the end of `received`'s interpreter turn, and interprets
  /// the effect of its own reduction one turn later.
  static func interpreted(
    after received: TestStoreDelivery, in turns: TestStoreDeliveryTurns
  ) -> TestStoreDelivery {
    let turn = turns.ending(atMost: received.interpreterTurn)
    return .init(
      storeOrder: { TestStoreOrder(slot: 2 * turn + 1, order: $0) }, interpreterTurn: turn + 1)
  }
}

/// The buffered action a test store is reducing, while that reduction lasts.
@MainActor
package final class TestStoreReceivedReduction {
  /// The delivery of the received action.
  let received: TestStoreDelivery
  /// Whether a `Store` drains the effect the reduction returned with the
  /// reduction, instead of queueing an interpreter job for it.
  var isDrained = false
  /// The sequence of the effect the reduction returned, once it exists.
  var effectSequence: UInt64?
  /// The last value the drained effect placed behind the received action;
  /// the next one goes behind it.
  var lastFollowUp: TestStoreDelivery?
  /// Whether the reduction and the walk of its effect are still in the
  /// MainActor turn in which they started.
  var isSynchronous = true

  /// Where a `Store` handles the received action in the modeled schedule.
  var storeOrder: TestStoreOrder { received.storeOrder }

  init(received: TestStoreDelivery) {
    self.received = received
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

    let reduction = TestStoreReceivedReduction(received: entry.delivery)
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
    reduction.isDrained = effect.isDrainedWithReduction
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

  /// Buffers an effect action where a `Store` handles it. One the
  /// synchronous part of a received action's walk delivers goes right behind
  /// that action, after the ones it delivered before, when a `Store` drains
  /// the effect with the reduction; otherwise at the end of the received
  /// action's interpreter turn.
  func enqueueDeliveredAction(_ action: R.Action, context: EffectExecutionContext?) {
    guard let reduction = followedReduction(deliveringIn: context) else {
      queue.enqueue(action, context: context)
      return
    }
    guard reduction.isDrained else {
      queue.enqueue(
        action, context: context,
        delivery: .interpreted(after: reduction.received, in: queue.turns), placement: .ordered)
      return
    }
    reduction.lastFollowUp = queue.enqueue(
      action, context: context, delivery: .drained(after: reduction.received),
      placement: .front(behind: reduction.lastFollowUp))
  }

  /// Buffers an output where a `Store` publishes it, as for an action.
  func enqueueDeliveredOutput(_ output: R.Output, context: EffectExecutionContext?) {
    guard let reduction = followedReduction(deliveringIn: context) else {
      outputQueue.enqueue(output, context: context, tracksActivity: false)
      return
    }
    let delivery: TestStoreDelivery =
      reduction.isDrained
      ? .drained(after: reduction.received)
      : .interpreted(after: reduction.received, in: outputQueue.turns)
    outputQueue.enqueue(
      output, context: context, tracksActivity: false, delivery: delivery, placement: .ordered)
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

extension ReducerEffect {
  /// Whether a `Store` handles this effect in the queue drain of the
  /// reduction that returned it: a plain `.send` or `.output`, also inside
  /// ownership metadata, which is not a scheduling boundary. A `Store` hands
  /// every other effect to a root interpreter task.
  fileprivate var isDrainedWithReduction: Bool {
    switch operation {
    case .send, .output: true
    case .owned(_, let effect): effect.isDrainedWithReduction
    default: false
    }
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
