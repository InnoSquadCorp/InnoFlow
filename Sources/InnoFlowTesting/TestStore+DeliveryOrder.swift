// MARK: - TestStore+DeliveryOrder.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
package import InnoFlowCore

// A `Store` reduces an effect action, and publishes an output, the moment an
// effect delivers it: an interpreter `.send` is reduced in the interpreter's
// MainActor job, and a run's `await send(action)` returns only after the
// reduction. When the reduction returns an effect other than a plain `.send`
// or `.output`, the `Store` creates a root interpreter task right then, and
// the values the synchronous part of that walk delivers are handled where
// that task runs. MainActor tasks run in the order they are created, so such
// a value is handled where a MainActor task created while the action was
// handled runs.
//
// A test store buffers the values at the same points instead, reduces an
// action when the test receives it, and keeps each buffer in the order in
// which a `Store` handles the values, where every value was handled at its
// delivery:
//
// - Every effect-action delivery, and every `send` whose reduction returns an
//   effect a `Store` interprets, opens an anchor chain and queues its first
//   marker task right away. When a marker runs, it takes the next MainActor
//   event as its position: the place where the `Store` runs the interpreter
//   task of that action.
// - A received or sent action whose effect a `Store` interprets is walked
//   only once its anchor has run. The MainActor jobs queued before the anchor
//   deliver their values first, as they do in a `Store`.
// - A value delivered outside such a walk is handled at its delivery, a new
//   event. A plain `.send` or `.output` that a received action's reduction
//   returns, also under ownership metadata, is drained with the reduction:
//   it shares the action's key and is queued right behind it. A value the
//   synchronous part of a walk delivers is handled at the position of the
//   walk's anchor, in delivery order.
// - A `Store` creates the interpreter task of an interpreted value while the
//   interpreter that delivered it runs. A marker therefore queues the marker
//   of the next level when it runs, while an action of its chain has not
//   finished the synchronous part of its walk, up to
//   `TestStoreAnchorChain.depth` levels; deeper values share the deepest
//   position.
// - Values delivered after the walk first suspends are handled at their
//   delivery.
// - A cancellation applied while the test reduces a received action — its
//   reduction, the reduction-turn acceptance and the synchronous part of its
//   effect walk — removes the covered values a `Store` would have delivered
//   after that action (after its anchor, once the walk runs), except the ones
//   its own walk delivered.
// - A cancellation the test issues itself removes every value it covers, as
//   if it landed first: `cancelEffects(identifiedBy:)`, `cancelAllEffects()`,
//   the cancellation of a dispatch, and the cancellation of all remaining
//   work when a drain times out or `finish()` fails.
//
// No other cancellation removes a delivered value; a `Store` has already
// reduced or published it.

/// Where a `Store` handles a delivered value in the schedule a test store
/// models: at a MainActor event, in delivery order among the values handled
/// at the same event.
package struct TestStoreOrder: Comparable, Sendable {
  /// The MainActor event: the value's own delivery, or the run of the anchor
  /// of the walk that delivered it.
  fileprivate let event: UInt64
  /// The delivery order among the values handled at `event`.
  fileprivate let order: UInt64

  package static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.event, lhs.order) < (rhs.event, rhs.order)
  }
}

/// The MainActor events every test store shares: deliveries and marker runs.
@MainActor
private enum TestStoreEvents {
  private static var last: UInt64 = 0

  static func next() -> UInt64 {
    last &+= 1
    return last
  }
}

/// The anchor markers one test store has queued.
@MainActor
package final class TestStoreAnchorMarkerCount {
  package private(set) var value = 0

  package init() {}

  fileprivate func increment() {
    value += 1
  }
}

