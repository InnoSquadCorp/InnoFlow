import Foundation

extension Store: EffectDriver {
  package typealias Action = R.Action
  package typealias Output = R.Output

  /// Starts the orchestration task that owns a non-awaited merge or
  /// concatenate subtree.
  ///
  /// Priority semantics are deliberate: the orchestration `Task` carries no
  /// explicit priority, so it inherits the enqueuing MainActor context
  /// (typically user-initiated). It only awaits child completion — the
  /// actual work runs in the child `.run` tasks, which apply their declared
  /// `priority:` in `startRun`. Deriving a wrapper priority from the child
  /// tree would add a per-composite tree walk for no observable scheduling
  /// difference.
  @discardableResult
  private func startCompositeTask(
    context: EffectExecutionContext?,
    operation: @escaping @MainActor @Sendable () async -> Void
  ) -> Task<Void, Never> {
    let token = UUID()
    let gate = RunStartGate()
    let bridge = effectBridge
    let flowTaskTracker = context?.flowTaskTracker
    let flowTaskActivity = flowTaskTracker?.beginActivity()
    let task = Task { @MainActor [weak flowTaskTracker] in
      defer {
        if let flowTaskActivity {
          flowTaskTracker?.endActivity(flowTaskActivity)
        }
      }
      await gate.wait()
      defer {
        bridge.finishCompositeTask(token: token)
      }
      guard !Task.isCancelled else { return }
      await operation()
    }

    bridge.registerCompositeTask(
      token: token,
      ids: context?.cancellationIDs ?? [],
      sequence: context?.sequence ?? 0,
      context: context,
      task: task
    )
    if let flowTaskActivity {
      flowTaskTracker?.attach(task, to: flowTaskActivity)
    }
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
    enqueue(
      action,
      animation: context?.animation,
      flowTaskTracker: context?.flowTaskTracker
    )
  }

  package func deliverOutput(_ output: R.Output, context: EffectExecutionContext?) {
    guard effectBridge.shouldProceed(context: context) else {
      instrumentation.didDeliverOutput(
        .init(
          sequence: context?.sequence,
          subscriberCount: 0,
          enqueuedCount: 0,
          droppedCount: 0,
          terminatedCount: 0,
          dispatchCaptureDisposition: nil,
          wasSuppressedByCancellation: true,
          dispatchID: context?.dispatchID
        )
      )
      return
    }

    let summary = outputHub.yield(output)
    let captureDisposition = context?.flowTaskTracker?.captureOutput(output).map {
      switch $0 {
      case .enqueued:
        return StoreInstrumentation<R.Action>.OutputDeliveryDisposition.enqueued
      case .dropped:
        return StoreInstrumentation<R.Action>.OutputDeliveryDisposition.dropped
      case .terminated:
        return StoreInstrumentation<R.Action>.OutputDeliveryDisposition.terminated
      }
    }
    instrumentation.didDeliverOutput(
      .init(
        sequence: context?.sequence,
        subscriberCount: summary.subscriberCount,
        enqueuedCount: summary.enqueuedCount,
        droppedCount: summary.droppedCount,
        terminatedCount: summary.terminatedCount,
        dispatchCaptureDisposition: captureDisposition,
        wasSuppressedByCancellation: false,
        dispatchID: context?.dispatchID
      )
    )
  }

  package func reportActionDrop(
    _ action: R.Action,
    reason: ActionDropReason,
    context: EffectExecutionContext?
  ) {
    recordDrop(action, reason: reason, context: context)
  }

