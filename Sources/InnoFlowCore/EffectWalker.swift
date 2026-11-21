// MARK: - EffectWalker.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

// MARK: - Effect Walker

/// The single recursive interpreter for `EffectTask.Operation`.
///
/// Structural rules (merge = parallel, concatenate = sequential,
/// cancellable = wrap context, throttle window logic, animation context)
/// are defined here exactly once. Runtime-specific behavior is delegated
/// to the `EffectDriver` conformer.
@MainActor
package struct EffectWalker<D: EffectDriver> {

  private weak var driver: D?

  package init(driver: D) {
    self.driver = driver
  }

  // MARK: - Public Entry Point

  /// Walk the effect tree, interpreting each node via the driver.
  package func walk(
    _ effect: ReducerEffect<D.Action, D.Output>,
    context: EffectExecutionContext? = nil,
    awaited: Bool = false
  ) async {
    switch effect.operation {
    case .optionalChild, .lifetimeScope:
      preconditionFailure("Child lifetime metadata must be prepared synchronously after reduction")

    case .owned(let owner, let nested):
      await walk(nested, context: .withOwner(owner, on: context), awaited: awaited)

    case .none:
      return

    case .send(let action):
      guard let driver else { return }
      driver.deliverAction(action, context: context)

    case .output(let output):
      guard let driver else { return }
      driver.deliverOutput(output, context: context)

    case .run(let priority, let operation):
      let task = await prepareRun(
        priority: priority,
        operation: operation,
        context: context
      )
      if awaited, let task {
        _ = await task.result
      }

    case .scheduledRun(let id, let policy, let priority, let onAdmission, let operation):
      let task = await prepareScheduledRun(
        id: id,
        policy: policy,
        priority: priority,
        onAdmission: onAdmission,
        operation: operation,
        context: context
      )
      if awaited, let task {
        _ = await task.result
      }

    case .merge(let children):
      guard shouldProceed(context: context) else { return }
      if awaited {
        await withTaskGroup(of: Void.self) { group in
          for child in children {
            group.addTask { [recurse] in
              await recurse(child, context, true)
            }
          }
          await group.waitForAll()
        }
      } else {
        guard let driver else { return }
        await driver.runConcurrently(
          children,
          context: context,
          recurse: recurse
        )
      }

    case .concatenate(let children):
      guard shouldProceed(context: context) else { return }
      if awaited {
        for child in children {
          guard shouldProceed(context: context) else { return }
          await recurse(child, context, true)
        }
      } else {
        guard let driver else { return }
        await driver.runSequentially(
          children,
          context: context,
          recurse: recurse
        )
      }

    case .cancel(let id):
      guard shouldProceed(context: context) else { return }
      guard let driver else { return }
      await driver.cancelEffects(id: id, context: context)

    case .cancellable(let nested, let id, let cancelInFlight):
      guard shouldProceed(context: context) else { return }
      if cancelInFlight {
        await cancelInFlightEffects(id: id, context: context)
      }
      await walk(
        nested,
        context: declaringContext(id, on: context, for: nested),
        awaited: awaited
      )

    case .debounce(let nested, let id, let interval):
      guard shouldProceed(context: context) else { return }
      let task = await prepareDebounce(
        nested: nested,
        id: id,
        interval: interval,
        context: context,
        nestedAwaited: awaited
      )
      if awaited, let task {
        _ = await task.result
      }

    case .throttle(let nested, let id, let interval, let leading, let trailing):
      guard shouldProceed(context: context) else { return }
      await walkThrottle(
        nested: nested,
        id: id,
        interval: interval,
        leading: leading,
        trailing: trailing,
        context: context,
        awaited: awaited
      )

    case .animation(let nested, let animation):
      await walk(
        nested,
        context: .withAnimation(animation, on: context),
        awaited: awaited
      )

    case .diagnosticDrop(let action, let reason):
      guard let driver else { return }
      driver.reportActionDrop(action, reason: reason, context: context)
    }
  }

  /// Rechecks sequential child admission without retaining the driver across
  /// the child's awaited work. Nested concatenations use this boundary after
  /// every completed child so accepted cancellation cannot start siblings.
  private func shouldProceed(context: EffectExecutionContext?) -> Bool {
    guard !Task.isCancelled, let driver else { return false }
    return driver.shouldProceed(context: context)
  }

  /// The context of work this tree declares under `id`.
  ///
  /// An ID cancellation accepted while the work was declared but not yet
  /// interpreted leaves its token already cancelled, so the work is skipped
  /// without ever registering where that cancellation could have found it.
  /// When the enclosing context still proceeds, only that ID stops the work:
  /// the driver records the cancellation for the dispatch that owns it.
  /// `work` is the subtree the context covers; `nil` stands for a lane
  /// request, which is always work.
  private func declaringContext(
    _ id: AnyEffectID,
    on context: EffectExecutionContext?,
    for work: ReducerEffect<D.Action, D.Output>?
  ) -> EffectExecutionContext {
    let declared = EffectExecutionContext.withCancellation(id, on: context)
    if let driver, !driver.shouldProceed(context: declared),
      driver.shouldProceed(context: context), work?.performsWork != false
    {
      driver.reportCancelledBeforeRegistration(context: declared)
    }
    return declared
  }

  /// Registers run work in a short-lived frame so an awaited run does not
  /// retain the driver while the operation is suspended.
  private func prepareRun(
    priority: TaskPriority?,
    operation: @escaping @concurrent @Sendable (Send<D.Action>, EffectContext) async -> Void,
    context: EffectExecutionContext?
  ) async -> Task<Void, Never>? {
    guard let driver else { return nil }
    guard driver.shouldProceed(context: context) else { return nil }
    return await driver.startRun(
      priority: priority,
      operation: operation,
      context: context
    )
  }

  private func prepareScheduledRun(
    id: AnyEffectID,
    policy: EffectExecutionPolicy,
    priority: TaskPriority?,
    onAdmission: (@Sendable (EffectAdmission) -> D.Action)?,
    operation: @escaping @concurrent @Sendable (Send<D.Action>, EffectContext) async -> Void,
    context: EffectExecutionContext?
  ) async -> Task<Void, Never>? {
    guard let driver else { return nil }
    guard driver.shouldProceed(context: context) else { return nil }
    let scheduledContext = declaringContext(id, on: context, for: nil)
    return await driver.scheduleRun(
      id: id,
      policy: policy,
      priority: priority,
      onAdmission: onAdmission,
      operation: operation,
      context: scheduledContext
    )
  }

  /// Applies a cancellation boundary in a short-lived frame so an enclosing
  /// cancellable wrapper does not retain the driver while its nested effect
  /// performs delayed awaited work.
  private func cancelInFlightEffects(
    id: AnyEffectID,
    context: EffectExecutionContext?
  ) async {
    guard let driver else { return }
    await driver.cancelInFlightEffects(id: id, context: context)
  }

  /// Schedules debounce work without retaining the driver while its timer is
  /// suspended. An enclosing unawaited composite is owned by the driver, so a
  /// strong driver reference across the delay would otherwise form a cycle.
  private func prepareDebounce(
    nested: ReducerEffect<D.Action, D.Output>,
    id: AnyEffectID,
    interval: Duration,
    context: EffectExecutionContext?,
    nestedAwaited: Bool
  ) async -> Task<Void, Never>? {
    guard let driver else { return nil }

    let delayedContext = declaringContext(id, on: context, for: nested)

    let delayedScope = DelayedEffectScope(
      ownerID: id,
      inheritedCancellationIDs: context?.cancellationIDs ?? [],
      sequence: context?.sequence,
      cancellationContext: delayedContext
    )
    return await driver.scheduleDebounce(
      nested,
      id: id,
      interval: interval,
      context: delayedContext,
      scope: delayedScope,
      nestedAwaited: nestedAwaited,
      recurse: recurse
    )
  }

  // MARK: - Throttle (shared window logic)

  private struct ThrottlePlan {
    let runsLeadingEffect: Bool
    /// What an awaited trailing request waits for: the end of its window, or
    /// a cancellation that removes it from the window first.
    let trailingCompletionToAwait: (@Sendable () async -> Void)?
  }

  private func walkThrottle(
    nested: ReducerEffect<D.Action, D.Output>,
    id: AnyEffectID,
    interval: Duration,
    leading: Bool,
    trailing: Bool,
    context: EffectExecutionContext?,
    awaited: Bool
  ) async {
    let throttleContext = declaringContext(id, on: context, for: nested)
    guard
      let plan = await prepareThrottle(
        nested: nested,
        id: id,
        interval: interval,
        leading: leading,
        trailing: trailing,
        context: context,
        throttleContext: throttleContext,
        awaited: awaited
      )
    else { return }

    if plan.runsLeadingEffect {
      await walk(nested, context: throttleContext, awaited: awaited)
    }

    if let trailingCompletion = plan.trailingCompletionToAwait {
      await trailingCompletion()
    }
  }

  /// Makes the window under `id` hold `request` for its dispatch, and returns
  /// what the request's interpreter frame awaits when it is awaited.
  ///
  /// The frame waits for its own request, not for the shared timer task: a
  /// cancellation that removes the request from the window releases it,
  /// while the timer keeps serving the requests that remain.
  private func holdWindow(
    _ id: AnyEffectID,
    request: DelayedEffectScope,
    drain: Task<Void, Never>,
    awaited: Bool,
    driver: D
  ) -> (@Sendable () async -> Void)? {
    let window = driver.throttleState.holdWindow(for: id, request: request)
    guard awaited else { return nil }
    guard let window else {
      return { _ = await drain.result }
    }
    let requestID = request.requestID
    return { await window.waitForRelease(of: requestID) }
  }

  /// Reports a throttle request that an ID cancellation released while its
  /// clock was read: the request was declared but registered nowhere that
  /// cancellation could find it, and the interpreter now skips it.
  ///
  /// As for work released before the interpreter reached it, only an ID
  /// cancellation is reported: a cancelled dispatch records its own
  /// cancellation, and a cancellation of every effect is not an ID
  /// cancellation.
  private func reportReleasedDuringClockRead(
    _ throttleContext: EffectExecutionContext,
    work: ReducerEffect<D.Action, D.Output>,
    driver: D
  ) {
    guard work.performsWork,
      throttleContext.flowTaskTracker?.isCancelled != true,
      throttleContext.cancellationScope?.isGloballyCancelled != true
    else { return }
    driver.reportCancelledBeforeRegistration(context: throttleContext)
  }

  /// Prepares throttle state without retaining the driver across delayed work.
  ///
  /// A Store owns unawaited composite tasks. If an awaited throttle frame kept
  /// the Store strongly while waiting for its timer, that ownership would form
  /// a cycle and prevent Store deinitialization from cancelling the timer.
  private func prepareThrottle(
    nested: ReducerEffect<D.Action, D.Output>,
    id: AnyEffectID,
    interval: Duration,
    leading: Bool,
    trailing: Bool,
    context: EffectExecutionContext?,
    throttleContext: EffectExecutionContext,
    awaited: Bool
  ) async -> ThrottlePlan? {
    guard let driver else { return nil }

    let delayedScope = DelayedEffectScope(
      ownerID: id,
      inheritedCancellationIDs: context?.cancellationIDs ?? [],
      sequence: context?.sequence,
      cancellationContext: throttleContext
    )
    guard driver.throttleState.beginAdmission(delayedScope) else { return nil }
    defer {
      driver.throttleState.endAdmission(for: id)
    }
    let proceededBeforeClockRead = driver.shouldProceed(context: throttleContext)
    let now = await driver.now
    guard driver.shouldProceed(context: throttleContext) else {
      // A cancellation accepted during the clock read found the request
      // nowhere: it is declared, but not registered yet.
      if proceededBeforeClockRead {
        reportReleasedDuringClockRead(throttleContext, work: nested, driver: driver)
      }
      return nil
    }
    guard driver.throttleState.admit(delayedScope) else { return nil }

    // Inside active window — store trailing if requested, then drop.
    if let windowEnd = driver.throttleState.windowEnd(for: id),
      now < windowEnd
    {
      if trailing {
        guard driver.throttleState.setScope(delayedScope) else { return nil }
        driver.throttleState.storePending(
          nested,
          context: throttleContext,
          requiresAwaitedCompletion: awaited,
          scope: delayedScope,
          for: id
        )

        let trailingTask: Task<Void, Never>
        if let activeTrailingTask = driver.throttleState.trailingTask(for: id) {
          driver.refreshTrailingDrainOwnership(
            for: id,
            context: throttleContext
          )
          trailingTask = activeTrailingTask
        } else {
          trailingTask = driver.scheduleTrailingDrain(
            for: id,
            interval: now.duration(to: windowEnd),
            schedulingContext: throttleContext,
            awaited: awaited,
            recurse: recurse
          )
        }
        return .init(
          runsLeadingEffect: false,
          trailingCompletionToAwait: holdWindow(
            id, request: delayedScope, drain: trailingTask, awaited: awaited, driver: driver)
        )
      }
      return .init(
        runsLeadingEffect: false,
        trailingCompletionToAwait: nil
      )
    }

    // New window.
    driver.throttleState.resetWindow(for: id)
    guard driver.throttleState.setScope(delayedScope) else { return nil }
    driver.throttleState.setWindowEnd(now.advanced(by: interval), for: id)

    if trailing && !leading {
      driver.throttleState.storePending(
        nested,
        context: throttleContext,
        requiresAwaitedCompletion: awaited,
        scope: delayedScope,
        for: id
      )
    }
    // The drain expires window ownership even when no trailing value exists.
    // Leading-only callers never await that bookkeeping task; a later awaited
    // trailing request promotes recursion through the pending state instead.
    let throttleDrain = driver.scheduleTrailingDrain(
      for: id,
      interval: interval,
      schedulingContext: throttleContext,
      awaited: trailing && awaited,
      recurse: recurse
    )

    return .init(
      runsLeadingEffect: leading,
      trailingCompletionToAwait: holdWindow(
        id, request: delayedScope, drain: throttleDrain, awaited: trailing && awaited,
        driver: driver)
    )
  }

  // MARK: - Recursion Closure

  private var recurse:
    @MainActor @Sendable (
      ReducerEffect<D.Action, D.Output>, EffectExecutionContext?, Bool
    ) async -> Void
  {
    { [self] effect, context, awaited in
      await self.walk(effect, context: context, awaited: awaited)
    }
  }
}

extension ReducerEffect {
  /// Whether interpreting this tree can do anything a cancellation would
  /// stop: deliver an action or output, start or schedule work, or request
  /// cancellation. A drop report is delivered regardless of cancellation.
  fileprivate var performsWork: Bool {
    switch operation {
    case .none, .diagnosticDrop:
      return false
    case .cancellable(let effect, _, let cancelInFlight):
      return cancelInFlight || effect.performsWork
    case .animation(let effect, _), .owned(_, let effect), .lifetimeScope(_, let effect):
      return effect.performsWork
    case .merge(let effects), .concatenate(let effects):
      return effects.contains { $0.performsWork }
    case .send, .output, .run, .scheduledRun, .cancel, .debounce, .throttle, .optionalChild:
      return true
    }
  }
}
