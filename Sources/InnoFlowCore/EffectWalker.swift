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
    _ effect: EffectTask<D.Action>,
    context: EffectExecutionContext? = nil,
    awaited: Bool = false
  ) async {
    switch effect.operation {
    case .none:
      return

    case .send(let action):
      guard let driver else { return }
      driver.deliverAction(action, context: context)

    case .run(let priority, let operation):
      let task = await prepareRun(
        priority: priority,
        operation: operation,
        context: context
      )
      if awaited, let task {
        _ = await task.result
      }

    case .merge(let children):
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
          awaited: false,
          recurse: recurse
        )
      }

    case .concatenate(let children):
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
          awaited: false,
          recurse: recurse
        )
      }

    case .cancel(let id):
      guard let driver else { return }
      await driver.cancelEffects(id: id, context: context)

    case .cancellable(let nested, let id, let cancelInFlight):
      if cancelInFlight {
        await cancelInFlightEffects(id: id, context: context)
      }
      await walk(
        nested,
        context: .withCancellation(id, on: context),
        awaited: awaited
      )

    case .debounce(let nested, let id, let interval):
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

    case .lazyMap(let lazyMapped):
      await walk(
        lazyMapped.materialize(),
        context: context,
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

  /// Registers run work in a short-lived frame so an awaited run does not
  /// retain the driver while the operation is suspended.
  private func prepareRun(
    priority: TaskPriority?,
    operation: @escaping @Sendable (Send<D.Action>, EffectContext) async -> Void,
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
    nested: EffectTask<D.Action>,
    id: AnyEffectID,
    interval: Duration,
    context: EffectExecutionContext?,
    nestedAwaited: Bool
  ) async -> Task<Void, Never>? {
    guard let driver else { return nil }

    let delayedScope = DelayedEffectScope(
      ownerID: id,
      inheritedCancellationIDs: context?.cancellationIDs ?? [],
      sequence: context?.sequence
    )
    return await driver.scheduleDebounce(
      nested,
      id: id,
      interval: interval,
      context: .withCancellation(id, on: context),
      scope: delayedScope,
      nestedAwaited: nestedAwaited,
      recurse: recurse
    )
  }

  // MARK: - Throttle (shared window logic)

  private struct ThrottlePlan {
    let runsLeadingEffect: Bool
    let trailingTaskToAwait: Task<Void, Never>?
  }

  private func walkThrottle(
    nested: EffectTask<D.Action>,
    id: AnyEffectID,
    interval: Duration,
    leading: Bool,
    trailing: Bool,
    context: EffectExecutionContext?,
    awaited: Bool
  ) async {
    let throttleContext = EffectExecutionContext.withCancellation(id, on: context)
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

    if let trailingTask = plan.trailingTaskToAwait {
      _ = await trailingTask.result
    }
  }

  /// Prepares throttle state without retaining the driver across delayed work.
  ///
  /// A Store owns unawaited composite tasks. If an awaited throttle frame kept
  /// the Store strongly while waiting for its timer, that ownership would form
  /// a cycle and prevent Store deinitialization from cancelling the timer.
  private func prepareThrottle(
    nested: EffectTask<D.Action>,
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
      sequence: context?.sequence
    )
    guard driver.throttleState.beginAdmission(delayedScope) else { return nil }
    defer {
      driver.throttleState.endAdmission(for: id)
    }
    let now = await driver.now
    guard driver.shouldProceed(context: throttleContext) else { return nil }
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
          trailingTaskToAwait: awaited ? trailingTask : nil
        )
      }
      return .init(
        runsLeadingEffect: false,
        trailingTaskToAwait: nil
      )
    }

    // New window.
    driver.throttleState.resetWindow(for: id)
    guard driver.throttleState.setScope(delayedScope) else { return nil }
    driver.throttleState.setWindowEnd(now.advanced(by: interval), for: id)

    var trailingTask: Task<Void, Never>?
    if trailing {
      if !leading {
        driver.throttleState.storePending(
          nested,
          context: throttleContext,
          requiresAwaitedCompletion: awaited,
          for: id
        )
      }
      trailingTask = driver.scheduleTrailingDrain(
        for: id,
        interval: interval,
        schedulingContext: throttleContext,
        awaited: awaited,
        recurse: recurse
      )
    }

    return .init(
      runsLeadingEffect: leading,
      trailingTaskToAwait: awaited ? trailingTask : nil
    )
  }

  // MARK: - Recursion Closure

  private var recurse:
    @MainActor @Sendable (
      EffectTask<D.Action>, EffectExecutionContext?, Bool
    ) async -> Void
  {
    { [self] effect, context, awaited in
      await self.walk(effect, context: context, awaited: awaited)
    }
  }
}
