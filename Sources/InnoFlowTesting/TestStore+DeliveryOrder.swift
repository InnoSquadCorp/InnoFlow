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
// that task runs. MainActor tasks start in the order they are created, so
// such a value is handled where a MainActor task created while the action
// was handled runs, unless the interpreter task created before it has not
// finished — it suspended, as a throttle reading its clock or a scheduled
// run waiting for admission does, or it still waits for the one before it —
// which the task awaits before it walks.
//
// A test store buffers the values at the same points instead, reduces an
// action when the test receives it, and keeps each buffer in the order in
// which a `Store` handles the values, where every value was handled at its
// delivery:
//
// - Every effect-action delivery outside a walk the test store follows, and
//   every `send`, opens an anchor chain and queues its first marker task
//   right away. When a marker runs, it takes the next MainActor event as its
//   position: the place where the `Store` runs the interpreter task of that
//   action. Each marker queues the next level's while the chain has a member
//   that can still need it, so level `n` stands for the MainActor jobs a
//   `Store` runs `n - 1` jobs behind that interpreter task, each queued while
//   the one before it runs. Among the values handled at one level, the order
//   of the jobs that deliver them decides: a job queued by an earlier job, or
//   earlier by the same job, runs first (`TestStoreRank`).
// - A received or sent action whose effect a `Store` interprets is walked
//   only once its anchor has run. The MainActor jobs queued before the anchor
//   deliver their values first, as they do in a `Store`.
// - A `Store` starts a root interpreter walk only once the one it created
//   before has finished. The test store walks interpreted effects in that
//   order, and records where each walk finished: a walk whose predecessor
//   had not finished when its anchor ran starts at the next level after the
//   point where the predecessor finished, behind everything the
//   predecessor's last job created: the earliest point at which a `Store`
//   starts it, short of the depth limit below. The predecessor's completion
//   resumes a `Store`'s walk through the global executor, which can land
//   behind later jobs, depending on how soon it hands the walk back relative
//   to the MainActor's other jobs.
// - A `send` takes its place, and queues its anchor, when it begins: a
//   `Store` reduces the sent action, and creates its interpreter task, in
//   the MainActor job in which the send begins. The send first reduces the
//   buffered values a `Store` handled before that place, then the sent
//   action, whose plain follow-ups share the place, and only then walks, in
//   order, the drained actions' effects whose walks had not started when the
//   send began and every interpreted one behind them, also when the drain
//   suspends. Every value delivered from the send on stays buffered, behind
//   the sent action.
// - A value delivered outside a followed walk is handled at its delivery, a
//   new event. A plain `.send` or `.output` that a received action's
//   reduction returns, also under ownership metadata, is drained with the
//   reduction: it shares the action's key and is queued right behind it. A
//   value a followed walk delivers is handled where that walk runs, in
//   delivery order.
// - A `Store` creates the interpreter task of an interpreted value while the
//   interpreter that delivered it runs: at the next level. Levels past
//   `TestStoreAnchorChain.depth` share the deepest one, a known limitation:
//   what is placed there can come before jobs a `Store` runs first.
// - The test store follows a walk until it returns. A `Store` resumes a walk
//   that suspends — after a clock read or an admission — behind every
//   MainActor job queued before it suspended, at the earliest where the next
//   level runs, behind everything the job it suspended in created; the test
//   store places what the walk delivers from then on there, one level deeper
//   for each suspension.
// - A `Store` walks the children of an unawaited `concatenate` in a MainActor
//   task it creates while the walk that starts it runs, and each child of an
//   unawaited `merge` once a task group has handed it to the MainActor, two
//   levels deeper at the earliest — an optimized build walks it there, a
//   debug build a job later; the children of a `merge` race each other, and
//   the test store starts them in declaration order. The test store
//   follows such a task's walk until it returns or awaits other work, as
//   above, and takes nothing from a buffer until every one it follows has.
//   What work delivers that a walk started and awaits or leaves to run in
//   another task — a run, a timer, the children of an awaited `merge` — and
//   what a composite task delivers once it awaited such work, is handled at
//   its delivery, a known limitation since 6.0.x: a `Store` can handle those
//   values before MainActor jobs placed ahead of them here.
// - A cancellation applied while the test reduces a received or sent action
//   — its reduction, the reduction-turn acceptance and a followed walk of its
//   effect — removes the covered values a `Store` would have delivered after
//   that action (after where the walk delivers, once it runs), except the
//   ones its own effect delivered. For a sent action, those are the values
//   delivered from the send on, such as those of a job queued before the
//   send, or of work a drained action started in another task.
// - A cancellation the test issues itself removes every value it covers, as
//   if it landed first: `cancelEffects(identifiedBy:)`, `cancelAllEffects()`,
//   the cancellation of a dispatch, and the cancellation of all remaining
//   work when a drain times out or `finish()` fails.
//
// No other cancellation removes a delivered value; a `Store` has already
// reduced or published it.

