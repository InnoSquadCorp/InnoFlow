// MARK: - EffectWalker.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import SwiftUI

// MARK: - Effect Walker

/// The single recursive interpreter for `EffectTask.Operation`.
///
/// Structural rules (merge = parallel, concatenate = sequential,
/// cancellable = wrap context, throttle window logic, animation context)
/// are defined here exactly once. Runtime-specific behavior is delegated
/// to the `EffectDriver` conformer.
@MainActor
package struct EffectWalker<D: EffectDriver> {

  private let driver: D

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
      driver.deliverAction(action, context: context)

    case .run(let priority, let operation):
      guard driver.shouldProceed(context: context) else { return }
      await driver.startRun(
        priority: priority,
        operation: operation,
        context: context,
        awaited: awaited
      )

    case .merge(let children):
      await driver.runConcurrently(
        children,
        context: context,
        awaited: awaited,
        recurse: recurse
      )

    case .concatenate(let children):
      await driver.runSequentially(
        children,
        context: context,
        awaited: awaited,
        recurse: recurse
      )

    case .cancel(let id):
      await driver.cancelEffects(id: id, context: context)

    case .cancellable(let nested, let id, let cancelInFlight):
      if cancelInFlight {
        await driver.cancelInFlightEffects(id: id, context: context)
      }
      await walk(
        nested,
        context: .withCancellation(id, on: context),
        awaited: awaited
      )

    case .debounce(let nested, let id, let interval):
      await driver.debounce(
        nested,
        id: id,
        interval: interval,
        context: .withCancellation(id, on: context),
        awaited: awaited,
        recurse: recurse
      )

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
    }
  }

  // MARK: - Throttle (shared window logic)

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
    let now = await driver.now

    // Inside active window — store trailing if requested, then drop.
    if let windowEnd = driver.throttleState.windowEnd(for: id),
      now < windowEnd
    {
      if trailing {
        driver.throttleState.storePending(nested, context: throttleContext, for: id)
      }
      return
    }

    // New window.
    driver.throttleState.resetWindow(for: id)
    driver.throttleState.setWindowEnd(now.advanced(by: interval), for: id)

    if trailing {
      if !leading {
        driver.throttleState.storePending(nested, context: throttleContext, for: id)
      }
      driver.scheduleTrailingDrain(for: id, interval: interval, recurse: recurse)
    }

    if leading {
      await walk(nested, context: throttleContext, awaited: awaited)
    }
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
