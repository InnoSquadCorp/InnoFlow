// MARK: - TestStore+EffectDriver.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
package import InnoFlowCore
import os

private final class ActionQueueWaiterResolution: Sendable {
  private enum State: Equatable {
    case pending
    case delivered
    case cancelled
    case timedOut
  }

  private let state = OSAllocatedUnfairLock(initialState: State.pending)

  var isCancellationClaimed: Bool {
    state.withLock { $0 == .cancelled }
  }

  func claimDelivery() -> Bool {
    claim(.delivered)
  }

  func claimCancellation() -> Bool {
    claim(.cancelled)
  }

  func claimTimeout() -> Bool {
    claim(.timedOut)
  }

  private func claim(_ terminalState: State) -> Bool {
    state.withLock { state in
      guard state == .pending else { return false }
      state = terminalState
      return true
    }
  }
}

@MainActor
package final class ActionQueue<Action: Sendable> {
  struct QueuedAction: Sendable {
    let action: Action
    let context: EffectExecutionContext?
  }

  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<QueuedAction?, Never>
    let timeoutTask: Task<Void, Never>?
    let resolution: ActionQueueWaiterResolution
  }

  private var buffer: [QueuedAction] = []
  private var headIndex = 0
  // Waiters intentionally use an ordered array instead of a dictionary so
  // resumption is FIFO. The previous dictionary-based implementation woke
  // an arbitrary waiter via `waiters.keys.first`, which made multi-waiter
  // test scenarios non-deterministic across runs.
  private var waiters: [Waiter] = []

  package var pendingWaiterCount: Int {
    waiters.count
  }

  func forEachBuffered(_ body: (QueuedAction) -> Void) {
    guard headIndex < buffer.count else { return }
    for index in headIndex..<buffer.count {
      body(buffer[index])
    }
  }

  // Internal diagnostics hook for verifying forwarded wait budgets without
  // coupling tests to scheduler-dependent wall-clock completion thresholds.
  var waitTimeoutObserver: ((Duration) -> Void)?

  func enqueue(_ action: Action, context: EffectExecutionContext?) {
    let queuedAction = QueuedAction(action: action, context: context)
    while !waiters.isEmpty {
      let head = waiters.removeFirst()
      head.timeoutTask?.cancel()
      guard head.resolution.claimDelivery() else {
        head.continuation.resume(returning: nil)
        continue
      }
      head.continuation.resume(returning: queuedAction)
      return
    }

    buffer.append(queuedAction)
  }

  func next(timeout: Duration) async -> QueuedAction? {
    if headIndex < buffer.count {
      let queuedAction = buffer[headIndex]
      headIndex += 1
      compactBufferIfNeeded()
      return queuedAction
    }

    waitTimeoutObserver?(timeout)

    let waiterID = UUID()
    let resolution = ActionQueueWaiterResolution()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !resolution.isCancellationClaimed else {
          continuation.resume(returning: nil)
          return
        }

        let timeoutTask = Task { @MainActor [weak self] in
          try? await Task.sleep(for: timeout)
          guard !Task.isCancelled else { return }
          guard resolution.claimTimeout() else { return }
          self?.resolveWaiter(id: waiterID, returning: nil)
        }
        waiters.append(
          Waiter(
            id: waiterID,
            continuation: continuation,
            timeoutTask: timeoutTask,
            resolution: resolution
          )
        )
      }
    } onCancel: {
      guard resolution.claimCancellation() else { return }
      Task { @MainActor [weak self] in
        self?.resolveWaiter(id: waiterID, returning: nil)
      }
    }
  }

  func popBuffered() -> QueuedAction? {
    guard headIndex < buffer.count else { return nil }
    let queuedAction = buffer[headIndex]
    headIndex += 1
    compactBufferIfNeeded()
    return queuedAction
  }

  private func resolveWaiter(id waiterID: UUID, returning queuedAction: QueuedAction?) {
    guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
    let waiter = waiters.remove(at: index)
    waiter.timeoutTask?.cancel()
    waiter.continuation.resume(returning: queuedAction)
  }

  private func compactBufferIfNeeded() {
    guard headIndex > 0 else { return }
    if headIndex == buffer.count {
      buffer.removeAll(keepingCapacity: true)
      headIndex = 0
    } else if headIndex >= 64, headIndex * 2 >= buffer.count {
      buffer.removeFirst(headIndex)
      headIndex = 0
    }
  }
}