  @discardableResult
  package func startRun(
    priority: TaskPriority?,
    operation: @escaping @Sendable (Send<R.Action>, EffectContext) async -> Void,
    context: EffectExecutionContext?
  ) async -> Task<Void, Never> {
    let context = context?.frozenForExecution()
    let sequence = context?.sequence ?? 0
    let token = UUID()
    let gate = RunStartGate()
    let runEvent = makeRunEvent(token: token, context: context)

    let runtime = effectBridge.runtime
    let instrumentation = self.instrumentation
    let clock = self.clock
    let lifetime = self.lifetime
    let flowTaskTracker = context?.flowTaskTracker
    let flowTaskActivity = flowTaskTracker?.beginActivity()
    let task = Task(priority: priority) { [weak self, weak flowTaskTracker] in
      defer {
        if let flowTaskActivity {
          flowTaskTracker?.endActivity(flowTaskActivity)
        }
      }
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
      let runFailedBox = RunFailureLatch()

      let send = Send<R.Action> { action in
        if lifetime.isReleased {
          instrumentation.didDropAction(
            .init(
              action: action,
              reason: .storeReleased,
              cancellationID: context?.cancellationID,
              sequence: sequence,
              dispatchID: context?.dispatchID
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
              sequence: sequence,
              dispatchID: context?.dispatchID
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
                sequence: sequence,
                dispatchID: context?.dispatchID
              )
            )
            return
          }

          if self.effectBridge.shouldProceed(context: context) {
            self.recordEmission(action, context: context)
            self.enqueue(
              action,
              animation: context?.animation,
              flowTaskTracker: context?.flowTaskTracker
            )
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
          let errorDescription = String(describing: error)
          let errorTypeName = String(describing: type(of: error))

          await MainActor.run {
            // Cancellation-first and first-error-wins are decided atomically
            // with Store's MainActor-isolated cancellation boundaries. This
            // prevents an uncooperative operation from reclassifying a run as
            // failed after cancellation has already been accepted.
            guard
              !lifetime.isReleased,
              let self,
              self.effectBridge.shouldProceed(context: context),
              runFailedBox.setIfUnset()
            else { return }

            instrumentation.didFailRun(
              .init(
                token: token,
                cancellationID: context?.cancellationID,
                sequence: context?.sequence,
                errorDescription: errorDescription,
                errorTypeName: errorTypeName,
                dispatchID: context?.dispatchID
              )
            )
          }
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
      sequence: sequence,
      context: context,
      task: task,
      gate: gate
    )
    if let flowTaskActivity {
      flowTaskTracker?.attach(task, to: flowTaskActivity)
    }
    return task
  }

  @discardableResult
  package func scheduleRun(
    id: AnyEffectID,
    policy: EffectExecutionPolicy,
    priority: TaskPriority?,
    onAdmission: (@Sendable (EffectAdmission) -> R.Action)?,
    operation: @escaping @Sendable (Send<R.Action>, EffectContext) async -> Void,
    context: EffectExecutionContext?
  ) async -> Task<Void, Never>? {
    let context = context?.frozenForExecution()
    let scheduler = effectBridge.runScheduler
    let plan = await scheduler.admit(
      id: id,
      policy: policy,
      cancellationIDs: context?.cancellationIDs ?? [],
      sequence: context?.sequence ?? 0,
      dispatchID: context?.dispatchID,
      onCancellation: { [weak self] dispatchID, sequence in
        self?.diagnostics?.recordCancellationRequested(
          dispatchID,
          sequence: sequence,
          hasEffectID: true
        )
      },
      onStart: { [weak self] scheduledToken in
        self?.diagnostics?.recordAdmission(
          .started,
          dispatchID: context?.dispatchID,
          sequence: context?.sequence,
          scheduledToken: scheduledToken
        )
        guard let action = onAdmission?(.started) else { return }
        self?.deliverAction(action, context: context)
      },
      onPendingExit: { [weak self] scheduledToken in
        self?.diagnostics?.recordQueuedRunRemoved(
          dispatchID: context?.dispatchID,
          sequence: context?.sequence,
          scheduledToken: scheduledToken
        )
      }
    )

    guard case .accepted(let ticket) = plan else {
      if case .rejected(let reason) = plan,
        let action = onAdmission?(.rejected(reason))
      {
        diagnostics?.recordAdmission(
          .rejected(reason),
          dispatchID: context?.dispatchID,
          sequence: context?.sequence
        )
        deliverAction(action, context: context)
      } else if case .rejected(let reason) = plan {
        diagnostics?.recordAdmission(
          .rejected(reason),
          dispatchID: context?.dispatchID,
          sequence: context?.sequence
        )
      }
      return nil
    }

    if case .latest = policy {
      await cancelInFlightEffects(id: id, context: context)
    }

    if case .queued = ticket.admission,
      let action = onAdmission?(ticket.admission)
    {
      diagnostics?.recordAdmission(
        ticket.admission,
        dispatchID: context?.dispatchID,
        sequence: context?.sequence,
        scheduledToken: ticket.token
      )
      deliverAction(action, context: context)
    } else if case .queued = ticket.admission {
      diagnostics?.recordAdmission(
        ticket.admission,
        dispatchID: context?.dispatchID,
        sequence: context?.sequence,
        scheduledToken: ticket.token
      )
    }

    let flowTaskTracker = context?.flowTaskTracker
    let flowTaskActivity = flowTaskTracker?.beginActivity()
    let task = Task { @MainActor [weak self, weak flowTaskTracker] in
      defer {
        if let flowTaskActivity {
          flowTaskTracker?.endActivity(flowTaskActivity)
        }
      }

      let shouldStart = await withTaskCancellationHandler {
        await ticket.gate.wait()
      } onCancel: {
        Task { @MainActor in
          scheduler.cancel(token: ticket.token)
        }
      }
      guard shouldStart, !Task.isCancelled else {
        await scheduler.finish(ticket.token)
        return
      }
      let runContext = EffectExecutionContext.withRunCancellation(
        ticket.cancellationState,
        on: context
      ).frozenForExecution()
      guard
        let run = await self?.startRun(
          priority: priority,
          operation: operation,
          context: runContext
        )
      else {
        await scheduler.finish(ticket.token)
        return
      }
      _ = scheduler.attachOperation(run, to: ticket)
      _ = await run.result
      await scheduler.finish(ticket.token)
    }

    if let flowTaskActivity {
      flowTaskTracker?.attach(task, to: flowTaskActivity)
    }
    guard await scheduler.attach(task, to: ticket) else { return task }
    return task
  }

  package func cancelEffects(id: AnyEffectID, context: EffectExecutionContext?) async {
    let sequence = effectBridge.markCancelled(id: id, upTo: context?.sequence)
    recordCancellation(id: id, sequence: sequence, dispatchID: context?.dispatchID)
    let targets = await effectBridge.cancellationTargetDispatchIDs(id: id, upTo: sequence)
    recordDiagnosticCancellations(targets, sequence: sequence, hasEffectID: true)
    await effectBridge.cancelEffects(id: id, upTo: sequence)
  }

  package func cancelInFlightEffects(id: AnyEffectID, context: EffectExecutionContext?) async {
    let sequence = effectBridge.markCancelledInFlight(id: id, upTo: context?.sequence)
    recordCancellation(id: id, sequence: sequence, dispatchID: context?.dispatchID)
    let targets = await effectBridge.cancellationTargetDispatchIDs(id: id, upTo: sequence)
    recordDiagnosticCancellations(targets, sequence: sequence, hasEffectID: true)
    await effectBridge.cancelInFlightEffects(id: id, upTo: sequence)
  }

  package func shouldProceed(context: EffectExecutionContext?) -> Bool {
    effectBridge.shouldProceed(context: context)
  }

  @discardableResult
  package func scheduleDebounce(
    _ nested: ReducerEffect<R.Action, R.Output>,
    id: AnyEffectID,
    interval: Duration,
    context: EffectExecutionContext?,
    scope: DelayedEffectScope,
    nestedAwaited: Bool,
    recurse:
      @escaping @MainActor @Sendable (
        ReducerEffect<R.Action, R.Output>, EffectExecutionContext?, Bool
      ) async -> Void
  ) async -> Task<Void, Never>? {
    await cancelInFlightEffects(id: id, context: context)
    guard shouldProceed(context: context) else { return nil }
    guard let generation = effectBridge.beginDebounce(scope) else { return nil }
    let clock = self.clock
    let flowTaskTracker = context?.flowTaskTracker
    let flowTaskActivity = flowTaskTracker?.beginActivity()

    let task = Task { [weak self, weak flowTaskTracker] in
      defer {
        if let flowTaskActivity {
          flowTaskTracker?.endActivity(flowTaskActivity)
        }
      }
      do {
        try await clock.sleep(interval)
      } catch {
        await MainActor.run {
          guard let self else { return }
          if self.effectBridge.debounceGeneration(for: id) == generation {
            self.effectBridge.finishDebounceState(for: id, generation: generation)
          }
          self.recordDrop(nil, reason: .throttledOrDebouncedCancellation, context: context)
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

      guard shouldRun else { return }
      await recurse(nested, context, nestedAwaited)
    }

    guard effectBridge.setDebounceDelayTask(task, for: id, generation: generation) else {
      return nil
    }
    if let flowTaskActivity {
      flowTaskTracker?.attach(task, to: flowTaskActivity)
    }
    return task
  }

  package var throttleState: ThrottleStateMap<R.Action, R.Output> {
    effectBridge.throttleState
  }

  @discardableResult
  package func scheduleTrailingDrain(
    for id: AnyEffectID,
    interval: Duration,
    schedulingContext: EffectExecutionContext,
    awaited: Bool,
    recurse:
      @escaping @MainActor @Sendable (
        ReducerEffect<R.Action, R.Output>, EffectExecutionContext?, Bool
      ) async -> Void
  ) -> Task<Void, Never> {
    let schedulingContext = schedulingContext.frozenForExecution()
    throttleState.cancelTrailingTask(for: id)
    let generation = throttleState.nextGeneration(for: id)

    let clock = self.clock
    let task = Task { [weak self] in
      do {
        try await clock.sleep(interval)
      } catch {
        await MainActor.run {
          guard let self else { return }
          if self.throttleState.generation(for: id) == generation {
            self.throttleState.finishState(for: id, generation: generation)
          }
          self.recordDrop(
            nil,
            reason: .throttledOrDebouncedCancellation,
            context: schedulingContext
          )
        }
        return
      }

      let pending: ThrottleStateMap<R.Action, R.Output>.PendingTrailing? =
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

      guard let pending else { return }
      await recurse(
        pending.effect,
        pending.context,
        awaited || pending.requiresAwaitedCompletion
      )
    }

    throttleState.setTrailingTask(task, for: id)
    // A trailing timer can outlive and serve more than one dispatch. The
    // runtime owns the shared timer; each dispatch tracks only its completion
    // so cancelling an older FlowTask cannot cancel a newer pending effect.
    schedulingContext.flowTaskTracker?.trackCompletion(of: task)
    return task
  }

  package func refreshTrailingDrainOwnership(
    for id: AnyEffectID,
    context: EffectExecutionContext
  ) {
    guard
      let flowTaskTracker = context.flowTaskTracker,
      let trailingTask = throttleState.trailingTask(for: id)
    else { return }

    // The timer is runtime-owned. Mirror its completion into the latest
    // dispatch without granting that dispatch authority over the shared task.
    flowTaskTracker.trackCompletion(of: trailingTask)
  }

  package var now: ContinuousClock.Instant {
    get async {
      await clock.now()
    }
  }

  package func runConcurrently(
    _ children: [ReducerEffect<R.Action, R.Output>],
    context: EffectExecutionContext?,
    awaited: Bool,
    recurse:
      @escaping @MainActor @Sendable (
        ReducerEffect<R.Action, R.Output>, EffectExecutionContext?, Bool
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
      startCompositeTask(context: context) {
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
    _ children: [ReducerEffect<R.Action, R.Output>],
    context: EffectExecutionContext?,
    awaited: Bool,
    recurse:
      @escaping @MainActor @Sendable (
        ReducerEffect<R.Action, R.Output>, EffectExecutionContext?, Bool
      ) async -> Void
  ) async {
    if awaited {
      for child in children {
        await recurse(child, context, true)
      }
    } else {
      let bridge = effectBridge
      startCompositeTask(context: context) {
        for child in children {
          guard !Task.isCancelled else { return }
          guard bridge.shouldProceed(context: context) else { return }
          await recurse(child, context, true)
        }
      }
    }
  }
}