/// Where a `Store` handles a delivered value in the schedule a test store
/// models: at a MainActor event, and, among the values handled where one
/// anchor marker ran, in the order in which a `Store` runs the jobs that
/// deliver them.
package struct TestStoreOrder: Comparable, Sendable {
  /// The MainActor event: the value's own delivery, or the run of the anchor
  /// marker of the walk that delivered it.
  fileprivate let event: UInt64
  /// The place of the value among the ones handled at `event`; the origin
  /// for a value handled at its own delivery.
  fileprivate let rank: TestStoreRank
  /// The delivery order, for values no rank tells apart.
  fileprivate let order: UInt64

  package static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.event != rhs.event { return lhs.event < rhs.event }
    if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
    return lhs.order < rhs.order
  }

  /// The place of an action the test sends now, which a `Store` reduces in
  /// the current MainActor job: behind every value delivered or anchored
  /// before, ahead of every value delivered or anchored from now on.
  @MainActor
  fileprivate static func now() -> Self {
    Self(event: TestStoreEvents.next(), rank: .origin, order: 0)
  }
}

/// The order in which a `Store` runs the MainActor jobs that share one anchor
/// level, and handles the values they deliver: a path of indices.
///
/// MainActor jobs run in the order they are queued, so the jobs of one level
/// run in the order of the jobs that queued them, and the jobs one job queued
/// in the order in which it queued them. What a walk creates — a value it
/// delivers, with the interpreter task of an action, or the task of a
/// composite — takes the walk's rank followed by its index among what the
/// walk creates before it next suspends. A walk that resumes, and a walk that
/// starts once the one before it has finished, are queued when the job
/// before them ends, at the earliest: they take that job's rank followed by
/// ``TestStoreRank/last``, behind everything that job created.
package struct TestStoreRank: Comparable, Sendable {
  /// The index of a job queued when the job before it ends.
  static let last = UInt64.max
  /// The rank of the first job of an anchor chain, and of a value a `Store`
  /// handles at its own delivery.
  static let origin = TestStoreRank(path: [])

  private let path: [UInt64]

  func appending(_ index: UInt64) -> TestStoreRank {
    TestStoreRank(path: path + [index])
  }

  package static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.path.lexicographicallyPrecedes(rhs.path)
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
/// MainActor jobs of that level: the first at the delivery, every other
/// while the marker before it runs. The chain's members are the actions
/// whose interpreter it anchors, and the walks of composite tasks the test
/// store follows on it; an action settles once the synchronous part of its
/// reduction's walk has finished, or when it leaves the buffer without being
/// reduced, and a composite task's walk once the test store stops following
/// it. The test store is a member too while the chain holds its interpreter
/// tail: the test store starts a root walk that waited for the tail's walk
/// at the chain's level after the tail, and resumes it one level deeper each
/// time it suspends, however late the test receives the walk's action. The
/// chain queues no marker once no member is unsettled, and at most ``depth``
/// markers in all.
@MainActor
package final class TestStoreAnchorChain {
  /// The deepest level that gets a marker of its own; deeper positions — a
  /// follow-up's, a composite task's, or a walk's start or resumption —
  /// share its position. An action the test never receives queues this many
  /// markers.
  package static let depth = 16

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
    advanced(by: 1)
  }

  /// Where a `Store` runs a MainActor job queued `levels` jobs behind this
  /// one, each queued while the one before it runs. The deepest level stands
  /// for every deeper one.
  func advanced(by levels: Int) -> TestStoreAnchor {
    TestStoreAnchor(chain: chain, level: min(level + levels, TestStoreAnchorChain.depth))
  }

  /// The position the marker took, once it has run.
  var position: UInt64? {
    chain.position(atLevel: level)
  }

  /// Whether the marker ran before `order`'s event.
  func ran(before order: TestStoreOrder) -> Bool {
    position.map { $0 < order.event } ?? false
  }

  /// Whether the interpreter task anchored here, once this marker has run,
  /// still waits for the walk that ended at `predecessor`: that walk's task
  /// had not finished when this one ran. It had when it finished at an
  /// earlier point, or when it is the task created just before this one at
  /// this very anchor and ran through without waiting or suspending.
  func isBehind(_ predecessor: TestStoreInterpreterTail?) -> Bool {
    guard let predecessor, let finished = predecessor.anchor.position, let own = position
    else { return false }
    return finished > own || (finished == own && !predecessor.ranThroughAtItsAnchor)
  }

  /// Where the test store starts the walk of the interpreter task anchored
  /// here, once this marker has run, when the walk before it ended at
  /// `predecessor`: here, unless the task still waits for that walk
  /// (``isBehind(_:)``); then at the next level after the point where that
  /// walk finished, a job queued right after it finished. Short of
  /// ``TestStoreAnchorChain/depth``, that is the earliest job in which a
  /// `Store` starts the walk.
  func start(after predecessor: TestStoreInterpreterTail?) -> TestStoreAnchor {
    guard let predecessor, isBehind(predecessor) else { return self }
    return predecessor.anchor.next
  }

  func wait() async {
    await chain.waitForMarker(atLevel: level)
  }
}

