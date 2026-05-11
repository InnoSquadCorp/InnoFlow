// MARK: - TestStore+EffectDriver.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
package import InnoFlowCore

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

  func enqueue(_ action: Action, context: EffectExecutionContext?) {
    let queuedAction = QueuedAction(action: action, context: context)
    if !waiters.isEmpty {
      let head = waiters.removeFirst()
      head.timeoutTask?.cancel()
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

    let waiterID = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let timeoutTask = Task { @MainActor [weak self] in
          try? await Task.sleep(for: timeout)
          guard !Task.isCancelled else { return }
          self?.resolveWaiter(id: waiterID, returning: nil)
        }
        waiters.append(
          Waiter(id: waiterID, continuation: continuation, timeoutTask: timeoutTask)
        )
      }
    } onCancel: {
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
  private let finishTrackedTaskImpl: (UUID) -> Void

  init(
    isTaskActive: @escaping (UUID) -> Bool,
    shouldProceed: @escaping (EffectExecutionContext?) -> Bool,
    finishTrackedTask: @escaping (UUID) -> Void
  ) {
    self.isTaskActiveImpl = isTaskActive
    self.shouldProceedImpl = shouldProceed
    self.finishTrackedTaskImpl = finishTrackedTask
  }

  func isTaskActive(token: UUID) -> Bool {
    isTaskActiveImpl(token)
  }

  func shouldProceed(context: EffectExecutionContext?) -> Bool {
    shouldProceedImpl(context)
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

  private func startRunTask(
    priority: TaskPriority?,
    operation: @escaping @Sendable (Send<R.Action>, EffectContext) async -> Void,
    context: EffectExecutionContext?
  ) -> Task<Void, Never> {
    let token = UUID()
    let startGate = TestStoreRunStartGate()
    let endpoint = TestStoreRunEndpoint<R.Action>(
      isTaskActive: { [weak self] token in
        self?.isRunTaskActive(token: token) ?? false
      },
      shouldProceed: { [weak self] context in
        self?.shouldProceed(context: context) ?? false
      },
      finishTrackedTask: { [weak self] token in
        self?.finishTrackedRunTask(token: token)
      }
    )
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
        checkCancellation: checkCancellation
      )

      await operation(send, effectContext)
      await runBridge.finish()
    }

    runningTasks[token] = task

    let uniqueIDs = Set(context?.cancellationIDs ?? [])
    for id in uniqueIDs {
      taskIDsByEffectID[id, default: []].insert(token)
    }

    Task { @MainActor in
      await startGate.open()
    }

    return task
  }

  package func cancelEffectsSynchronously(identifiedBy id: AnyEffectID) {
    debounceDelayTasksByID.removeValue(forKey: id)?.cancel()
    debounceGenerationByID.removeValue(forKey: id)
    throttleState.clearState(for: id)
    guard let ids = taskIDsByEffectID.removeValue(forKey: id) else { return }

    for token in ids {
      runningTasks.removeValue(forKey: token)?.cancel()
      removeTrackedTask(token: token)
    }
  }

  package func cancelAllEffectsSynchronously() {
    for task in runningTasks.values {
      task.cancel()
    }
    for task in debounceDelayTasksByID.values {
      task.cancel()
    }
    throttleState.clearAll()
    runningTasks.removeAll()
    taskIDsByEffectID.removeAll()
    debounceDelayTasksByID.removeAll()
    debounceGenerationByID.removeAll()
  }

  private func removeTrackedTask(token: UUID) {
    runningTasks.removeValue(forKey: token)

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
  }

  private func sleepForDriver(_ duration: Duration) async throws {
    if let manualClock {
      try await manualClock.sleep(for: duration)
    } else {
      try await Task.sleep(for: duration)
    }
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
    queue.enqueue(action, context: context)
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

  package func startRun(
    priority: TaskPriority?,
    operation: @escaping @Sendable (Send<R.Action>, EffectContext) async -> Void,
    context: EffectExecutionContext?,
    awaited: Bool
  ) async {
    let task = startRunTask(
      priority: priority,
      operation: operation,
      context: context
    )

    if awaited {
      _ = await task.result
    }
  }

  package func cancelEffects(id: AnyEffectID, context: EffectExecutionContext?) async {
    markCancelled(id: id, upTo: context?.sequence)
    cancelEffectsSynchronously(identifiedBy: id)
  }

  package func cancelInFlightEffects(id: AnyEffectID, context: EffectExecutionContext?) async {
    markCancelledInFlight(id: id, upTo: context?.sequence)
    cancelEffectsSynchronously(identifiedBy: id)
  }

  package func shouldProceed(context: EffectExecutionContext?) -> Bool {
    guard let sequence = context?.sequence else { return true }
    return shouldStart(sequence: sequence, cancellationIDs: context?.cancellationIDs ?? [])
  }

  package func debounce(
    _ nested: EffectTask<R.Action>,
    id: AnyEffectID,
    interval: Duration,
    context: EffectExecutionContext?,
    awaited: Bool,
    recurse:
      @escaping @MainActor @Sendable (
        EffectTask<R.Action>, EffectExecutionContext?, Bool
      ) async -> Void
  ) async {
    debounceDelayTasksByID[id]?.cancel()
    markCancelledInFlight(id: id, upTo: context?.sequence)
    cancelEffectsSynchronously(identifiedBy: id)

    let generation = UUID()
    debounceGenerationByID[id] = generation

    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if self.debounceGenerationByID[id] == generation {
          self.debounceDelayTasksByID.removeValue(forKey: id)
          self.debounceGenerationByID.removeValue(forKey: id)
        }
      }

      do {
        try await self.sleepForDriver(interval)
      } catch {
        return
      }

      guard !Task.isCancelled else { return }
      guard self.debounceGenerationByID[id] == generation else { return }
      guard self.shouldProceed(context: context) else { return }
      await recurse(nested, context, true)
    }

    debounceDelayTasksByID[id] = task

    if awaited {
      _ = await task.result
    }
  }

  package func scheduleTrailingDrain(
    for id: AnyEffectID,
    interval: Duration,
    recurse:
      @escaping @MainActor @Sendable (
        EffectTask<R.Action>, EffectExecutionContext?, Bool
      ) async -> Void
  ) {
    throttleState.cancelTrailingTask(for: id)
    let generation = throttleState.nextGeneration(for: id)
    let task = Task { [weak self] in
      guard let self else { return }
      do {
        try await self.sleepForDriver(interval)
      } catch {
        return
      }
      guard self.throttleState.generation(for: id) == generation else { return }
      defer {
        if self.throttleState.generation(for: id) == generation {
          self.throttleState.clearState(for: id)
        }
      }
      guard let pending = self.throttleState.pending(for: id) else { return }
      guard self.shouldProceed(context: pending.context) else { return }
      await recurse(pending.effect, pending.context, false)
    }
    throttleState.setTrailingTask(task, for: id)
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
      let uniqueCancellationIDs = Set(context?.cancellationIDs ?? [])
      for child in children {
        let token = UUID()
        let task = Task { @MainActor [weak self] in
          defer {
            self?.removeTrackedTask(token: token)
          }
          guard self != nil else { return }
          await recurse(child, context, false)
        }
        // Track unawaited concurrent children so cancelAllEffectsSynchronously
        // can reach them. Without this, fire-and-forget Tasks here would
        // outlive their owning TestStore drain and break the assertion that
        // cancellation reliably winds the entire effect tree down — a
        // divergence from the Store path that this commit closes.
        runningTasks[token] = task
        for id in uniqueCancellationIDs {
          taskIDsByEffectID[id, default: []].insert(token)
        }
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
      let cancellationIDs = context?.cancellationIDs ?? []
      let startGate = TestStoreRunStartGate()
      let task = Task { @MainActor [weak self] in
        guard await startGate.wait() else {
          return
        }
        guard let self else { return }
        defer {
          self.removeTrackedTask(token: token)
        }
        for child in children {
          guard !Task.isCancelled else { break }
          guard self.shouldProceed(context: context) else { break }
          await recurse(child, context, true)
        }
      }
      runningTasks[token] = task
      for id in Set(cancellationIDs) {
        taskIDsByEffectID[id, default: []].insert(token)
      }
      Task { @MainActor in
        await startGate.open()
      }
    }
  }
}
