// MARK: - TestStore+EffectLifecycle.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
package import InnoFlowCore

extension TestStore {
  // MARK: - Task Management

  func trackEffectTask(
    token: UUID,
    task: Task<Void, Never>,
    context: EffectExecutionContext?
  ) {
    runningTasks[token] = .init(
      task: task,
      context: context
    )
    for id in Set(context?.cancellationIDs ?? []) {
      taskIDsByEffectID[id, default: []].insert(token)
    }
  }

  func refreshTrackedTask(
    token: UUID,
    context: EffectExecutionContext?
  ) {
    guard let trackedTask = runningTasks[token] else { return }
    removeTaskIDIndexes(token: token)
    runningTasks[token] = .init(
      task: trackedTask.task,
      context: context?.frozenForExecution()
    )
    for id in Set(context?.cancellationIDs ?? []) {
      taskIDsByEffectID[id, default: []].insert(token)
    }
  }

  private func nextDebounceGeneration() -> UInt64 {
    nextDebounceGenerationValue &+= 1
    return nextDebounceGenerationValue
  }

  func beginDebounce(_ scope: DelayedEffectScope) -> UInt64? {
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
  func setDebounceTask(
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
  func finishDebounceTask(for id: AnyEffectID, generation: UInt64) -> Bool {
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

  func makeRunEndpoint() -> TestStoreRunEndpoint<R.Action> {
    TestStoreRunEndpoint(
      isTaskActive: { [weak self] token in
        self?.isRunTaskActive(token: token) ?? false
      },
      shouldProceed: { [weak self] context in
        self?.shouldProceed(context: context) ?? false
      },
      didStartRun: { [weak self] context in
        self?.recordEffectEvent(.started, context: context)
      },
      didEnqueueAction: { [weak self] in
        self?.noteUnverifiedWorkAfterTerminalVerification()
        self?.finishActivity.noteProgress()
      },
      reportRunFailure: { [weak self] message, origin, context in
        guard let self else { return }
        self.recordEffectEvent(.failed(message), context: context)
        let source =
          origin.map(TestStoreSourceLocation.init)
          ?? self.terminalVerificationSource
          ?? .init()
        self.issueReporter(message, source)
      },
      finishTrackedTask: { [weak self] token in
        self?.finishTrackedRunTask(token: token)
      }
    )
  }

  func startRunTask(
    priority: TaskPriority?,
    operation: @escaping @Sendable (Send<R.Action>, EffectContext) async -> Void,
    context: EffectExecutionContext?
  ) -> Task<Void, Never> {
    let context = context?.frozenForExecution()
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

    let dispatchActivity = (context?.flowTaskTracker).map(TestStoreDispatchActivity.init)
    let task = Task(priority: priority) {
      defer { dispatchActivity?.finish() }
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
      endpoint.didStartRun(context: context)

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

    dispatchActivity?.attach(task)
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
    runScheduler.cancel(id: id, upTo: sequence)
    cancelDebounceTasks { scope in
      scope.contains(id)
        && (scope.sequence <= sequence
          || scope.shouldProceed == false)
    }
    throttleState.clearStates { scope in
      scope.contains(id)
        && (scope.sequence <= sequence
          || scope.shouldProceed == false)
    }
    guard let tokens = taskIDsByEffectID[id] else { return }

    for token in Array(tokens) {
      guard let trackedTask = runningTasks[token] else {
        removeTrackedTask(token: token)
        continue
      }
      let isPastBoundary =
        (trackedTask.context?.sequence ?? 0) <= sequence
        || trackedTask.context?.isCancelled(id: id) == true
      guard isPastBoundary else { continue }
      trackedTask.task.cancel()
      markTrackedTaskCancelled(token: token)
    }
  }

  package func cancelAllEffectsSynchronously(upTo sequence: UInt64) {
    runScheduler.cancelAll(upTo: sequence)
    let tokens = runningTasks.compactMap { token, trackedTask in
      let isPastBoundary =
        (trackedTask.context?.sequence ?? 0) <= sequence
        || trackedTask.context?.shouldProceed == false
      return isPastBoundary ? token : nil
    }
    for token in tokens {
      runningTasks[token]?.task.cancel()
      markTrackedTaskCancelled(token: token)
    }
    cancelDebounceTasks { scope in
      scope.sequence <= sequence
        || scope.shouldProceed == false
    }
    throttleState.clearStates { scope in
      scope.sequence <= sequence
        || scope.shouldProceed == false
    }
  }

  private func markTrackedTaskCancelled(token: UUID) {
    // Cancellation closes delivery immediately, while the task remains in the
    // physical registry until its completion callback actually arrives.
    guard cancelledTaskTokens.insert(token).inserted else { return }
    recordEffectEvent(.cancelled(.effect), context: runningTasks[token]?.context)
    removeTaskIDIndexes(token: token)
    for id in Array(throttleActivityTokenByID.keys)
    where throttleActivityTokenByID[id] == token {
      throttleActivityTokenByID.removeValue(forKey: id)
    }
  }

  private func removeTrackedTask(token: UUID) {
    cancelledTaskTokens.remove(token)
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

  package func popBufferedQueuedAction() -> ActionQueue<R.Action>.QueuedAction? {
    while let entry = queue.popBuffered() {
      guard shouldProceed(context: entry.context) else {
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
    queue.removeBuffered { !shouldProceed(context: $0.context) }
    outputQueue.removeBuffered { !shouldProceed(context: $0.context) }
    finishActivity.noteProgress()
  }

  private func isRunTaskActive(token: UUID) -> Bool {
    runningTasks[token] != nil && !cancelledTaskTokens.contains(token)
  }

  func finishTrackedRunTask(token: UUID) {
    removeTrackedTask(token: token)
    finishActivity.end(token)
  }
}