/// Where the last root interpreter walk a test store followed finished.
@MainActor
package struct TestStoreInterpreterTail {
  /// The level at which the walk delivered when it returned.
  package let anchor: TestStoreAnchor
  /// The rank at that level of the job in which the walk returned.
  let rank: TestStoreRank
  /// Whether the walk started where a `Store` first runs its interpreter
  /// task and returned without suspending: that task had then finished
  /// before any task created after it ran, also one at the same anchor.
  package let ranThroughAtItsAnchor: Bool
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
      storeOrder: { TestStoreOrder(event: event, rank: .origin, order: $0) },
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

  /// A value a followed walk delivers at `place`: a `Store` handles it where
  /// that walk runs, and creates the interpreter task of its own reduction
  /// there, one level deeper.
  static func interpreted(at place: TestStoreWalkPlace, isAction: Bool) -> TestStoreDelivery {
    let followUp = isAction ? place.anchor.next : nil
    followUp?.chain.addMember()
    return .init(
      storeOrder: { TestStoreOrder(event: place.position, rank: place.rank, order: $0) },
      followUpAnchor: followUp)
  }

  /// The order of what a job handles at `place`, ahead of everything a
  /// `Store` handles there afterwards.
  static func order(at place: TestStoreWalkPlace) -> TestStoreOrder {
    TestStoreOrder(event: place.position, rank: place.rank, order: 0)
  }

  /// The rank of the interpreter task of this action's reduction at its
  /// anchor: the value's own rank where a `Store` handles it.
  var rank: TestStoreRank {
    storeOrder.rank
  }

  /// Ends the action's membership of its anchor chain: its reduction's walk
  /// has finished its synchronous part, or it left the buffer unreduced.
  func settle() {
    guard !isSettled, let followUpAnchor else { return }
    isSettled = true
    followUpAnchor.chain.settleMember()
  }
}

/// Where a followed walk places what it delivers or creates next.
@MainActor
package struct TestStoreWalkPlace {
  /// The level at which the walk delivers.
  let anchor: TestStoreAnchor
  /// The position that level's marker took.
  let position: UInt64
  /// The rank at that level of what the walk delivers or creates next.
  let rank: TestStoreRank
}

/// The walks of composite tasks a test store follows that have not finished
/// yet. They deliver at positions that can precede values already buffered,
/// so the test store takes nothing from a buffer while one is pending.
@MainActor
package final class TestStoreFollowedTasks {
  private var pendingCount = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  fileprivate func begin() {
    pendingCount += 1
  }

  fileprivate func end() {
    pendingCount -= 1
    guard pendingCount == 0 else { return }
    let resumed = waiters
    waiters.removeAll()
    for waiter in resumed {
      waiter.resume()
    }
  }

  /// Returns once no followed composite task is pending, without suspending
  /// when none is. Task cancellation does not end the wait: each pending task
  /// finishes once the marker of its level has run.
  package func settle() async {
    while pendingCount > 0 {
      await withCheckedContinuation { waiters.append($0) }
    }
  }
}

