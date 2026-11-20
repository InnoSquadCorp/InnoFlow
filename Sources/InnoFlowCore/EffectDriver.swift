// MARK: - EffectDriver.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import Synchronization

/// Ownership metadata for delayed debounce and throttle work.
///
/// A timing identifier owns the delayed work directly. Cancellation identifiers
/// inherited from enclosing effect scopes also own it, so cancelling any member
/// can tear the delayed state down without waiting for a nested `.run` to start.
package struct DelayedEffectScope: Sendable {
  package let ownerID: AnyEffectID
  package let inheritedCancellationIDs: [AnyEffectID]
  package let sequence: UInt64
  package let cancellationContext: EffectExecutionContext?
  /// Identifies the request this scope belongs to, through every copy.
  package let requestID: UUID

  package init(
    ownerID: AnyEffectID,
    inheritedCancellationIDs: [AnyEffectID] = [],
    sequence: UInt64? = nil,
    cancellationContext: EffectExecutionContext? = nil
  ) {
    self.ownerID = ownerID
    self.inheritedCancellationIDs = inheritedCancellationIDs
    self.sequence = sequence ?? 0
    self.cancellationContext = cancellationContext?.frozenForExecution()
    self.requestID = UUID()
  }

  package func contains(_ id: AnyEffectID) -> Bool {
    ownerID == id || inheritedCancellationIDs.contains(id)
  }

  package var shouldProceed: Bool {
    cancellationContext?.shouldProceed ?? true
  }
}

package func shouldAdmitDelayedScope(
  _ candidate: DelayedEffectScope,
  replacing current: DelayedEffectScope?
) -> Bool {
  guard let current else { return true }
  return candidate.sequence >= current.sequence
}

/// The end of one throttle window, which every request the window holds
/// waits for: through its dispatch, and through the interpreter frame of an
/// awaited request.
///
/// The window's timer is shared by the dispatches whose requests it holds,
/// but each request waits through an entry of its own. A request that an ID
/// cancellation removes from the window is released at once, so its
/// dispatch's waiting stays scoped to its own work, while the window keeps
/// its timer for the requests that remain. The timer's task completes the
/// window when it returns, which releases every request still held: also a
/// request the window no longer retains, and one its dispatch's cancellation
/// removed.
package final class ThrottleWindowCompletion: Sendable {
  private struct Entry {
    /// The completion the request's dispatch tracks.
    var dispatchCompletion: FlowTaskCompletion?
    /// Interpreter frames of the request that await the window.
    var waiters: [CheckedContinuation<Void, Never>] = []
  }

  private struct State {
    var isComplete = false
    var entries: [UUID: Entry] = [:]
  }

  private let state = Mutex(State())

  package init() {}

  /// Makes the window hold `request`, and `tracker`'s dispatch wait for it
  /// on that request's behalf. A completed window holds nothing.
  package func hold(_ request: UUID, for tracker: FlowTaskTracker?) {
    let dispatchCompletion = tracker.map { _ in FlowTaskCompletion() }
    let isHeld = state.withLock { state -> Bool in
      guard !state.isComplete, state.entries[request] == nil else { return false }
      state.entries[request] = Entry(dispatchCompletion: dispatchCompletion)
      return true
    }
    // A completion the window completed in between is observed as complete.
    if isHeld, let tracker, let dispatchCompletion {
      tracker.trackCompletion(of: dispatchCompletion)
    }
  }

  /// Suspends until the window releases `request`: when it completes, or
  /// when a cancellation removes the request first. Returns at once for a
  /// request the window does not hold.
  package func waitForRelease(of request: UUID) async {
    await withCheckedContinuation { continuation in
      let isHeld = state.withLock { state -> Bool in
        guard state.entries[request] != nil else { return false }
        state.entries[request]?.waiters.append(continuation)
        return true
      }
      if !isHeld {
        continuation.resume()
      }
    }
  }

  /// Releases `request`, which the window no longer holds.
  package func release(_ request: UUID) {
    guard let entry = state.withLock({ $0.entries.removeValue(forKey: request) }) else { return }
    Self.finish(entry)
  }

  /// Ends the window and releases every request it still holds.
  package func complete() {
    let entries = state.withLock { state -> [Entry] in
      state.isComplete = true
      let entries = Array(state.entries.values)
      state.entries.removeAll(keepingCapacity: false)
      return entries
    }
    for entry in entries {
      Self.finish(entry)
    }
  }

  private static func finish(_ entry: Entry) {
    entry.dispatchCompletion?.complete()
    for waiter in entry.waiters {
      waiter.resume()
    }
  }
}