@MainActor
private final class TestStoreRunEndpoint<Action: Sendable> {
  private let isTaskActiveImpl: (UUID) -> Bool
  private let shouldProceedImpl: (EffectExecutionContext?) -> Bool
  private let didEnqueueActionImpl: () -> Void
  private let reportRunFailureImpl: (String, EffectOrigin?) -> Void
  private let finishTrackedTaskImpl: (UUID) -> Void

  init(
    isTaskActive: @escaping (UUID) -> Bool,
    shouldProceed: @escaping (EffectExecutionContext?) -> Bool,
    didEnqueueAction: @escaping () -> Void,
    reportRunFailure: @escaping (String, EffectOrigin?) -> Void,
    finishTrackedTask: @escaping (UUID) -> Void
  ) {
    self.isTaskActiveImpl = isTaskActive
    self.shouldProceedImpl = shouldProceed
    self.didEnqueueActionImpl = didEnqueueAction
    self.reportRunFailureImpl = reportRunFailure
    self.finishTrackedTaskImpl = finishTrackedTask
  }

  func isTaskActive(token: UUID) -> Bool {
    isTaskActiveImpl(token)
  }

  func shouldProceed(context: EffectExecutionContext?) -> Bool {
    shouldProceedImpl(context)
  }

  func didEnqueueAction() {
    didEnqueueActionImpl()
  }

  func reportRunFailure(
    _ message: String,
    origin: EffectOrigin?,
    token: UUID,
    context: EffectExecutionContext?
  ) {
    guard isTaskActiveImpl(token), shouldProceedImpl(context) else { return }
    reportRunFailureImpl(message, origin)
  }

  func finishTrackedTask(token: UUID) {
    finishTrackedTaskImpl(token)
  }
}

private actor TestStoreRunBridge<Action: Sendable> {
  private let endpoint: TestStoreRunEndpoint<Action>
  private let queue: ActionQueue<Action>
  private let token: UUID
  private let context: EffectExecutionContext?

  init(
    endpoint: TestStoreRunEndpoint<Action>,
    queue: ActionQueue<Action>,
    token: UUID,
    context: EffectExecutionContext?
  ) {
    self.endpoint = endpoint
    self.queue = queue
    self.token = token
    self.context = context
  }

  func emit(_ action: Action) async {
    guard await endpoint.isTaskActive(token: token) else { return }
    guard await endpoint.shouldProceed(context: context) else { return }
    await queue.enqueue(action, context: context)
    await endpoint.didEnqueueAction()
  }

  func finish() async {
    await endpoint.finishTrackedTask(token: token)
  }
}

private actor TestStoreRunStartGate {
  private var isOpen = false
  private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

  func wait() async -> Bool {
    guard isOpen == false else { return true }
    let waiterID = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        waiters[waiterID] = continuation
      }
    } onCancel: {
      Task {
        await self.cancelWaiter(waiterID)
      }
    }
  }

  func open() {
    guard isOpen == false else { return }
    isOpen = true
    let continuations = waiters
    waiters.removeAll()
    for continuation in continuations.values {
      continuation.resume(returning: true)
    }
  }

  private func cancelWaiter(_ waiterID: UUID) {
    guard let continuation = waiters.removeValue(forKey: waiterID) else { return }
    continuation.resume(returning: false)
  }
}

extension TestStore {
  // MARK: - Task Management

  private func trackEffectTask(
    token: UUID,
    task: Task<Void, Never>,
    context: EffectExecutionContext?
  ) {
    runningTasks[token] = .init(
      task: task,
      sequence: context?.sequence ?? 0
    )
    for id in Set(context?.cancellationIDs ?? []) {
      taskIDsByEffectID[id, default: []].insert(token)
    }
  }

  private func refreshTrackedTask(
    token: UUID,
    context: EffectExecutionContext?
  ) {
    guard let trackedTask = runningTasks[token] else { return }
    removeTaskIDIndexes(token: token)
    runningTasks[token] = .init(
      task: trackedTask.task,
      sequence: context?.sequence ?? 0
    )
    for id in Set(context?.cancellationIDs ?? []) {
      taskIDsByEffectID[id, default: []].insert(token)
    }
  }