/// Starts the walks of the children of one `merge` in declaration order. Each
/// waits for the marker of its level, and a task resumed from such a wait
/// reaches the MainActor through another executor, in any order.
@MainActor
private final class TestStoreStartOrder {
  private var startedCount = 0
  private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]

  /// Returns once every child before `index` has started.
  func waitForTurn(of index: Int) async {
    guard index > startedCount else { return }
    await withCheckedContinuation { waiting[index] = $0 }
  }

  /// The child `index` starts in this MainActor job; the next one starts in
  /// a later job.
  func didStart(_ index: Int) {
    startedCount = index + 1
    waiting.removeValue(forKey: startedCount)?.resume()
  }
}

/// The walk of an effect whose deliveries a test store places where a `Store`
/// handles them, while the walk runs in one MainActor task without awaiting
/// other work:
///
/// - the root interpreter walk of a received or sent action's reduction,
///   until it returns;
/// - the walk a `Store` runs in a task that a followed walk creates — the
///   children of an unawaited `concatenate`, or one child of an unawaited
///   `merge` — until it returns or first awaits other work: a run, a timer,
///   or the children of an awaited `merge`.
///
/// A followed walk delivers at one anchor level at a time. Each time it
/// resumes from a suspension inside the effect driver — a clock read, an
/// admission — it delivers one level deeper: a `Store` resumes it behind
/// every MainActor job queued before it suspended, at the earliest where the
/// next level runs.
@MainActor
package final class TestStoreFollowedWalk {
  /// The followed walk the current task runs. A task a walk creates inherits
  /// it; the task of a composite, the work of a timer and the task of a
  /// scheduled run set their own.
  @TaskLocal static var current: TestStoreFollowedWalk?

  /// Where a `Store` handles the action whose reduction returned the effect:
  /// the delivery of the received action, or the place of the send; `nil`
  /// for the walk of a task another walk created.
  let handled: TestStoreDelivery?
  /// Whether a `Store` drains the effect the reduction returned with the
  /// reduction, instead of creating an interpreter task for it.
  let isDrained: Bool
  /// Where a `Store` first runs the task of the walk; `nil` for a drained
  /// effect.
  let anchor: TestStoreAnchor?
  /// Where the test store starts the walk: the anchor, or, for a root walk,
  /// the next level after the walk created before it finished
  /// (``TestStoreAnchor/start(after:)``).
  private(set) var startAnchor: TestStoreAnchor?
  /// Where the test store places what the walk delivers now: its start, and
  /// one level deeper each time it resumed (``TestStoreAnchor/next``). Short
  /// of ``TestStoreAnchorChain/depth``, that is behind every MainActor job
  /// queued before the walk last suspended, where a `Store` resumes it at
  /// the earliest.
  private(set) var deliveryAnchor: TestStoreAnchor?
  /// The last value a drained effect placed behind its action; the next one
  /// goes behind it.
  var lastFollowUp: TestStoreDelivery?

  private let store: ObjectIdentifier
  private let sequence: UInt64?
  /// The store's pending followed composite tasks, this walk's among them
  /// when it is one.
  private let tasks: TestStoreFollowedTasks
  /// The turn of a `merge`'s child among its siblings.
  private let turn: (order: TestStoreStartOrder, index: Int)?
  /// The rank, at the level where the walk delivers, of the job it runs in.
  private var rank: TestStoreRank
  /// The index of what the walk delivers or creates next in that job.
  private var nextIndex: UInt64 = 0
  /// The walk has started.
  private var hasStarted = false
  /// The test store still follows the walk: it has neither returned nor
  /// awaited other work.
  private var isFollowed = true
  /// The walk is inside an effect-driver call that can suspend it.
  private var isAwaitingDriver = false
  /// The walk suspended inside that call and has not resumed.
  private var isSuspended = false
  /// The walk did not start where a `Store` first runs its task, or suspended.
  private var didWaitOrSuspend = false
  /// Counts the stretches the walk ran between suspensions.
  private var stretch: UInt64 = 0

  /// Follows the root walk of the effect that the reduction of an action a
  /// `Store` handles at `handled` returned.
  init(
    handled: TestStoreDelivery, isDrained: Bool, store: AnyObject, sequence: UInt64?,
    tasks: TestStoreFollowedTasks
  ) {
    self.handled = handled
    self.isDrained = isDrained
    self.store = ObjectIdentifier(store)
    self.sequence = sequence
    self.tasks = tasks
    turn = nil
    rank = handled.rank
    anchor = isDrained ? nil : handled.followUpAnchor
    startAnchor = anchor
    deliveryAnchor = anchor
  }

  /// Follows the walk of a task that `creator` creates, which a `Store` runs
  /// at `anchor` with `rank`. The walk is a member of the anchor's chain, and
  /// pending, until the test store stops following it.
  private init(
    at anchor: TestStoreAnchor, rank: TestStoreRank, creator: TestStoreFollowedWalk,
    turn: (order: TestStoreStartOrder, index: Int)? = nil
  ) {
    handled = nil
    isDrained = false
    store = creator.store
    sequence = creator.sequence
    tasks = creator.tasks
    self.turn = turn
    self.rank = rank
    self.anchor = anchor
    startAnchor = anchor
    deliveryAnchor = anchor
    anchor.chain.addMember()
    tasks.begin()
  }

  /// The followed walk that is delivering a value of the effect `sequence`
  /// into `store` right now, in the current task.
  static func delivering(in store: AnyObject, sequence: UInt64?) -> TestStoreFollowedWalk? {
    guard let walk = current, walk.store == ObjectIdentifier(store), walk.isDelivering,
      let sequence, walk.sequence == sequence
    else { return nil }
    return walk
  }

  /// Follows the walk of the task that the walk delivering a value of
  /// `context` into `store` creates now for an unawaited `concatenate`: a
  /// `Store` walks the children in a MainActor task it creates there, the
  /// job queued behind the creating one. `nil` when no followed walk is
  /// creating the task.
  static func ofSequentialTask(
    in store: AnyObject, context: EffectExecutionContext?
  ) -> TestStoreFollowedWalk? {
    guard let creator = delivering(in: store, sequence: context?.sequence),
      let place = creator.placeNext()
    else { return nil }
    return TestStoreFollowedWalk(at: place.anchor.next, rank: place.rank, creator: creator)
  }

  /// Follows the walks of the `count` children of an unawaited `merge` that
  /// the walk delivering a value of `context` into `store` starts now. A
  /// `Store` creates one MainActor task there, in which a task group hands
  /// every child to the MainActor from another executor to check that the
  /// effect can proceed, then walks the child: an optimized build walks it
  /// in that job, two MainActor jobs behind the creating one, each queued
  /// while the one before it runs; a debug build hands the child back to
  /// another executor in between and walks it a job later. The children race
  /// each other; the test store starts them two jobs behind, the earliest
  /// point, in declaration order. `nil` for every child when no followed walk
  /// is starting them.
  static func ofConcurrentChildren(
    _ count: Int, in store: AnyObject, context: EffectExecutionContext?
  ) -> [TestStoreFollowedWalk?] {
    guard let creator = delivering(in: store, sequence: context?.sequence),
      let place = creator.placeNext()
    else { return Array(repeating: nil, count: count) }
    let order = TestStoreStartOrder()
    return (0..<count).map { index in
      TestStoreFollowedWalk(
        at: place.anchor.advanced(by: 2),
        rank: place.rank.appending(UInt64(index)).appending(TestStoreRank.last),
        creator: creator, turn: (order, index))
    }
  }

  /// Where the walk finished, for the root walk created after it.
  var tail: TestStoreInterpreterTail? {
    deliveryAnchor.map {
      TestStoreInterpreterTail(anchor: $0, rank: rank, ranThroughAtItsAnchor: !didWaitOrSuspend)
    }
  }

  /// The walk will start once the walk that ended at `predecessor` has
  /// finished: at its anchor, or, when it still waits for that walk then, at
  /// the next level after the point where that walk finished, on the chain
  /// that holds the interpreter tail, which keeps queueing levels while it
  /// does. A `Store` queues the waiting walk when its predecessor's last job
  /// ends.
  ///
  /// - Returns: Where the walk starts.
  func prepareToStart(after predecessor: TestStoreInterpreterTail?) -> TestStoreAnchor? {
    guard let anchor, let predecessor, anchor.isBehind(predecessor) else { return anchor }
    didWaitOrSuspend = true
    rank = predecessor.rank.appending(TestStoreRank.last)
    startAnchor = predecessor.anchor.next
    deliveryAnchor = startAnchor
    return startAnchor
  }

  /// Runs `body`, the walk, in the current task, once the marker of its
  /// start has run: the walk delivers there until it first suspends.
  func run(_ body: () async -> Void) async {
    hasStarted = true
    if !isDrained {
      beginStretch()
    }
    await Self.$current.withValue(self) { await body() }
  }

  /// Runs `body`, the walk of a task another walk created: followed as
  /// `walk`, once the marker of its level has run and the children of the
  /// same `merge` before it have started; without a walk to follow it as,
  /// handled at its deliveries.
  static func runTask(following walk: TestStoreFollowedWalk?, _ body: () async -> Void) async {
    guard let walk else {
      return await $current.withValue(nil) { await body() }
    }
    await walk.anchor?.wait()
    if let turn = walk.turn {
      await turn.order.waitForTurn(of: turn.index)
      turn.order.didStart(turn.index)
    }
    await walk.run(body)
    walk.finish()
  }

  /// `recurse` for a timer's work: what it walks is handled at its
  /// delivery, whichever walk armed the timer.
  static func unfollowed<Action: Sendable, Output: Sendable>(
    _ recurse:
      @escaping @MainActor @Sendable (
        ReducerEffect<Action, Output>, EffectExecutionContext?, Bool
      ) async -> Void
  )
    -> @MainActor @Sendable (ReducerEffect<Action, Output>, EffectExecutionContext?, Bool) async
    -> Void
  {
    { effect, context, awaited in
      await runTask(following: nil) { await recurse(effect, context, awaited) }
    }
  }

  /// The walk has returned, or awaits other work: values delivered from now
  /// on are handled at their delivery, and the walk's membership settles.
  func finish() {
    guard isFollowed else { return }
    isFollowed = false
    if let handled {
      handled.settle()
    } else {
      anchor?.chain.settleMember()
      tasks.end()
    }
  }

  /// Where the walk places the value it delivers or the task it creates now,
  /// and takes that place; `nil` when the marker of its level has not run.
  func placeNext() -> TestStoreWalkPlace? {
    guard let place else { return nil }
    nextIndex += 1
    return place
  }

  /// The order behind which a cancellation the walk applies now removes
  /// covered values: where a `Store` handles the action, then where the walk
  /// delivers next.
  var threshold: TestStoreOrder? {
    guard hasStarted, !isDrained, let place else { return handled?.storeOrder }
    return TestStoreDelivery.order(at: place)
  }

  /// The walk the current task runs, when the test store follows it and it
  /// is about to make an effect-driver call on `store` that can suspend it.
  /// The caller reports the return of that call with
  /// ``didResumeFromDriver()``.
  static func awaitingDriver(in store: AnyObject) -> TestStoreFollowedWalk? {
    guard let walk = current, walk.store == ObjectIdentifier(store), walk.isDelivering,
      !walk.isDrained
    else { return nil }
    walk.isAwaitingDriver = true
    return walk
  }

  /// The effect-driver call has returned. When it suspended the walk, the
  /// walk delivers one level deeper from now on, behind everything the job
  /// it suspended in created. That level's marker was queued when the marker
  /// before it ran, before the stretch that just ended began, so it has run:
  /// the chain had an unsettled member then — the walk's own action, the
  /// walk itself, or the test store while the chain held the interpreter
  /// tail. Only walks running concurrently on one store can find it missing;
  /// the walk then keeps delivering where it did.
  func didResumeFromDriver() {
    isAwaitingDriver = false
    guard isFollowed, isSuspended else { return }
    isSuspended = false
    didWaitOrSuspend = true
    if let next = deliveryAnchor?.next, next.position != nil {
      deliveryAnchor = next
      rank = rank.appending(TestStoreRank.last)
      nextIndex = 0
    }
    beginStretch()
  }

  /// Where the walk delivers or creates next, once the marker of its level
  /// has run.
  private var place: TestStoreWalkPlace? {
    guard let anchor = deliveryAnchor, let position = anchor.position else { return nil }
    return TestStoreWalkPlace(anchor: anchor, position: position, rank: rank.appending(nextIndex))
  }

  /// Whether the walk's own task is running a stretch the test store follows.
  private var isDelivering: Bool {
    hasStarted && isFollowed && !isSuspended
  }

  /// The walk runs from now until it next suspends. MainActor jobs run in the
  /// order they are queued: the job queued here runs once the walk has
  /// suspended or returned, before the walk resumes and before any work the
  /// walk started in this stretch.
  private func beginStretch() {
    stretch &+= 1
    let begun = stretch
    Task { @MainActor [weak self] in
      self?.stretchDidEnd(begun)
    }
  }

  /// The stretch has ended: inside an effect-driver call, the walk resumes
  /// one level deeper; anywhere else, it awaits other work or has returned,
  /// and the test store stops following it.
  private func stretchDidEnd(_ ended: UInt64) {
    guard isFollowed, ended == stretch else { return }
    if isAwaitingDriver {
      isSuspended = true
    } else {
      finish()
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
      await walkFollowing(effect, context: context, handled: entry.delivery, isDrained: true)
    case .interpreted:
      await walkFollowing(effect, context: context, handled: entry.delivery, isDrained: false)
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
      await walkFollowing(effect, context: context, handled: prepared.delivery, isDrained: true)
      await prepared.runDeferredWalks()
    case .interpreted:
      await prepared.runDeferredWalks()
      await walkFollowing(effect, context: context, handled: prepared.delivery, isDrained: false)
    }
  }

  /// The anchor markers this store has queued, for its deliveries and sends.
  package var queuedAnchorMarkerCount: Int {
    queue.anchorMarkerCount?.value ?? 0
  }

  /// Walks a reduction's effect where a `Store` interprets it: inline when
  /// the `Store` drains it, otherwise once the walk's anchor has run.
  ///
  /// - Parameter handled: Where a `Store` handles the action whose reduction
  ///   returned the effect.
  private func walkFollowing(
    _ effect: ReducerEffect<R.Action, R.Output>,
    context: EffectExecutionContext,
    handled: TestStoreDelivery,
    isDrained: Bool
  ) async {
    let walk = TestStoreFollowedWalk(
      handled: handled, isDrained: isDrained, store: self, sequence: context.sequence,
      tasks: followedTasks)
    defer { walk.finish() }
    // A drained walk delivers its value without suspending.
    guard let anchor = walk.anchor else {
      return await walk.run { await walker.walk(effect, context: context, awaited: false) }
    }
    await anchor.wait()
    // A `Store` starts the walk once the walk it created before has finished.
    await walk.prepareToStart(after: interpreterTail)?.wait()
    await walk.run { await walker.walk(effect, context: context, awaited: false) }
    interpreterTail = walk.tail
  }

  /// Buffers an effect action where a `Store` handles it: right behind the
  /// received action, after the ones its reduction drained before, when the
  /// synchronous part of a drained walk delivers it; at its walk's anchor
  /// when an interpreted walk does; otherwise at its delivery.
  func enqueueDeliveredAction(_ action: R.Action, context: EffectExecutionContext?) {
    guard let walk = TestStoreFollowedWalk.delivering(in: self, sequence: context?.sequence)
    else {
      queue.enqueue(action, context: context)
      return
    }
    if walk.isDrained, let handled = walk.handled {
      walk.lastFollowUp = queue.enqueue(
        action, context: context, delivery: .drained(after: handled, isAction: true),
        placement: .front(behind: walk.lastFollowUp))
    } else if let place = walk.placeNext() {
      queue.enqueue(
        action, context: context, delivery: .interpreted(at: place, isAction: true),
        placement: .ordered)
    } else {
      queue.enqueue(action, context: context)
    }
  }

  /// Buffers an output where a `Store` publishes it, as for an action.
  func enqueueDeliveredOutput(_ output: R.Output, context: EffectExecutionContext?) {
    guard let walk = TestStoreFollowedWalk.delivering(in: self, sequence: context?.sequence)
    else {
      outputQueue.enqueue(output, context: context, tracksActivity: false)
      return
    }
    let delivery: TestStoreDelivery
    if walk.isDrained, let handled = walk.handled {
      delivery = .drained(after: handled, isAction: false)
    } else if let place = walk.placeNext() {
      delivery = .interpreted(at: place, isAction: false)
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
    } else if let walk = TestStoreFollowedWalk.delivering(in: self, sequence: issuer),
      let walkThreshold = walk.threshold
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
    await followedTasks.settle()
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