@MainActor
package final class ThrottleStateMap<Action: Sendable, Output: Sendable> {
  private struct AdmissionState {
    var latestSequence: UInt64
    var outstandingCount: Int
  }

  package struct PendingTrailing: Sendable {
    package let effect: ReducerEffect<Action, Output>
    package let context: EffectExecutionContext?
    package let requiresAwaitedCompletion: Bool
    /// The request's ownership metadata. A window whose owner an ID
    /// cancellation removes passes back to the newest remaining request
    /// through it.
    package let scope: DelayedEffectScope?
  }

  /// What a cancellation did to one window.
  package enum WindowCancellation {
    /// The cancellation covers neither the window's owner nor a request the
    /// window retains.
    case unaffected
    /// The cancellation removed retained requests other than the owner.
    case pruned
    /// The cancellation removed the window's owner. The newest remaining
    /// request that can still proceed owns the window now, and the window
    /// keeps its timer.
    case handedOver(to: PendingTrailing)
    /// No request was left to own the window, so it was reset and its timer
    /// cancelled.
    case reset
  }

  private var windowEndByID: [AnyEffectID: ContinuousClock.Instant] = [:]
  /// Trailing requests of the current window, oldest first.
  ///
  /// The window fires the newest request that can still proceed. Requests it
  /// supersedes are kept so that cancelling the newest request — through its
  /// dispatch or through an ID only it carries — gives the window back to
  /// the request it replaced instead of silently taking that request down
  /// with it: a cancellation affects only the work it covers. The list is
  /// bounded by ``supersededPendingLimit``.
  private var pendingByID: [AnyEffectID: [PendingTrailing]] = [:]

  /// How many trailing requests one window retains: the newest and the
  /// requests it can fall back to. Older ones are dropped first.
  package static var supersededPendingLimit: Int { 8 }
  private var trailingTaskByID: [AnyEffectID: Task<Void, Never>] = [:]
  private var trailingCompletionByID: [AnyEffectID: ThrottleWindowCompletion] = [:]
  private var generationByID: [AnyEffectID: UInt64] = [:]
  private var scopeByID: [AnyEffectID: DelayedEffectScope] = [:]
  private var admissionStateByID: [AnyEffectID: AdmissionState] = [:]
  private var nextGenerationValue: UInt64 = 0

  package init() {}

  package func windowEnd(for id: AnyEffectID) -> ContinuousClock.Instant? {
    windowEndByID[id]
  }

  package func setWindowEnd(_ instant: ContinuousClock.Instant, for id: AnyEffectID) {
    windowEndByID[id] = instant
  }

  package func storePending(
    _ effect: ReducerEffect<Action, Output>,
    context: EffectExecutionContext?,
    requiresAwaitedCompletion: Bool = false,
    scope: DelayedEffectScope? = nil,
    for id: AnyEffectID
  ) {
    var requests = pendingByID[id] ?? []
    let requiresAwaitedCompletion =
      requests.contains { $0.requiresAwaitedCompletion } || requiresAwaitedCompletion
    // A request that can no longer proceed will never fire; only requests
    // that could still be fallen back to are worth retaining.
    requests.removeAll { $0.context?.shouldProceed == false }
    requests.append(
      .init(
        effect: effect,
        context: context,
        requiresAwaitedCompletion: requiresAwaitedCompletion,
        scope: scope
      )
    )
    if requests.count > Self.supersededPendingLimit {
      requests.removeFirst(requests.count - Self.supersededPendingLimit)
    }
    pendingByID[id] = requests
  }

  /// The newest trailing request stored for the window, whether or not it
  /// can still proceed.
  package func pending(for id: AnyEffectID) -> PendingTrailing? {
    pendingByID[id]?.last
  }

  /// The trailing request the window fires when it closes: the newest one
  /// whose context can still proceed.
  package func pendingToFire(for id: AnyEffectID) -> PendingTrailing? {
    pendingByID[id]?.last { $0.context?.shouldProceed ?? true }
  }

  package func setTrailingTask(
    _ task: Task<Void, Never>,
    completion: ThrottleWindowCompletion? = nil,
    for id: AnyEffectID
  ) {
    trailingTaskByID[id] = task
    trailingCompletionByID[id] = completion
  }

  package func trailingCompletion(for id: AnyEffectID) -> ThrottleWindowCompletion? {
    trailingCompletionByID[id]
  }

  /// Makes the window under `id` hold `request`: the request's dispatch
  /// waits for the window until it closes, or until a cancellation removes
  /// the request from it.
  ///
  /// - Returns: the window that now holds the request, for an awaited request
  ///   to wait on.
  @discardableResult
  package func holdWindow(
    for id: AnyEffectID,
    request: DelayedEffectScope
  ) -> ThrottleWindowCompletion? {
    guard let window = trailingCompletionByID[id] else { return nil }
    window.hold(request.requestID, for: request.cancellationContext?.flowTaskTracker)
    return window
  }

  package func scope(for id: AnyEffectID) -> DelayedEffectScope? {
    scopeByID[id]
  }

  package func trailingTask(for id: AnyEffectID) -> Task<Void, Never>? {
    trailingTaskByID[id]
  }

  package func latestAdmissionSequence(for id: AnyEffectID) -> UInt64? {
    admissionStateByID[id]?.latestSequence
  }

  /// Registers a throttle request before its asynchronous clock read.
  ///
  /// The short-lived ledger prevents an older suspended clock read from
  /// recreating state after a newer request overtakes and finishes. Entries are
  /// removed when every overlapping clock read completes, so dynamic timing IDs
  /// are not retained for the lifetime of the store.
  @discardableResult
  package func beginAdmission(_ scope: DelayedEffectScope) -> Bool {
    let activeSequence = scopeByID[scope.ownerID]?.sequence
    let pendingSequence = admissionStateByID[scope.ownerID]?.latestSequence
    if let latest = [activeSequence, pendingSequence].compactMap({ $0 }).max(),
      scope.sequence < latest
    {
      return false
    }

    if var state = admissionStateByID[scope.ownerID] {
      state.latestSequence = max(state.latestSequence, scope.sequence)
      state.outstandingCount += 1
      admissionStateByID[scope.ownerID] = state
    } else {
      admissionStateByID[scope.ownerID] = .init(
        latestSequence: scope.sequence,
        outstandingCount: 1
      )
    }
    return true
  }

  package func admit(_ scope: DelayedEffectScope) -> Bool {
    guard let state = admissionStateByID[scope.ownerID] else { return false }
    guard scope.sequence >= state.latestSequence else { return false }
    guard let activeScope = scopeByID[scope.ownerID] else { return true }
    return shouldAdmitDelayedScope(scope, replacing: activeScope)
  }

  package func endAdmission(for id: AnyEffectID) {
    guard var state = admissionStateByID[id] else { return }
    state.outstandingCount -= 1
    if state.outstandingCount == 0 {
      admissionStateByID.removeValue(forKey: id)
    } else {
      admissionStateByID[id] = state
    }
  }

  /// Assigns ownership to work that actually occupies the active window.
  @discardableResult
  package func setScope(_ scope: DelayedEffectScope) -> Bool {
    guard admissionStateByID[scope.ownerID]?.latestSequence == scope.sequence else {
      return false
    }
    scopeByID[scope.ownerID] = scope
    return true
  }

  package func cancelTrailingTask(for id: AnyEffectID) {
    trailingTaskByID.removeValue(forKey: id)?.cancel()
    trailingCompletionByID.removeValue(forKey: id)
  }

  package func generation(for id: AnyEffectID) -> UInt64? {
    generationByID[id]
  }

  @discardableResult
  package func nextGeneration(for id: AnyEffectID) -> UInt64 {
    nextGenerationValue &+= 1
    generationByID[id] = nextGenerationValue
    return nextGenerationValue
  }

  package func resetWindow(for id: AnyEffectID) {
    cancelTrailingTask(for: id)
    generationByID.removeValue(forKey: id)
    pendingByID.removeValue(forKey: id)
  }

  /// Applies a cancellation to one window.
  ///
  /// The retained trailing requests the cancellation covers, and any that can
  /// no longer proceed, are removed. When it covers the request that owns
  /// the window, ownership passes to the newest remaining request that can
  /// still proceed, and the window keeps its timer and deadline; only a
  /// window with no such request left is reset.
  ///
  /// The window releases every request the cancellation covers, so their
  /// dispatches no longer wait for a timer that now serves other requests.
  @discardableResult
  package func clearState(
    for id: AnyEffectID,
    where shouldClear: (DelayedEffectScope) -> Bool
  ) -> WindowCancellation {
    let window = trailingCompletionByID[id]
    var released: [UUID] = []
    defer {
      // Once the window's state is final: releasing a request runs its
      // dispatch's completion callbacks.
      for request in released {
        window?.release(request)
      }
    }
    let retained = pendingByID[id] ?? []
    let remaining = retained.filter { request in
      if let scope = request.scope, shouldClear(scope) {
        released.append(scope.requestID)
        return false
      }
      return request.context?.shouldProceed != false
    }
    if remaining.count != retained.count {
      pendingByID[id] = remaining.isEmpty ? nil : remaining
    }
    guard let owner = scopeByID[id], shouldClear(owner) else {
      return remaining.count == retained.count ? .unaffected : .pruned
    }
    released.append(owner.requestID)
    guard let successor = remaining.last, let successorScope = successor.scope else {
      resetWindow(for: id)
      windowEndByID.removeValue(forKey: id)
      scopeByID.removeValue(forKey: id)
      return .reset
    }
    scopeByID[id] = successorScope
    return .handedOver(to: successor)
  }

  /// Applies a cancellation to every window.
  ///
  /// - Returns: the context of the request that took over each window whose
  ///   owner the cancellation removed. A runtime that tracks the shared timer
  ///   under its owner's IDs moves it to that request.
  @discardableResult
  package func clearStates(
    where shouldClear: (DelayedEffectScope) -> Bool
  ) -> [AnyEffectID: EffectExecutionContext] {
    var newOwners: [AnyEffectID: EffectExecutionContext] = [:]
    for id in Set(scopeByID.keys).union(pendingByID.keys) {
      if case .handedOver(let owner) = clearState(for: id, where: shouldClear),
        let context = owner.context
      {
        newOwners[id] = context
      }
    }
    return newOwners
  }

  /// Dispatches that lose throttled work to a cancellation: the owner of a
  /// window, and the owners of the trailing requests a window retains.
  package func cancellationTargetDispatchIDs(
    where isTarget: (DelayedEffectScope) -> Bool
  ) -> Set<DispatchID> {
    var dispatchIDs: Set<DispatchID> = []
    for scope in scopeByID.values where isTarget(scope) {
      if let dispatchID = scope.cancellationContext?.dispatchID {
        dispatchIDs.insert(dispatchID)
      }
    }
    for requests in pendingByID.values {
      for request in requests {
        guard let scope = request.scope, isTarget(scope),
          let dispatchID = scope.cancellationContext?.dispatchID
        else { continue }
        dispatchIDs.insert(dispatchID)
      }
    }
    return dispatchIDs
  }

  @discardableResult
  package func finishState(for id: AnyEffectID, generation: UInt64) -> Bool {
    guard generationByID[id] == generation else { return false }
    trailingTaskByID.removeValue(forKey: id)
    trailingCompletionByID.removeValue(forKey: id)
    generationByID.removeValue(forKey: id)
    pendingByID.removeValue(forKey: id)
    windowEndByID.removeValue(forKey: id)
    scopeByID.removeValue(forKey: id)
    return true
  }

  package func clearAll() {
    for task in trailingTaskByID.values {
      task.cancel()
    }
    trailingTaskByID.removeAll(keepingCapacity: true)
    trailingCompletionByID.removeAll(keepingCapacity: true)
    pendingByID.removeAll(keepingCapacity: true)
    windowEndByID.removeAll(keepingCapacity: true)
    generationByID.removeAll(keepingCapacity: true)
    scopeByID.removeAll(keepingCapacity: true)
    admissionStateByID.removeAll(keepingCapacity: true)
  }
}