/// The interpreter positions of one effect-action delivery or one send: the
/// MainActor jobs in which a `Store` runs the interpreter task of the action,
/// of its interpreted follow-ups, and so on, one level each.
///
/// A level's marker is a MainActor task queued where a `Store` creates the
/// interpreter task of that level: the first at the delivery, every other
/// while the marker before it runs. The chain's members are the actions
/// whose interpreter it anchors; a member settles once the synchronous part
/// of its reduction's walk has finished, or when it leaves the buffer without
/// being reduced. The chain queues no marker once no member is unsettled, and
/// at most ``depth`` markers in all.
@MainActor
package final class TestStoreAnchorChain {
  /// The deepest level that gets a marker of its own; deeper follow-ups
  /// share its position.
  package static let depth = 4

  /// The levels whose marker is queued.
  private var queuedLevels = 0
  /// The positions the markers took, by level.
  private var positions: [UInt64] = []
  private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
  private var unsettledMemberCount = 1
  private let markerCount: TestStoreAnchorMarkerCount?

  /// Opens a chain whose first member is the action being delivered or sent,
  /// and queues its first marker.
  init(markerCount: TestStoreAnchorMarkerCount?) {
    self.markerCount = markerCount
    queueMarker()
  }

  /// The anchor of the chain's first member.
  var first: TestStoreAnchor {
    TestStoreAnchor(chain: self, level: 1)
  }

  fileprivate func addMember() {
    unsettledMemberCount += 1
  }

  fileprivate func settleMember() {
    unsettledMemberCount -= 1
  }

  fileprivate func position(atLevel level: Int) -> UInt64? {
    level <= positions.count ? positions[level - 1] : nil
  }

  /// Returns once the marker of `level` has run. Task cancellation does not
  /// end the wait: the marker is already queued.
  fileprivate func waitForMarker(atLevel level: Int) async {
    guard positions.count < level else { return }
    // The waiting action is an unsettled member, so a marker that is still
    // queued goes on to `level`. Only a chain whose markers have all run
    // needs the next one now.
    if queuedLevels < level, positions.count == queuedLevels {
      queueMarker()
    }
    await withCheckedContinuation { waiters[level, default: []].append($0) }
  }

  private func queueMarker() {
    queuedLevels += 1
    markerCount?.increment()
    let level = queuedLevels
    Task { @MainActor [weak self] in
      self?.markerDidRun(level: level)
    }
  }

  private func markerDidRun(level: Int) {
    positions.append(TestStoreEvents.next())
    // A `Store` creates the next level's interpreter tasks in this job, so
    // they run before anything a resumed walk's caller queues afterwards.
    // Queue the marker before resuming the walks, however soon a resumed
    // continuation reaches the MainActor.
    if unsettledMemberCount > 0, queuedLevels < Self.depth {
      queueMarker()
    }
    for waiter in waiters.removeValue(forKey: level) ?? [] {
      waiter.resume()
    }
  }
}