  private func nextDebounceGeneration() -> UInt64 {
    nextDebounceGenerationValue &+= 1
    return nextDebounceGenerationValue
  }

  private func beginDebounce(_ scope: DelayedEffectScope) -> UInt64? {
    if let trackedTask = debounceTasksByID[scope.ownerID] {
      guard shouldAdmitDelayedScope(scope, replacing: trackedTask.scope) else {
        return nil
      }
      trackedTask.task?.cancel()
    }

    let generation = nextDebounceGeneration()
    debounceTasksByID[scope.ownerID] = .init(
      task: nil,
      scope: scope,
      generation: generation
    )
    return generation
  }

  @discardableResult
  private func setDebounceTask(
    _ task: Task<Void, Never>,
    for id: AnyEffectID,
    generation: UInt64
  ) -> Bool {
    guard let trackedTask = debounceTasksByID[id], trackedTask.generation == generation else {
      task.cancel()
      return false
    }
    trackedTask.task?.cancel()
    debounceTasksByID[id] = .init(
      task: task,
      scope: trackedTask.scope,
      generation: generation
    )
    return true
  }

  @discardableResult
  private func finishDebounceTask(for id: AnyEffectID, generation: UInt64) -> Bool {
    guard debounceTasksByID[id]?.generation == generation else { return false }
    debounceTasksByID.removeValue(forKey: id)
    return true
  }

  private func cancelDebounceTasks(
    where shouldCancel: (DelayedEffectScope) -> Bool
  ) {
    for (id, trackedTask) in Array(debounceTasksByID) {
      guard shouldCancel(trackedTask.scope) else { continue }
      debounceTasksByID.removeValue(forKey: id)?.task?.cancel()
    }
  }

