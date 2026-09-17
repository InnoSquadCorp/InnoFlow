// MARK: - FlowScope.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

/// A lexical owner for multiple dispatch-scoped tasks.
///
/// Register only work whose lifetime belongs to this scope. Closing a scope
/// cancels and joins its unfinished dispatches without affecting sibling scopes
/// or Store-wide work.
@MainActor
public final class FlowScope {
  private var tasks: [UUID: FlowTask] = [:]
  private var isClosed = false
  private var isCloseFinished = false
  private var closeWaiters: [CheckedContinuation<Void, Never>] = []

  public init() {}

  /// Registers and returns the same dispatch handle.
  ///
  /// A task registered after closure is cancelled and joined before this call
  /// returns. Completed tasks are never changed to cancelled.
  @discardableResult
  public func track(_ task: FlowTask) async -> FlowTask {
    guard task.isFinished == false else { return task }
    guard isClosed == false else {
      task.cancel()
      await task.finish()
      return task
    }

    let token = UUID()
    tasks[token] = task
    task.observeCompletion { [weak self] in
      Task { @MainActor [weak self] in
        self?.tasks.removeValue(forKey: token)
      }
    }
    return task
  }

  /// Registers and returns the same output-capturing handle and stream.
  @discardableResult
  public func track<Output: Sendable>(
    _ task: OutputFlowTask<Output>
  ) async -> OutputFlowTask<Output> {
    guard task.isFinished == false else { return task }
    guard isClosed == false else {
      task.cancel()
      await task.finish()
      return task
    }

    let token = UUID()
    tasks[token] = task.flowTaskReference
    task.observeCompletion { [weak self] in
      Task { @MainActor [weak self] in
        self?.tasks.removeValue(forKey: token)
      }
    }
    return task
  }

  /// Cancels and joins every unfinished dispatch currently owned by the scope.
  public func cancelAndFinish() async {
    guard isClosed == false else {
      guard isCloseFinished == false else { return }
      await withCheckedContinuation { continuation in
        closeWaiters.append(continuation)
      }
      return
    }
    isClosed = true

    let unfinished = tasks.values.filter { $0.isFinished == false }
    tasks.removeAll(keepingCapacity: false)
    for task in unfinished {
      task.cancel()
    }
    await withTaskGroup(of: Void.self) { group in
      for task in unfinished {
        group.addTask {
          await task.finish()
        }
      }
      await group.waitForAll()
    }
    isCloseFinished = true
    let waiters = closeWaiters
    closeWaiters.removeAll(keepingCapacity: false)
    for waiter in waiters {
      waiter.resume()
    }
  }

  package var trackedTaskCount: Int {
    tasks.count
  }
}

/// Runs an operation with an explicit group lifetime for Store dispatches.
///
/// Normal return, thrown error, and caller cancellation all close the scope.
@MainActor
public func withFlowScope<Result: Sendable>(
  _ operation: @MainActor (FlowScope) async throws -> Result
) async rethrows -> Result {
  let scope = FlowScope()
  return try await withTaskCancellationHandler {
    do {
      let result = try await operation(scope)
      await scope.cancelAndFinish()
      return result
    } catch {
      await scope.cancelAndFinish()
      throw error
    }
  } onCancel: {
    Task { @MainActor in
      await scope.cancelAndFinish()
    }
  }
}