// MARK: - Effect Driver Protocol

/// Runtime-specific primitives for effect interpretation.
///
/// The walker (`EffectWalker`) owns the recursive tree-traversal and structural rules.
/// The driver provides leaf operations that differ between `Store` and `TestStore`.
@MainActor
package protocol EffectDriver<Action, Output>: AnyObject {
  associatedtype Action: Sendable
  associatedtype Output: Sendable

  // MARK: - Leaf Operations

  /// Deliver an action back to the reduce cycle.
  func deliverAction(_ action: Action, context: EffectExecutionContext?)

  /// Deliver a reducer output after the action's state mutation is visible.
  func deliverOutput(_ output: Output, context: EffectExecutionContext?)

  /// Surface a structural action drop (e.g., `IfLet` child state missing)
  /// without re-delivering the action. Stores route this to
  /// `StoreInstrumentation.didDropAction`; test runtimes may no-op.
  func reportActionDrop(
    _ action: Action,
    reason: ActionDropReason,
    context: EffectExecutionContext?
  )

  /// Starts and registers a `.run` effect, returning its tracked task.
  /// The walker decides whether to await completion after the driver's strong
  /// reference has left scope.
  @discardableResult
  func startRun(
    priority: TaskPriority?,
    operation: @escaping @concurrent @Sendable (Send<Action>, EffectContext) async -> Void,
    context: EffectExecutionContext?
  ) async -> Task<Void, Never>

  /// Admits a run into a Store-local execution lane and returns the task that
  /// owns both queue waiting and physical operation completion.
  @discardableResult
  func scheduleRun(
    id: AnyEffectID,
    policy: EffectExecutionPolicy,
    priority: TaskPriority?,
    onAdmission: (@Sendable (EffectAdmission) -> Action)?,
    operation: @escaping @concurrent @Sendable (Send<Action>, EffectContext) async -> Void,
    context: EffectExecutionContext?
  ) async -> Task<Void, Never>?

  // MARK: - Cancellation

  /// Cancel all effects for the given id.
  /// Used by `.cancel(id)` — includes the current sequence in the boundary.
  func cancelEffects(id: AnyEffectID, context: EffectExecutionContext?) async

  /// Cancel in-flight effects for the given id, preserving the current
  /// sequence's eligibility.
  /// Used by `.cancellable(cancelInFlight: true)` and `.debounce`.
  func cancelInFlightEffects(id: AnyEffectID, context: EffectExecutionContext?) async

  /// Whether execution should proceed for the given context.
  /// Store and TestStore both check sequence boundaries for cancellable effects.
  func shouldProceed(context: EffectExecutionContext?) -> Bool

  /// Reports work declared under an effect ID that an ID cancellation
  /// released before the interpreter reached it.
  ///
  /// The cancellation was accepted while the work was declared but not yet
  /// registered (an earlier sibling was still running, or the issuing
  /// effect's own `.cancel` was interpreted first), so its token is created
  /// already cancelled and the work is skipped without anything recording
  /// the cancellation for the dispatch that owns it. `context` is the
  /// work's own context. A runtime without dispatch diagnostics ignores it.
  func reportCancelledBeforeRegistration(context: EffectExecutionContext)

  // MARK: - Debounce

  /// Schedules a debounced effect and returns its registered delay task.
  /// The driver owns timer and generation tracking. When the timer fires, it
  /// interprets the nested effect using the requested awaited semantics.
  ///
  /// The walker decides whether to await the returned task after the driver's
  /// strong reference has left scope.
  @discardableResult
  func scheduleDebounce(
    _ nested: ReducerEffect<Action, Output>,
    id: AnyEffectID,
    interval: Duration,
    context: EffectExecutionContext?,
    scope: DelayedEffectScope,
    nestedAwaited: Bool,
    recurse:
      @escaping @MainActor @Sendable (
        ReducerEffect<Action, Output>, EffectExecutionContext?, Bool
      ) async -> Void
  ) async -> Task<Void, Never>?

  // MARK: - Throttle State

  /// Shared throttle bookkeeping for the driver.
  var throttleState: ThrottleStateMap<Action, Output> { get }

  /// Schedules the generation-scoped drain task for the throttle id.
  ///
  /// Every window gets a drain so leading-only state expires at its deadline;
  /// the task recurses only when a trailing effect is pending.
  /// `awaited` records whether the call that opened the window needs the
  /// trailing window to complete. Later pending replacements can only promote
  /// that requirement through `PendingTrailing.requiresAwaitedCompletion`.
  /// `schedulingContext` identifies the effect frame that created the sleeper;
  /// a successful drain still recurses with the latest pending context.
  ///
  /// The drain installs a ``ThrottleWindowCompletion`` with its task through
  /// ``ThrottleStateMap/setTrailingTask(_:completion:for:)`` and completes it
  /// when the task returns. The walker makes each request's dispatch wait on
  /// that window, never on the task itself.
  @discardableResult
  func scheduleTrailingDrain(
    for id: AnyEffectID,
    interval: Duration,
    schedulingContext: EffectExecutionContext,
    awaited: Bool,
    recurse:
      @escaping @MainActor @Sendable (
        ReducerEffect<Action, Output>, EffectExecutionContext?, Bool
      ) async -> Void
  ) -> Task<Void, Never>

  /// Refreshes runtime-specific ownership when an active trailing drain is
  /// reused by a newer pending effect. Production Store ownership lives in
  /// `throttleState`; TestStore also reindexes its finish/cancellation task.
  /// The newer request's dispatch waits for the window through
  /// ``ThrottleStateMap/holdWindow(for:request:)``.
  func refreshTrailingDrainOwnership(
    for id: AnyEffectID,
    context: EffectExecutionContext
  )

  /// Current clock instant for throttle window comparison.
  var now: ContinuousClock.Instant { get async }

  // MARK: - Concurrency Primitives

  /// Start children concurrently (merge) without waiting for them. The
  /// walker awaits an awaited merge itself, so a driver only ever owns the
  /// detached form.
  func runConcurrently(
    _ children: [ReducerEffect<Action, Output>],
    context: EffectExecutionContext?,
    recurse:
      @escaping @MainActor @Sendable (
        ReducerEffect<Action, Output>, EffectExecutionContext?, Bool
      ) async -> Void
  ) async

  /// Start children sequentially (concatenate) in a driver-owned task without
  /// waiting for it. The walker runs an awaited concatenation itself.
  func runSequentially(
    _ children: [ReducerEffect<Action, Output>],
    context: EffectExecutionContext?,
    recurse:
      @escaping @MainActor @Sendable (
        ReducerEffect<Action, Output>, EffectExecutionContext?, Bool
      ) async -> Void
  ) async
}

extension EffectDriver {
  /// A runtime without dispatch diagnostics has nothing to record.
  package func reportCancelledBeforeRegistration(context: EffectExecutionContext) {}
}