  private func makeRunEndpoint() -> TestStoreRunEndpoint<R.Action> {
    TestStoreRunEndpoint(
      isTaskActive: { [weak self] token in
        self?.isRunTaskActive(token: token) ?? false
      },
      shouldProceed: { [weak self] context in
        self?.shouldProceed(context: context) ?? false
      },
      didEnqueueAction: { [weak self] in
        self?.finishActivity.noteProgress()
      },
      reportRunFailure: { [weak self] message, origin in
        guard let self else { return }
        let source =
          origin.map { ($0.file, $0.line) }
          ?? self.terminalVerificationSource
          ?? (#file, #line)
        self.assertionFailureReporter(message, source.0, source.1)
      },
      finishTrackedTask: { [weak self] token in
        self?.finishTrackedRunTask(token: token)
      }
    )
  }

  private func startRunTask(
    priority: TaskPriority?,
    operation: @escaping @Sendable (Send<R.Action>, EffectContext) async -> Void,
    context: EffectExecutionContext?
  ) -> Task<Void, Never> {
    let token = UUID()
    beginFinishActivity(.run, token: token, context: context)
    let startGate = TestStoreRunStartGate()
    let endpoint = makeRunEndpoint()
    let runFailureLatch = RunFailureLatch()
    let runBridge = TestStoreRunBridge(
      endpoint: endpoint,
      queue: queue,
      token: token,
      context: context
    )
    let manualClock = self.manualClock
    let wallClock = self.wallClock

    let task = Task(priority: priority) {
      guard await startGate.wait() else {
        await runBridge.finish()
        return
      }
      let canStart = await MainActor.run {
        endpoint.isTaskActive(token: token)
          && endpoint.shouldProceed(context: context)
      }
      guard !Task.isCancelled, canStart else {
        await runBridge.finish()
        return
      }

      let send = Send<R.Action> { action in
        await runBridge.emit(action)
      }

      let checkCancellation: @Sendable () async throws -> Void = {
        let canContinue = await MainActor.run {
          endpoint.isTaskActive(token: token)
            && endpoint.shouldProceed(context: context)
        }
        if Task.isCancelled || canContinue == false {
          throw CancellationError()
        }
      }

      let effectContext = EffectContext(
        now: {
          if let manualClock {
            return await manualClock.now
          }
          return wallClock.now
        },
        sleep: { duration in
          if let manualClock {
            try await manualClock.sleep(for: duration)
          } else {
            try await Task.sleep(for: duration)
          }
        },
        isCancellationRequested: {
          do {
            try await checkCancellation()
            return false
          } catch {
            return true
          }
        },
        checkCancellation: checkCancellation,
        reportError: { error in
          guard runFailureLatch.setIfUnset() else { return }
          let errorTypeName = String(describing: type(of: error))
          let errorDescription = String(describing: error)
          await endpoint.reportRunFailure(
            """
            EffectTask.run failed with an unhandled error.

            Error type: \(errorTypeName)
            Error: \(errorDescription)

            Handle expected errors inside the effect or convert them into actions that the reducer can verify.
            """,
            origin: context?.origin,
            token: token,
            context: context
          )
        }
      )

      await operation(send, effectContext)
      await runBridge.finish()
    }

    trackEffectTask(token: token, task: task, context: context)

    Task { @MainActor in
      await startGate.open()
    }

    return task
  }

  package func cancelEffectsSynchronously(
    identifiedBy id: AnyEffectID,
    upTo sequence: UInt64
  ) {
    cancelDebounceTasks { scope in
      scope.contains(id)
        && (scope.sequence <= sequence
          || shouldStart(sequence: scope.sequence, cancellationID: id) == false)
    }
    throttleState.clearStates { scope in
      scope.contains(id)
        && (scope.sequence <= sequence
          || shouldStart(sequence: scope.sequence, cancellationID: id) == false)
    }
    guard let tokens = taskIDsByEffectID[id] else { return }

    for token in Array(tokens) {
      guard let trackedTask = runningTasks[token] else {
        removeTrackedTask(token: token)
        continue
      }
      let isPastBoundary =
        trackedTask.sequence <= sequence
        || shouldStart(sequence: trackedTask.sequence, cancellationID: id) == false
      guard isPastBoundary else { continue }
      trackedTask.task.cancel()
      removeTrackedTask(token: token)
    }
  }

  package func cancelAllEffectsSynchronously(upTo sequence: UInt64) {
    let tokens = runningTasks.compactMap { token, trackedTask in
      let isPastBoundary =
        trackedTask.sequence <= sequence
        || shouldStart(sequence: trackedTask.sequence, cancellationIDs: []) == false
      return isPastBoundary ? token : nil
    }
    for token in tokens {
      runningTasks[token]?.task.cancel()
      removeTrackedTask(token: token)
    }
    cancelDebounceTasks { scope in
      scope.sequence <= sequence
        || shouldStart(sequence: scope.sequence, cancellationIDs: []) == false
    }
    throttleState.clearStates { scope in
      scope.sequence <= sequence
        || shouldStart(sequence: scope.sequence, cancellationIDs: []) == false
    }
  }

  private func removeTrackedTask(token: UUID) {
    runningTasks.removeValue(forKey: token)
    removeTaskIDIndexes(token: token)

    for id in Array(throttleActivityTokenByID.keys)
    where throttleActivityTokenByID[id] == token {
      throttleActivityTokenByID.removeValue(forKey: id)
    }
  }

  private func removeTaskIDIndexes(token: UUID) {
    for id in Array(taskIDsByEffectID.keys) {
      guard var tokens = taskIDsByEffectID[id] else { continue }
      tokens.remove(token)
      if tokens.isEmpty {
        taskIDsByEffectID.removeValue(forKey: id)
      } else {
        taskIDsByEffectID[id] = tokens
      }
    }
  }

  // MARK: - Receiving

  package func nextActionWithinTimeout() async -> R.Action? {
    let queue = self.queue
    while let queuedAction = await queue.next(timeout: effectTimeout) {
      guard shouldProceed(context: queuedAction.context) else { continue }
      return queuedAction.action
    }
    return nil
  }

  package func popBufferedAction() async -> R.Action? {
    while let queuedAction = queue.popBuffered() {
      guard shouldProceed(context: queuedAction.context) else { continue }
      return queuedAction.action
    }
    return nil
  }

  private func isRunTaskActive(token: UUID) -> Bool {
    runningTasks[token] != nil
  }

  private func finishTrackedRunTask(token: UUID) {
    removeTrackedTask(token: token)
    finishActivity.end(token)
  }

}

// MARK: - EffectDriver Conformance

extension TestStore: EffectDriver {
  package typealias Action = R.Action

