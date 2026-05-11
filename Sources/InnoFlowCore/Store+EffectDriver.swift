import Foundation
import os

/// Latch that flips from `false` to `true` exactly once. Used to record that
/// `reportError` fired `didFailRun` during a run so the trailing
/// `didFinishRun` can be suppressed — the start/finish/fail/cancel contract is
/// 1:1 per run.
package final class SingleWriteFlag: Sendable {
  private let storage = OSAllocatedUnfairLock(initialState: false)

  package init() {}

  package func set() {
    storage.withLock { $0 = true }
  }

  /// Atomic compare-and-set: returns `true` if this call flipped the latch,
  /// `false` if the latch was already set. Lets callers implement
  /// first-writer-wins policies without a separate read+write race window.
  @discardableResult
  package func setIfUnset() -> Bool {
    storage.withLock { wasSet in
      if wasSet { return false }
      wasSet = true
      return true
    }
  }

  package var isSet: Bool {
    storage.withLock { $0 }
  }
}

extension Store: EffectDriver {
  package typealias Action = R.Action

  @discardableResult
  private func startCompositeTask(
    cancellationIDs: [AnyEffectID],
    operation: @escaping @MainActor @Sendable () async -> Void
  ) -> Task<Void, Never> {
    let token = UUID()
    let gate = RunStartGate()
    let bridge = effectBridge
    let task = Task { @MainActor in
      await gate.wait()
      defer {
        bridge.finishCompositeTask(token: token)
      }
      guard !Task.isCancelled else { return }
      await operation()
    }

    bridge.registerCompositeTask(token: token, ids: cancellationIDs, task: task)
    Task {
      await gate.open()
    }
    return task
  }

  package func deliverAction(_ action: R.Action, context: EffectExecutionContext?) {
    guard effectBridge.shouldProceed(context: context) else {
      recordDrop(action, reason: .cancellationBoundary, context: context)
      return
    }
    recordEmission(action, context: context)
    enqueue(action, animation: context?.animation)
  }

  package func reportActionDrop(
    _ action: R.Action,
    reason: ActionDropReason,
    context: EffectExecutionContext?
  ) {
    recordDrop(action, reason: reason, context: context)
  }

  package func startRun(
    priority: TaskPriority?,
    operation: @escaping @Sendable (Send<R.Action>, EffectContext) async -> Void,
    context: EffectExecutionContext?,
    awaited: Bool
  ) async {
    let sequence = context?.sequence ?? 0
    let token = UUID()
    let gate = RunStartGate()
    let runEvent = makeRunEvent(token: token, context: context)

    let runtime = effectBridge.runtime
    let instrumentation = self.instrumentation
    let clock = self.clock
    let lifetime = self.lifetime
    let task = Task(priority: priority) { [weak self] in
      await gate.wait()
      do {
        if lifetime.isReleased {
          throw CancellationError()
        }
        guard
          await runtime.canStartOperation(
            token: token,
            ids: context?.cancellationIDs ?? [],
            sequence: sequence
          )
        else {
          throw CancellationError()
        }
      } catch {
        // Run was cancelled before it could start. We never fired `didStartRun`,
        // so we deliberately do not fire `didFinishRun` either — the
        // start/finish pair stays balanced.
        await runtime.finish(token: token)
        return
      }

      instrumentation.didStartRun(runEvent)

      // Tracks whether `reportError` fired `didFailRun` during this run. The
      // start/finish/fail/cancel contract is 1:1 per run, so if the run
      // failed we must not also emit `didFinishRun` below.
      let runFailedBox = SingleWriteFlag()

      let send = Send<R.Action> { action in
        if lifetime.isReleased {
          instrumentation.didDropAction(
            .init(
              action: action,
              reason: .storeReleased,
              cancellationID: context?.cancellationID,
              sequence: sequence
            )
          )
          return
        }

        switch await runtime.emissionDecision(
          token: token,
          ids: context?.cancellationIDs ?? [],
          sequence: sequence
        ) {
        case .allow:
          break

        case .drop(let reason):
          instrumentation.didDropAction(
            .init(
              action: action,
              reason: reason,
              cancellationID: context?.cancellationID,
              sequence: sequence
            )
          )
          return
        }

        await MainActor.run {
          guard let self else {
            instrumentation.didDropAction(
              .init(
                action: action,
                reason: .storeReleased,
                cancellationID: context?.cancellationID,
                sequence: sequence
              )
            )
            return
          }

          if self.effectBridge.shouldProceed(context: context) {
            self.recordEmission(action, context: context)
            self.enqueue(action, animation: context?.animation)
          } else {
            self.recordDrop(action, reason: .cancellationBoundary, context: context)
          }
        }
      }

      let checkCancellation: @Sendable () async throws -> Void = {
        if lifetime.isReleased {
          throw CancellationError()
        }
        try await runtime.checkCancellation(
          token: token,
          ids: context?.cancellationIDs ?? [],
          sequence: sequence
        )
      }

      let effectContext = EffectContext(
        now: {
          await clock.now()
        },
        sleep: { duration in
          try await clock.sleep(duration)
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
          // First-error-wins: the start/finish/fail/cancel contract is 1:1
          // per run, so swallow any subsequent reportError calls instead of
          // fanning out duplicate didFailRun events.
          guard runFailedBox.setIfUnset() else { return }
          instrumentation.didFailRun(
            .init(
              token: token,
              cancellationID: context?.cancellationID,
              sequence: context?.sequence,
              errorDescription: String(describing: error),
              errorTypeName: String(describing: type(of: error))
            )
          )
        }
      )

      await operation(send, effectContext)
      await runtime.finish(token: token)
      if !runFailedBox.isSet {
        instrumentation.didFinishRun(runEvent)
      }
    }

    await runtime.registerAndStart(
      token: token,
      ids: context?.cancellationIDs ?? [],
      task: task,
      gate: gate
    )

    if awaited {
      _ = await task.result
    }
  }

