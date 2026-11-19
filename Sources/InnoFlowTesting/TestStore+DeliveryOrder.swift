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
// handled runs, unless the interpreter task created before it has not
// finished — it suspended, as a throttle reading its clock or a scheduled
// run waiting for admission does, or it still waits for the one before it —
// which the task awaits before it walks.
//
// A test store buffers the values at the same points instead, reduces an
// action when the test receives it, and keeps each buffer in the order in
// which a `Store` handles the values, where every value was handled at its
// delivery:
//
// - Every effect-action delivery outside the synchronous part of a walk the
//   test store follows, and every `send`, opens an anchor chain and queues
//   its first marker task right away. When a marker runs, it takes the next
//   MainActor event as its position: the place where the `Store` runs the
//   interpreter task of that action.
// - A received or sent action whose effect a `Store` interprets is walked
//   only once its anchor has run. The MainActor jobs queued before the anchor
//   deliver their values first, as they do in a `Store`.
// - A `Store` starts a root interpreter walk only once the one it created
//   before has finished. The test store walks interpreted effects in that
//   order, and records where each walk finished: a walk whose predecessor
//   finished only after its anchor ran starts at the next level after that
//   point, the earliest point at which a `Store` starts it, short of the
//   two limitations below. The predecessor's completion resumes a `Store`'s
//   walk through the global executor, which can land behind later jobs,
//   depending on how soon it hands the walk back relative to the MainActor's
//   other jobs.
// - A `send` takes its place, and queues its anchor, when it begins: a
//   `Store` reduces the sent action, and creates its interpreter task, in
//   the MainActor job in which the send begins. The send first reduces the
//   buffered values a `Store` handled before that place, then the sent
//   action, whose plain follow-ups share the place, and only then walks, in
//   order, the drained actions' effects whose walks had not started when the
//   send began and every interpreted one behind them, also when the drain
//   suspends. Every value delivered from the send on stays buffered, behind
//   the sent action.
// - A value delivered outside such a walk is handled at its delivery, a new
//   event. A plain `.send` or `.output` that a received action's reduction
//   returns, also under ownership metadata, is drained with the reduction:
//   it shares the action's key and is queued right behind it. A value the
//   synchronous part of a walk delivers is handled where the walk starts, in
//   delivery order.
// - A `Store` creates the interpreter task of an interpreted value while the
//   interpreter that delivered it runs. A marker therefore queues the marker
//   of the next level when it runs, while an action of its chain has not
//   finished its walk or the last walk the test store followed finished on
//   the chain, up to `TestStoreAnchorChain.depth` levels; deeper positions,
//   a walk's start or resumption among them, share the deepest one, a known
//   limitation: what is placed there can come before jobs a `Store` runs
//   first.
// - The test store follows a walk until it returns. A `Store` resumes a walk
//   that suspends — after a clock read or an admission — behind every
//   MainActor job queued before it started, at the earliest where the next
//   level after its start runs, which the test store takes for what the
//   walk delivers from then on, short of the depth limit above. A walk that
//   suspends more than once is placed as if it resumed once, and the walks
//   behind it start right behind that place, a known limitation: both can
//   come before jobs a `Store` runs first. What
//   work a walk started in another task delivers — a run, a composite and
//   its children, a timer — is handled at its delivery, a known limitation:
//   a `Store` starts that work while the walk runs, and can handle its first
//   values before MainActor jobs placed ahead of them here.
// - A cancellation applied while the test reduces a received or sent action
//   — its reduction, the reduction-turn acceptance and the synchronous part
//   of its effect walk — removes the covered values a `Store` would have
//   delivered after that action (after where its walk delivers, once it
//   runs), except the ones its own walk delivered. For a sent action, those are the
//   values delivered from the send on, such as those of a job queued before
//   the send, or of work a drained action started in another task.
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

  /// The place of an action the test sends now, which a `Store` reduces in
  /// the current MainActor job: behind every value delivered or anchored
  /// before, ahead of every value delivered or anchored from now on.
  @MainActor
  fileprivate static func now() -> Self {
    Self(event: TestStoreEvents.next(), order: 0)
  }
}

