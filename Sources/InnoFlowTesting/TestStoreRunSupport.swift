// MARK: - TestStoreRunSupport.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import InnoFlowCore

@MainActor
final class TestStoreRunEndpoint<Action: Sendable> {
  private let isTaskActiveImpl: (UUID) -> Bool
  private let shouldProceedImpl: (EffectExecutionContext?) -> Bool
  private let didStartRunImpl: (EffectExecutionContext?) -> Void
  private let didEnqueueActionImpl: () -> Void
  private let reportRunFailureImpl: (String, EffectOrigin?, EffectExecutionContext?) -> Void
  private let finishTrackedTaskImpl: (UUID) -> Void

  init(
    isTaskActive: @escaping (UUID) -> Bool,
    shouldProceed: @escaping (EffectExecutionContext?) -> Bool,
    didStartRun: @escaping (EffectExecutionContext?) -> Void,
    didEnqueueAction: @escaping () -> Void,
    reportRunFailure: @escaping (String, EffectOrigin?, EffectExecutionContext?) -> Void,
    finishTrackedTask: @escaping (UUID) -> Void
  ) {
    self.isTaskActiveImpl = isTaskActive
    self.shouldProceedImpl = shouldProceed
    self.didStartRunImpl = didStartRun
    self.didEnqueueActionImpl = didEnqueueAction
    self.reportRunFailureImpl = reportRunFailure
    self.finishTrackedTaskImpl = finishTrackedTask
  }

  func isTaskActive(token: UUID) -> Bool {
    isTaskActiveImpl(token)
  }

  func shouldProceed(context: EffectExecutionContext?) -> Bool {
    shouldProceedImpl(context)
  }

  func didStartRun(context: EffectExecutionContext?) {
    didStartRunImpl(context)
  }

  func didEnqueueAction() {
    didEnqueueActionImpl()
  }

  func reportRunFailure(
    _ message: String,
    origin: EffectOrigin?,
    token: UUID,
    context: EffectExecutionContext?
  ) {
    guard isTaskActiveImpl(token), shouldProceedImpl(context) else { return }
    reportRunFailureImpl(message, origin, context)
  }

  func finishTrackedTask(token: UUID) {
    finishTrackedTaskImpl(token)
  }
}

actor TestStoreRunBridge<Action: Sendable> {
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
    await MainActor.run {
      guard endpoint.isTaskActive(token: token), endpoint.shouldProceed(context: context) else {
        return
      }
      queue.enqueue(action, context: context)
      endpoint.didEnqueueAction()
    }
  }

  func finish() async {
    await endpoint.finishTrackedTask(token: token)
  }
}

actor TestStoreRunStartGate {
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