  package func deliverAction(_ action: R.Action, context: EffectExecutionContext?) {
    // BREAKING (InnoFlow 4.0.0): deliverAction now enqueues synchronously on
    // the MainActor, matching Store's enqueue contract exactly. Previously
    // each delivery hopped through a fire-and-forget `Task { @MainActor }`,
    // which let actions interleave with subsequent reducer ticks in
    // non-deterministic ways. Test fixtures that relied on that latency
    // (e.g. asserting an intermediate state between two scheduled
    // deliveries) must move the assertion to before the action that would
    // have raced ahead.
    guard shouldProceed(context: context) else { return }
    noteUnverifiedWorkAfterTerminalVerification()
    queue.enqueue(action, context: context)
    finishActivity.noteProgress()
  }

  package func reportActionDrop(
    _ action: R.Action,
    reason: ActionDropReason,
    context: EffectExecutionContext?
  ) {
    // TestStore observes assertion failures via DEBUG `assertionFailure` at the
    // composition site; the diagnostic effect itself is a no-op here so test
    // expectations stay deterministic.
  }

  @discardableResult
  package func startRun(
    priority: TaskPriority?,
    operation: @escaping @Sendable (Send<R.Action>, EffectContext) async -> Void,
    context: EffectExecutionContext?
  ) async -> Task<Void, Never> {
    startRunTask(
      priority: priority,
      operation: operation,
      context: context
    )
  }

  package func cancelEffects(id: AnyEffectID, context: EffectExecutionContext?) async {
    let sequence = markCancelled(id: id, upTo: context?.sequence)
    cancelEffectsSynchronously(identifiedBy: id, upTo: sequence)
  }

  package func cancelInFlightEffects(id: AnyEffectID, context: EffectExecutionContext?) async {
    let sequence = markCancelledInFlight(id: id, upTo: context?.sequence)
    cancelEffectsSynchronously(identifiedBy: id, upTo: sequence)
  }

  package func shouldProceed(context: EffectExecutionContext?) -> Bool {
    guard let sequence = context?.sequence else { return true }
    return shouldStart(sequence: sequence, cancellationIDs: context?.cancellationIDs ?? [])
  }

  @discardableResult
  package func scheduleDebounce(
    _ nested: EffectTask<R.Action>,
    id: AnyEffectID,
    interval: Duration,
    context: EffectExecutionContext?,
    scope: DelayedEffectScope,
    nestedAwaited: Bool,
    recurse:
      @escaping @MainActor @Sendable (
        EffectTask<R.Action>, EffectExecutionContext?, Bool
      ) async -> Void
  ) async -> Task<Void, Never>? {
    let sequence = markCancelledInFlight(id: id, upTo: context?.sequence)
    cancelEffectsSynchronously(identifiedBy: id, upTo: sequence)

    guard shouldProceed(context: context) else { return nil }

    guard let generation = beginDebounce(scope) else { return nil }
    let delayClock = manualClock.map { StoreClock.manual($0) } ?? .continuous
    let activityToken = UUID()
    beginFinishActivity(.debounce, token: activityToken, context: context)
    let endpoint = makeRunEndpoint()

    let task = Task { [weak self] in
      let didFinishDelay: Bool
      do {
        try await delayClock.sleep(interval)
        didFinishDelay = true
      } catch {
        _ = await MainActor.run {
          self?.finishDebounceTask(for: id, generation: generation)
        }
        didFinishDelay = false
      }

      if didFinishDelay {
        let shouldRun = await MainActor.run { [weak self] in
          guard let self else { return false }
          guard !Task.isCancelled else { return false }
          guard self.debounceTasksByID[id]?.generation == generation else { return false }
          defer {
            self.finishDebounceTask(for: id, generation: generation)
          }
          return self.shouldProceed(context: context)
        }

        if shouldRun {
          await recurse(nested, context, nestedAwaited)
        }
      }

      endpoint.finishTrackedTask(token: activityToken)
    }

    guard setDebounceTask(task, for: id, generation: generation) else {
      return nil
    }
    trackEffectTask(token: activityToken, task: task, context: context)
    return task
  }

