// MARK: - TestStore+EffectDriver.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
package import InnoFlowCore

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
    context?.shouldProceed ?? true
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
    let schedulingContext = schedulingContext.frozenForExecution()
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
