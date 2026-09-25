// MARK: - TestStore+EffectRunScheduler.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
package import InnoFlowCore

extension TestStore {
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
    let plan = await runScheduler.admit(
      id: id,
      policy: policy,
      cancellationIDs: context?.cancellationIDs ?? [],
      sequence: context?.sequence ?? 0,
      dispatchID: context?.dispatchID,
      onCancellation: { _, _ in },
      onStart: { [weak self] _ in
        guard let action = onAdmission?(.started) else { return }
        self?.deliverAction(action, context: context)
      },
      onPendingExit: { _ in }
    )

    guard case .accepted(let ticket) = plan else {
      if case .rejected(let reason) = plan,
        let action = onAdmission?(.rejected(reason))
      {
        deliverAction(action, context: context)
      }
      return nil
    }

    if case .latest = policy {
      await cancelInFlightEffects(id: id, context: context)
    }

    if case .queued = ticket.admission,
      let action = onAdmission?(ticket.admission)
    {
      deliverAction(action, context: context)
    }

    let token = ticket.token
    beginFinishActivity(.scheduled, token: token, context: context)
    let endpoint = makeRunEndpoint()
    let scheduler = runScheduler
    let task = Task { @MainActor [weak self] in
      defer {
        endpoint.finishTrackedTask(token: token)
      }
      let shouldStart = await withTaskCancellationHandler {
        await ticket.gate.wait()
      } onCancel: {
        Task { @MainActor in
          scheduler.cancel(token: token)
        }
      }
      guard shouldStart, !Task.isCancelled else {
        await scheduler.finish(token)
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
        await scheduler.finish(token)
        return
      }
      _ = scheduler.attachOperation(run, to: ticket)
      _ = await run.result
      await scheduler.finish(token)
    }

    trackEffectTask(token: token, task: task, context: context)
    _ = await runScheduler.attach(task, to: ticket)
    return task
  }
}