  @discardableResult
  package func scheduleTrailingDrain(
    for id: AnyEffectID,
    interval: Duration,
    schedulingContext: EffectExecutionContext,
    awaited: Bool,
    recurse:
      @escaping @MainActor @Sendable (
        EffectTask<R.Action>, EffectExecutionContext?, Bool
      ) async -> Void
  ) -> Task<Void, Never> {
    throttleState.cancelTrailingTask(for: id)
    let generation = throttleState.nextGeneration(for: id)
    let delayClock = manualClock.map { StoreClock.manual($0) } ?? .continuous
    let activityToken = UUID()
    beginFinishActivity(
      .throttle,
      token: activityToken,
      context: schedulingContext
    )
    let endpoint = makeRunEndpoint()
    let task = Task { [weak self] in
      let pending: ThrottleStateMap<R.Action>.PendingTrailing?
      do {
        try await delayClock.sleep(interval)
        pending = await MainActor.run { [weak self] in
          guard let self else { return nil }
          guard self.throttleState.generation(for: id) == generation else { return nil }
          defer {
            if self.throttleState.generation(for: id) == generation {
              self.throttleState.finishState(for: id, generation: generation)
            }
          }
          guard let pending = self.throttleState.pending(for: id) else { return nil }
          guard self.shouldProceed(context: pending.context) else { return nil }
          return pending
        }
      } catch {
        await MainActor.run {
          guard let self else { return }
          if self.throttleState.generation(for: id) == generation {
            self.throttleState.finishState(for: id, generation: generation)
          }
        }
        pending = nil
      }

      if let pending {
        await recurse(
          pending.effect,
          pending.context,
          awaited || pending.requiresAwaitedCompletion
        )
      }

      endpoint.finishTrackedTask(token: activityToken)
    }
    throttleState.setTrailingTask(task, for: id)
    throttleActivityTokenByID[id] = activityToken
    trackEffectTask(token: activityToken, task: task, context: schedulingContext)
    return task
  }

  package func refreshTrailingDrainOwnership(
    for id: AnyEffectID,
    context: EffectExecutionContext
  ) {
    guard let token = throttleActivityTokenByID[id] else { return }
    guard runningTasks[token] != nil else {
      throttleActivityTokenByID.removeValue(forKey: id)
      return
    }
    refreshTrackedTask(token: token, context: context)
  }

  package var now: ContinuousClock.Instant {
    get async {
      if let manualClock {
        return await manualClock.now
      }
      return wallClock.now
    }
  }

  package func runConcurrently(
    _ children: [EffectTask<R.Action>],
    context: EffectExecutionContext?,
    awaited: Bool,
    recurse:
      @escaping @MainActor @Sendable (
        EffectTask<R.Action>, EffectExecutionContext?, Bool
      ) async -> Void
  ) async {
    if awaited {
      await withTaskGroup(of: Void.self) { group in
        for child in children {
          group.addTask {
            await recurse(child, context, true)
          }
        }
        await group.waitForAll()
      }
    } else {
      for child in children {
        let token = UUID()
        beginFinishActivity(.composite, token: token, context: context)
        let task = Task { @MainActor [weak self] in
          defer {
            self?.finishTrackedRunTask(token: token)
          }
          guard self != nil else { return }
          await recurse(child, context, false)
        }
        // Track unawaited concurrent children so cancelAllEffectsSynchronously
        // can reach them. Without this, fire-and-forget Tasks here would
        // outlive their owning TestStore drain and break the assertion that
        // cancellation reliably winds the entire effect tree down — a
        // divergence from the Store path that this commit closes.
        trackEffectTask(token: token, task: task, context: context)
      }
    }
  }

  package func runSequentially(
    _ children: [EffectTask<R.Action>],
    context: EffectExecutionContext?,
    awaited: Bool,
    recurse:
      @escaping @MainActor @Sendable (
        EffectTask<R.Action>, EffectExecutionContext?, Bool
      ) async -> Void
  ) async {
    if awaited {
      for child in children {
        await recurse(child, context, true)
      }
    } else {
      let token = UUID()
      beginFinishActivity(.composite, token: token, context: context)
      let startGate = TestStoreRunStartGate()
      let endpoint = makeRunEndpoint()
      let task = Task { @MainActor in
        defer {
          endpoint.finishTrackedTask(token: token)
        }
        guard await startGate.wait() else {
          return
        }
        for child in children {
          guard !Task.isCancelled else { break }
          guard endpoint.isTaskActive(token: token) else { break }
          guard endpoint.shouldProceed(context: context) else { break }
          await recurse(child, context, true)
        }
      }
      trackEffectTask(token: token, task: task, context: context)
      Task { @MainActor in
        await startGate.open()
      }
    }
  }
}