/// What a send prepares before it reduces the sent action. A `Store` reduces
/// the sent action, and creates its interpreter task, in the MainActor job
/// in which the send begins, so the send takes its place, and opens its
/// anchor chain, when it begins, however long the drain before it lasts.
@MainActor
package struct TestStorePreparedSend {
  /// The place of the send: the plain follow-ups of the sent action share
  /// it, and its anchor is where a `Store` runs the sent action's interpreter.
  fileprivate let delivery: TestStoreDelivery
  /// The effect walks of the buffered actions the send drained that a
  /// `Store` starts after it reduces the sent action: they had not started
  /// when the send began.
  fileprivate var deferredWalks: [@MainActor () async -> Void] = []

  /// Takes the place of a send that begins now.
  init(markerCount: TestStoreAnchorMarkerCount?) {
    delivery = .sent(at: .now(), opening: markerCount)
  }

  /// The place of the send: every value a `Store` handled before the send is
  /// ordered before it.
  var order: TestStoreOrder { delivery.storeOrder }

  /// Runs the deferred walks in order, each once it starts.
  fileprivate func runDeferredWalks() async {
    for walk in deferredWalks {
      await walk()
    }
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
/// being reduced. The test store is a member too while the chain holds its
/// interpreter tail: the test store starts a root walk that waited for the
/// tail's walk at the chain's level after the tail, and resumes it at the
/// level after that, however late the test receives the walk's action. The
/// chain queues no marker once no member is unsettled, and at most ``depth``
/// markers in all.
@MainActor
package final class TestStoreAnchorChain {
  /// The deepest level that gets a marker of its own; deeper positions — a
  /// follow-up's, or a walk's start or resumption — share its position.
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

  func addMember() {
    unsettledMemberCount += 1
  }

  func settleMember() {
    unsettledMemberCount -= 1
  }

  fileprivate func position(atLevel level: Int) -> UInt64? {
    level <= positions.count ? positions[level - 1] : nil
  }

  /// Returns once the marker of `level` has run. Task cancellation does not
  /// end the wait: the marker is already queued.
  fileprivate func waitForMarker(atLevel level: Int) async {
    guard positions.count < level else { return }
    // The waiting action, or the interpreter tail the chain holds, is an
    // unsettled member, so a marker that is still queued goes on to `level`.
    // Only a chain whose markers have all run needs the next one now.
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
  /// runs. The deepest level stands for every deeper one.
  var next: TestStoreAnchor {
    TestStoreAnchor(chain: chain, level: min(level + 1, TestStoreAnchorChain.depth))
  }

  /// The position the marker took, once it has run.
  var position: UInt64? {
    chain.position(atLevel: level)
  }

  /// Whether the marker ran before `order`'s event.
  func ran(before order: TestStoreOrder) -> Bool {
    position.map { $0 < order.event } ?? false
  }

  /// Where the test store starts the walk of the interpreter task anchored
  /// here, once this marker has run, when the walk before it finished at
  /// `predecessor`: here, unless that walk finished at or after the point
  /// where this anchor ran; then at its next level, a job queued right after
  /// it finished.
  /// Short of the two limitations in this file's header — a walk that
  /// suspends more than once, and ``TestStoreAnchorChain/depth`` — that is
  /// the earliest job in which a `Store` starts the walk.
  func start(after predecessor: TestStoreAnchor?) -> TestStoreAnchor {
    guard let predecessor, let finished = predecessor.position, let own = position,
      finished >= own
    else { return self }
    return predecessor.next
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

  /// The place of an action the test sends at `order`, which opens its own
  /// anchor chain: a `Store` reduces it, and creates its interpreter task,
  /// in the MainActor job in which the send begins.
  static func sent(
    at order: TestStoreOrder, opening markerCount: TestStoreAnchorMarkerCount?
  ) -> TestStoreDelivery {
    .init(
      storeOrder: { _ in order },
      followUpAnchor: TestStoreAnchorChain(markerCount: markerCount).first)
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
/// follows, until that walk returns.
@MainActor
package final class TestStoreFollowedWalk {
  /// Where a `Store` handles the action: the delivery of the received
  /// action, or the place of the send.
  let handled: TestStoreDelivery
  /// Whether a `Store` drains the effect the reduction returned with the
  /// reduction, instead of creating an interpreter task for it.
  let isDrained: Bool
  /// Where a `Store` first runs the interpreter task of an effect it does not
  /// drain.
  let anchor: TestStoreAnchor?
  /// Where the test store starts the walk: the anchor, or the next level
  /// after the walk created before it finished
  /// (``TestStoreAnchor/start(after:)``).
  private(set) var startAnchor: TestStoreAnchor?
  /// Where the walk delivers once it has suspended: the next level after its
  /// start (``TestStoreAnchor/next``). Short of the two limitations in this
  /// file's header, that is behind every MainActor job queued before the
  /// walk started, where a `Store` resumes the walk at the earliest.
  private(set) var resumedAnchor: TestStoreAnchor?
  /// The order behind which a cancellation applied during the reduction
  /// removes covered values: where `handled` is, then the position where the
  /// walk delivers.
  var threshold: TestStoreOrder
  /// The last value the drained effect placed behind the action; the next
  /// one goes behind it.
  var lastFollowUp: TestStoreDelivery?
  /// The walk has started.
  var isWalking = false
  /// The test store still follows the walk: it has not returned.
  private(set) var isSynchronous = true

  /// Follows the reduction of an action a `Store` handles at `handled`.
  init(handled: TestStoreDelivery, isDrained: Bool) {
    self.handled = handled
    self.isDrained = isDrained
    anchor = isDrained ? nil : handled.followUpAnchor
    startAnchor = anchor
    threshold = handled.storeOrder
  }

  /// Where the test store places what the walk delivers now:
  /// ``resumedAnchor`` once it has suspended, ``startAnchor`` before.
  var deliveryAnchor: TestStoreAnchor? {
    resumedAnchor ?? startAnchor
  }

  /// The walk will start at `start`: its anchor, or, when it waits for its
  /// predecessor, a level of the chain that holds the interpreter tail, which
  /// keeps queueing levels while it does.
  func prepare(toStartAt start: TestStoreAnchor) {
    startAnchor = start
  }

  /// The start's marker has run: the walk delivers there.
  func begin() {
    if let position = startAnchor?.position {
      threshold = TestStoreDelivery.walkThreshold(at: position)
    }
  }

  /// The walk has reached its first suspension: from now on it delivers at
  /// ``resumedAnchor``, the next level after its start. That marker was
  /// queued when the start's ran, before the walk began, so it has run: the
  /// start's chain had an unsettled member then — the walk's own action, the
  /// action of the walk before it, or the test store while the chain held
  /// the interpreter tail. Only walks running concurrently on one store can
  /// find it missing; the walk then keeps delivering at its start.
  func didReachFirstSuspension() {
    guard isSynchronous, resumedAnchor == nil, let next = startAnchor?.next,
      let position = next.position
    else { return }
    resumedAnchor = next
    threshold = TestStoreDelivery.walkThreshold(at: position)
  }

  /// The walk has returned: values delivered from now on are handled at their
  /// delivery, and the action's membership settles.
  func endSynchronousPart() {
    guard isSynchronous else { return }
    isSynchronous = false
    handled.settle()
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
    guard
      let reduction = reduceAndAccept(
        entry, source: source, location: location, willReduce: willReduce, didReduce: didReduce)
    else { return }
    await walkReceivedEffect(reduction.effect, context: reduction.context, of: entry)
  }

  /// Reduces a buffered action that a send drains before it reduces the sent
  /// action. A `Store` reduced that action at its delivery, but runs the
  /// interpreter task it created then after the sent action when that task
  /// had not run when the send began: such a walk is deferred in `prepared`
  /// instead, still anchored where that task runs, and keeps the action's
  /// activity lease.
  package func reduceBufferedActionBeforeSend(
    _ entry: ActionQueue<R.Action>.QueuedAction,
    location: TestStoreSourceLocation,
    preparing prepared: inout TestStorePreparedSend
  ) async {
    guard
      let reduction = reduceAndAccept(
        entry, source: .automatic, location: location, willReduce: { _ in }, didReduce: { _ in })
    else {
      entry.finish()
      return
    }
    // A marker that runs while the drain is suspended still runs after the
    // send began. A `Store` starts the walk once the walk created before it
    // has finished, so a walk behind a deferred one is deferred too.
    if reduction.effect.storeHandling == .interpreted,
      !prepared.deferredWalks.isEmpty
        || entry.delivery.followUpAnchor.map({ anchor in
          anchor.ran(before: prepared.order)
            && anchor.start(after: interpreterTail).ran(before: prepared.order)
        }) != true
    {
      prepared.deferredWalks.append { [self] in
        defer { entry.finish() }
        await walkReceivedEffect(reduction.effect, context: reduction.context, of: entry)
      }
      return
    }
    defer { entry.finish() }
    await walkReceivedEffect(reduction.effect, context: reduction.context, of: entry)
  }

  /// Reduces a deliverable buffered action and runs the reduction-turn
  /// acceptance of its effect; `nil` when the action is no longer
  /// deliverable.
  private func reduceAndAccept(
    _ entry: ActionQueue<R.Action>.QueuedAction,
    source: TestStoreReductionSource,
    location: TestStoreSourceLocation,
    willReduce: (R.State) -> Void,
    didReduce: (R.State) -> Void
  ) -> (effect: ReducerEffect<R.Action, R.Output>, context: EffectExecutionContext)? {
    guard entry.isDeliverable else { return nil }
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
    return (effect, context)
  }

  private func walkReceivedEffect(
    _ effect: ReducerEffect<R.Action, R.Output>,
    context: EffectExecutionContext,
    of entry: ActionQueue<R.Action>.QueuedAction
  ) async {
    switch effect.storeHandling {
    case .nothing:
      entry.delivery.settle()
    case .drained:
      await walkFollowing(
        effect, context: context,
        walk: TestStoreFollowedWalk(handled: entry.delivery, isDrained: true))
    case .interpreted:
      await walkFollowing(
        effect, context: context,
        walk: TestStoreFollowedWalk(handled: entry.delivery, isDrained: false))
    }
  }

  /// Reduces an action the test sends, with `reduce`, at the place
  /// `prepared` took when the send began, and runs the reduction-turn
  /// acceptance of its effect. A `Store` does both in the MainActor job in
  /// which the send begins, before any job a suspended drain let run: a
  /// cancellation applied in either — the closing of an optional child's
  /// lifetime, or one the effect requests — removes the covered values
  /// delivered from the send on.
  package func reduceSentAction(
    at prepared: TestStorePreparedSend,
    location: TestStoreSourceLocation,
    flowTaskTracker: FlowTaskTracker?,
    _ reduce: () -> ReducerEffect<R.Action, R.Output>
  ) -> (effect: ReducerEffect<R.Action, R.Output>, context: EffectExecutionContext) {
    reducingAction = prepared.delivery
    defer { reducingAction = nil }
    let effect = reduce()
    let context = reductionTurnContext(
      for: effect, location: location, flowTaskTracker: flowTaskTracker)
    return (effect, context)
  }

  /// Walks the effect a sent action's reduction returned, with the
  /// cancellation that effect requests already accepted, at the place of the
  /// send: a `Store` drains a plain `.send` or `.output` with the send, and
  /// runs an interpreter task for any other effect where the send's anchor
  /// runs.
  ///
  /// - Parameter prepared: The place of the send, taken when it began, and
  ///   the walks of the buffered actions it drained whose interpreter tasks a
  ///   `Store` runs after the sent action's reduction, ahead of the sent
  ///   action's own.
  package func walkSentEffect(
    _ effect: ReducerEffect<R.Action, R.Output>,
    context: EffectExecutionContext,
    prepared: TestStorePreparedSend
  ) async {
    switch effect.storeHandling {
    case .nothing:
      prepared.delivery.settle()
      await prepared.runDeferredWalks()
    case .drained:
      // Before any interpreter task runs, and before any job a suspended
      // drain let run.
      await walkFollowing(
        effect, context: context,
        walk: TestStoreFollowedWalk(handled: prepared.delivery, isDrained: true))
      await prepared.runDeferredWalks()
    case .interpreted:
      await prepared.runDeferredWalks()
      await walkFollowing(
        effect, context: context,
        walk: TestStoreFollowedWalk(handled: prepared.delivery, isDrained: false))
    }
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
    guard let anchor = walk.anchor else {
      walk.isWalking = true
      return await walker.walk(effect, context: context, awaited: false)
    }
    await anchor.wait()
    // A `Store` starts the walk once the walk it created before has finished.
    let start = anchor.start(after: interpreterTail)
    walk.prepare(toStartAt: start)
    await start.wait()
    walk.begin()
    // MainActor jobs run in the order they are queued: this one runs at the
    // walk's first suspension, before the walk resumes and before any work
    // the walk started.
    Task { @MainActor [weak walk] in
      walk?.didReachFirstSuspension()
    }
    walk.isWalking = true
    await walker.walk(effect, context: context, awaited: false)
    interpreterTail = walk.deliveryAnchor
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
    if walk.isDrained {
      walk.lastFollowUp = queue.enqueue(
        action, context: context, delivery: .drained(after: walk.handled, isAction: true),
        placement: .front(behind: walk.lastFollowUp))
    } else if let anchor = walk.deliveryAnchor, let position = anchor.position {
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
    if walk.isDrained {
      delivery = .drained(after: walk.handled, isAction: false)
    } else if let anchor = walk.deliveryAnchor, let position = anchor.position {
      delivery = .interpreted(at: anchor, position: position, isAction: false)
    } else {
      delivery = .delivered(opening: nil)
    }
    outputQueue.enqueue(
      output, context: context, tracksActivity: false, delivery: delivery, placement: .ordered)
  }

  /// Removes the delivered values a cancellation covers when the test applies
  /// it while reducing a received or sent action: a `Store` reduced that
  /// action, or ran its interpreter, before it delivered them. The values the
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
    if let reducing = reducingAction {
      threshold = reducing.storeOrder
      ownSequence = nil
    } else if let issuer, let walk = followedWalks[issuer], walk.isWalking, walk.isSynchronous {
      // Once the walk runs, only its own cancellations belong to the reduction.
      threshold = walk.threshold
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
    popBufferedQueuedAction(handledBefore: nil)
  }

  /// Pops the next deliverable buffered action a `Store` handles before
  /// `limit`, or `nil` when the next one is handled after it.
  package func popBufferedQueuedAction(
    before limit: TestStoreOrder
  ) -> ActionQueue<R.Action>.QueuedAction? {
    popBufferedQueuedAction(handledBefore: limit)
  }

  private func popBufferedQueuedAction(
    handledBefore limit: TestStoreOrder?
  ) -> ActionQueue<R.Action>.QueuedAction? {
    while let entry = queue.popBuffered(if: { entry in
      limit.map { entry.delivery.storeOrder < $0 } ?? true
    }) {
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