  package func cancelEffects(id: AnyEffectID, context: EffectExecutionContext?) async {
    let sequence = effectBridge.markCancelled(id: id, upTo: context?.sequence)
    recordCancellation(id: id, sequence: sequence)
    await effectBridge.cancelEffects(id: id, upTo: sequence)
  }

  package func cancelInFlightEffects(id: AnyEffectID, context: EffectExecutionContext?) async {
    let sequence = effectBridge.markCancelledInFlight(id: id, upTo: context?.sequence)
    recordCancellation(id: id, sequence: sequence)
    await effectBridge.cancelInFlightEffects(id: id, upTo: sequence)
  }

  package func shouldProceed(context: EffectExecutionContext?) -> Bool {
    effectBridge.shouldProceed(context: context)
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
    await cancelInFlightEffects(id: id, context: context)
    let generation = effectBridge.nextDebounceGeneration(for: id)
    let clock = self.clock

    let task = Task { [weak self] in
      do {
        try await clock.sleep(interval)
      } catch {
        await MainActor.run {
          self?.recordDrop(nil, reason: .throttledOrDebouncedCancellation, context: context)
        }
        return
      }

      let shouldRun = await MainActor.run { [weak self] in
        guard let self else { return false }
        guard self.effectBridge.debounceGeneration(for: id) == generation else { return false }
        defer {
          self.effectBridge.finishDebounceState(for: id, generation: generation)
        }
        return self.shouldProceed(context: context)
      }

      guard shouldRun, let self else { return }
      await self.walkEffect(nested, context: context, awaited: awaited)
    }

    effectBridge.setDebounceDelayTask(task, for: id, generation: generation)

    if awaited {
      _ = await task.result
    }
  }

  package var throttleState: ThrottleStateMap<R.Action> {
    effectBridge.throttleState
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

    let clock = self.clock
    let task = Task { [weak self] in
      do {
        try await clock.sleep(interval)
      } catch {
        await MainActor.run {
          self?.recordDrop(nil, reason: .throttledOrDebouncedCancellation, context: nil)
        }
        return
      }

      let pending: ThrottleStateMap<R.Action>.PendingTrailing? =
        await MainActor.run { [weak self] in
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

      guard let pending, let self else { return }
      await self.walkEffect(pending.effect, context: pending.context, awaited: false)
    }

    throttleState.setTrailingTask(task, for: id)
  }

  package var now: ContinuousClock.Instant {
    get async {
      await clock.now()
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
      let bridge = effectBridge
      startCompositeTask(cancellationIDs: context?.cancellationIDs ?? []) {
        await withTaskGroup(of: Void.self) { group in
          for child in children {
            group.addTask {
              guard !Task.isCancelled else { return }
              guard await MainActor.run(body: { bridge.shouldProceed(context: context) }) else {
                return
              }
              await recurse(child, context, false)
            }
          }
          await group.waitForAll()
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
      let bridge = effectBridge
      startCompositeTask(cancellationIDs: context?.cancellationIDs ?? []) {
        for child in children {
          guard !Task.isCancelled else { return }
          guard bridge.shouldProceed(context: context) else { return }
          await recurse(child, context, true)
        }
      }
    }
  }
}