/// One level of an anchor chain: where a `Store` runs an interpreter task.
@MainActor
package struct TestStoreAnchor {
  package let chain: TestStoreAnchorChain
  /// The level, from 1 through ``TestStoreAnchorChain/depth``.
  package let level: Int

  /// Where a `Store` runs the interpreter task it creates while this one
  /// runs.
  var next: TestStoreAnchor {
    TestStoreAnchor(chain: chain, level: min(level + 1, TestStoreAnchorChain.depth))
  }

  /// The position the marker took, once it has run.
  var position: UInt64? {
    chain.position(atLevel: level)
  }

  func wait() async {
    await chain.waitForMarker(atLevel: level)
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
  /// Where a `Store` runs the interpreter task of this action's reduction;
  /// `nil` for an output.
  package let followUpAnchor: TestStoreAnchor?
  /// A cancellation removed the value before the test received it.
  package var isWithdrawn = false
  private var isSettled = false

  private init(
    storeOrder: (_ order: UInt64) -> TestStoreOrder,
    followUpAnchor: TestStoreAnchor?
  ) {
    Self.lastOrder &+= 1
    order = Self.lastOrder
    self.storeOrder = storeOrder(order)
    self.followUpAnchor = followUpAnchor
  }

  /// A value a `Store` handles at its delivery. An action opens its own
  /// anchor chain, whose markers `markerCount` counts; an output passes
  /// `nil`.
  static func delivered(opening markerCount: TestStoreAnchorMarkerCount?) -> TestStoreDelivery {
    let event = TestStoreEvents.next()
    return .init(
      storeOrder: { TestStoreOrder(event: event, order: $0) },
      followUpAnchor: markerCount.map { TestStoreAnchorChain(markerCount: $0).first })
  }

  /// A value the reduction of `received` returns as a plain `.send` or
  /// `.output`: a `Store` handles it right behind `received`, and creates the
  /// interpreter task of its own reduction there too.
  static func drained(after received: TestStoreDelivery, isAction: Bool) -> TestStoreDelivery {
    let anchor = isAction ? received.followUpAnchor : nil
    anchor?.chain.addMember()
    return .init(storeOrder: { _ in received.storeOrder }, followUpAnchor: anchor)
  }

  /// A value the synchronous part of a walk anchored at `anchor` delivers: a
  /// `Store` handles it where that interpreter runs, and creates the
  /// interpreter task of its own reduction there, one level deeper.
  static func interpreted(
    at anchor: TestStoreAnchor, position: UInt64, isAction: Bool
  ) -> TestStoreDelivery {
    let followUp = isAction ? anchor.next : nil
    followUp?.chain.addMember()
    return .init(
      storeOrder: { TestStoreOrder(event: position, order: $0) }, followUpAnchor: followUp)
  }

  /// The order behind every value a `Store` handles at `position` up to now:
  /// a walk anchored there runs after them.
  static func walkThreshold(at position: UInt64) -> TestStoreOrder {
    TestStoreOrder(event: position, order: lastOrder)
  }

  /// Ends the action's membership of its anchor chain: its reduction's walk
  /// has finished its synchronous part, or it left the buffer unreduced.
  func settle() {
    guard !isSettled, let followUpAnchor else { return }
    isSettled = true
    followUpAnchor.chain.settleMember()
  }
}

/// The reduction of a received or sent action whose effect walk a test store
/// follows, while the synchronous part of that walk lasts.
@MainActor
package final class TestStoreFollowedWalk {
  /// The delivery of the received action; `nil` for a sent action.
  let received: TestStoreDelivery?
  /// The chain a sent action is the member of.
  private let sentChain: TestStoreAnchorChain?
  /// Whether a `Store` drains the effect the reduction returned with the
  /// reduction, instead of creating an interpreter task for it.
  let isDrained: Bool
  /// Where a `Store` runs the interpreter of an effect it does not drain.
  let anchor: TestStoreAnchor?
  /// The order behind which a cancellation applied during the reduction
  /// removes covered values: the received action's own, then the anchor's
  /// once the walk runs.
  var threshold: TestStoreOrder?
  /// The last value the drained effect placed behind the received action;
  /// the next one goes behind it.
  var lastFollowUp: TestStoreDelivery?
  /// The anchor has run and the walk has started.
  var isWalking = false
  /// The walk is still in the MainActor turn in which it started.
  private(set) var isSynchronous = true

  /// Follows the reduction of a received action.
  init(received: TestStoreDelivery, isDrained: Bool) {
    self.received = received
    sentChain = nil
    self.isDrained = isDrained
    anchor = isDrained ? nil : received.followUpAnchor
    threshold = received.storeOrder
  }

  /// Follows the reduction of a sent action whose effect a `Store`
  /// interprets: its interpreter task is created at the reduction.
  init(sentChain: TestStoreAnchorChain) {
    received = nil
    self.sentChain = sentChain
    isDrained = false
    anchor = sentChain.first
  }

  /// The synchronous part of the walk has finished: values delivered from now
  /// on are handled at their delivery, and the action's membership settles.
  func endSynchronousPart() {
    guard isSynchronous else { return }
    isSynchronous = false
    if let received {
      received.settle()
    } else {
      sentChain?.settleMember()
    }
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

    // A cancellation the reduction applies removes covered values behind the
    // received action.
    reducingAction = entry.delivery
    let effect = reduceAction(entry.action, source: source, location: location)
    didReduce(previousState)
    let context = reductionTurnContext(
      for: effect, location: location, flowTaskTracker: entry.context?.flowTaskTracker)
    reducingAction = nil

    switch effect.storeHandling {
    case .nothing:
      entry.delivery.settle()
    case .drained:
      await walkFollowing(
        effect, context: context,
        walk: TestStoreFollowedWalk(received: entry.delivery, isDrained: true))
    case .interpreted:
      await walkFollowing(
        effect, context: context,
        walk: TestStoreFollowedWalk(received: entry.delivery, isDrained: false))
    }
  }

  /// Walks the effect a sent action's reduction returned, with the
  /// cancellation that effect requests already accepted. A `Store` creates
  /// an interpreter task for an effect it does not drain at the reduction;
  /// the walk waits until that task would run.
  package func walkSentEffect(
    _ effect: ReducerEffect<R.Action, R.Output>,
    location: TestStoreSourceLocation,
    flowTaskTracker: FlowTaskTracker?
  ) async {
    let context = reductionTurnContext(
      for: effect, location: location, flowTaskTracker: flowTaskTracker)
    guard effect.storeHandling == .interpreted else {
      // A `Store` handles a drained follow-up of a sent action at its
      // delivery, during the send.
      await walker.walk(effect, context: context, awaited: false)
      return
    }
    let chain = TestStoreAnchorChain(markerCount: queue.anchorMarkerCount)
    await walkFollowing(effect, context: context, walk: TestStoreFollowedWalk(sentChain: chain))
  }

  /// The anchor markers this store has queued, for its deliveries and sends.
  package var queuedAnchorMarkerCount: Int {
    queue.anchorMarkerCount?.value ?? 0
  }

  /// Walks a reduction's effect where a `Store` interprets it: inline when
  /// the `Store` drains it, otherwise once the walk's anchor has run.
  private func walkFollowing(
    _ effect: ReducerEffect<R.Action, R.Output>,
    context: EffectExecutionContext,
    walk: TestStoreFollowedWalk
  ) async {
    let sequence = context.sequence
    if let sequence { followedWalks[sequence] = walk }
    defer {
      walk.endSynchronousPart()
      if let sequence { followedWalks[sequence] = nil }
    }
    // A drained walk delivers its value without suspending.
    if let anchor = walk.anchor {
      await anchor.wait()
      if let position = anchor.position, walk.threshold != nil {
        walk.threshold = TestStoreDelivery.walkThreshold(at: position)
      }
      // MainActor jobs run in the order they are queued: this one runs at
      // the walk's first suspension, before the walk resumes and before any
      // work the walk started, which ends the synchronous part.
      Task { @MainActor [weak walk] in
        walk?.endSynchronousPart()
      }
    }
    walk.isWalking = true
    await walker.walk(effect, context: context, awaited: false)
  }

  /// The walk whose synchronous part is delivering a value of `context`.
  /// Work queued on the MainActor before the walk began can run at its first
  /// suspension; its values belong to other effects.
  private func followedWalk(
    deliveringIn context: EffectExecutionContext?
  ) -> TestStoreFollowedWalk? {
    guard let sequence = context?.sequence, let walk = followedWalks[sequence],
      walk.isWalking, walk.isSynchronous
    else { return nil }
    return walk
  }

  /// Buffers an effect action where a `Store` handles it: right behind the
  /// received action, after the ones its reduction drained before, when the
  /// synchronous part of a drained walk delivers it; at its walk's anchor
  /// when an interpreted walk does; otherwise at its delivery.
  func enqueueDeliveredAction(_ action: R.Action, context: EffectExecutionContext?) {
    guard let walk = followedWalk(deliveringIn: context) else {
      queue.enqueue(action, context: context)
      return
    }
    if walk.isDrained, let received = walk.received {
      walk.lastFollowUp = queue.enqueue(
        action, context: context, delivery: .drained(after: received, isAction: true),
        placement: .front(behind: walk.lastFollowUp))
    } else if let anchor = walk.anchor, let position = anchor.position {
      queue.enqueue(
        action, context: context,
        delivery: .interpreted(at: anchor, position: position, isAction: true),
        placement: .ordered)
    } else {
      queue.enqueue(action, context: context)
    }
  }

  /// Buffers an output where a `Store` publishes it, as for an action.
  func enqueueDeliveredOutput(_ output: R.Output, context: EffectExecutionContext?) {
    guard let walk = followedWalk(deliveringIn: context) else {
      outputQueue.enqueue(output, context: context, tracksActivity: false)
      return
    }
    let delivery: TestStoreDelivery
    if walk.isDrained, let received = walk.received {
      delivery = .drained(after: received, isAction: false)
    } else if let anchor = walk.anchor, let position = anchor.position {
      delivery = .interpreted(at: anchor, position: position, isAction: false)
    } else {
      delivery = .delivered(opening: nil)
    }
    outputQueue.enqueue(
      output, context: context, tracksActivity: false, delivery: delivery, placement: .ordered)
  }

  /// Removes the delivered values a cancellation covers when the test applies
  /// it while reducing a received action: a `Store` reduced that action, or
  /// ran its interpreter, before it delivered them. The values the
  /// reduction's own walk delivered stay, as do the values a `Store` handled
  /// before.
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
    let threshold: TestStoreOrder
    let ownSequence: UInt64?
    if let received = reducingAction {
      threshold = received.storeOrder
      ownSequence = nil
    } else if let issuer, let walk = followedWalks[issuer], walk.isWalking, walk.isSynchronous,
      walk.received != nil, let walkThreshold = walk.threshold
    {
      // Once the walk runs, only its own cancellations belong to the reduction.
      threshold = walkThreshold
      ownSequence = issuer
    } else {
      return
    }

    func isCovered<Value>(_ entry: ActionQueue<Value>.QueuedAction) -> Bool {
      let isOwnDelivery = ownSequence != nil && entry.context?.sequence == ownSequence
      return !isOwnDelivery && entry.isCovered(byCancellationOf: id, upTo: boundary)
    }
    queue.withdraw { entry, _ in entry.delivery.storeOrder > threshold && isCovered(entry) }
    outputQueue.withdraw { entry, _ in entry.delivery.storeOrder > threshold && isCovered(entry) }
  }

  /// Removes every delivered value a cancellation the test issues covers: the
  /// test chooses the `Store` schedule in which that cancellation lands first.
  package func purgeDeliveries(cancelledBy id: AnyEffectID?, upTo boundary: UInt64) {
    queue.withdraw { entry, _ in entry.isCovered(byCancellationOf: id, upTo: boundary) }
    outputQueue.withdraw { entry, _ in entry.isCovered(byCancellationOf: id, upTo: boundary) }
  }
}

/// How a `Store` handles the effect a reduction returns.
private enum TestStoreEffectHandling {
  /// Nothing to interpret.
  case nothing
  /// A plain `.send` or `.output`, also inside ownership metadata, which is
  /// not a scheduling boundary: handled in the queue drain of the reduction.
  case drained
  /// Every other effect: handed to a root interpreter task.
  case interpreted
}

extension ReducerEffect {
  fileprivate var storeHandling: TestStoreEffectHandling {
    switch operation {
    case .none: .nothing
    case .send, .output: .drained
    case .owned(_, let effect): effect.storeHandling
    default: .interpreted
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
