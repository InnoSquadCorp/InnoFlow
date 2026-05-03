import Foundation

extension Store: EffectDriver {
  package typealias Action = R.Action

  package func deliverAction(_ action: R.Action, context: EffectExecutionContext?) {
    guard effectBridge.shouldProceed(context: context) else {
      recordDrop(action, reason: .cancellationBoundary, context: context)
      return
    }
    recordEmission(action, context: context)
    enqueue(action, animation: context?.animation)
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
    instrumentation.didStartRun(runEvent)

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
            id: context?.cancellationID,
            sequence: sequence
          )
        else {
          throw CancellationError()
        }
      } catch {
        await runtime.finish(token: token)
        instrumentation.didFinishRun(runEvent)
        return
      }

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
          id: context?.cancellationID,
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

      let effectContext = EffectContext(
        now: {
          await clock.now()
        },
        sleep: { duration in
          try await clock.sleep(duration)
        },
        isCancelled: {
          Task.isCancelled
        },
        checkCancellation: {
          if lifetime.isReleased {
            throw CancellationError()
          }
          try await runtime.checkCancellation(
            token: token,
            id: context?.cancellationID,
            sequence: sequence
          )
        }
      )

      await operation(send, effectContext)
      await runtime.finish(token: token)
      instrumentation.didFinishRun(runEvent)
    }

    await runtime.registerAndStart(
      token: token,
      id: context?.cancellationID,
      task: task,
      gate: gate
    )

    if awaited {
      _ = await task.result
    }
  }

  package func cancelEffects(id: EffectID, context: EffectExecutionContext?) async {
    let sequence = effectBridge.markCancelled(id: id, upTo: context?.sequence)
    recordCancellation(id: id, sequence: sequence)
    await effectBridge.cancelEffects(id: id, upTo: sequence)
  }

  package func cancelInFlightEffects(id: EffectID, context: EffectExecutionContext?) async {
    let sequence = effectBridge.markCancelledInFlight(id: id, upTo: context?.sequence)
    recordCancellation(id: id, sequence: sequence)
    await effectBridge.cancelInFlightEffects(id: id, upTo: sequence)
  }

  package func shouldProceed(context: EffectExecutionContext?) -> Bool {
    effectBridge.shouldProceed(context: context)
  }

  package func debounce(
    _ nested: EffectTask<R.Action>,
    id: EffectID,
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
    for id: EffectID,
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
      for child in children {
        Task { [weak self] in
          guard self != nil else { return }
          await recurse(child, context, false)
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
      Task { [weak self] in
        guard self != nil else { return }
        for child in children {
          await recurse(child, context, true)
        }
      }
    }
  }
}
