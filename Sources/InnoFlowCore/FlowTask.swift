// MARK: - FlowTask.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import os

package protocol FlowTaskOutputCapturing: Sendable {
  func yield<Value: Sendable>(_ value: Value) -> StoreOutputYieldDisposition
  func finish()
}

package final class TypedFlowTaskOutputCapture<Output: Sendable>: FlowTaskOutputCapturing {
  package let stream: AsyncStream<Output>
  private let continuation: AsyncStream<Output>.Continuation

  package init(
    bufferingPolicy: AsyncStream<Output>.Continuation.BufferingPolicy
  ) {
    let pair = AsyncStream<Output>.makeStream(bufferingPolicy: bufferingPolicy)
    self.stream = pair.stream
    self.continuation = pair.continuation
  }

  package func yield<Value: Sendable>(_ value: Value) -> StoreOutputYieldDisposition {
    guard let output = value as? Output else {
      assertionFailure(
        "FlowTask output capture received \(String(reflecting: Value.self)); expected \(String(reflecting: Output.self))"
      )
      return .terminated
    }
    return storeOutputYieldDisposition(continuation.yield(output))
  }

  package func finish() {
    continuation.finish()
  }

  package func cancelDispatchOnConsumerTermination(_ tracker: FlowTaskTracker) {
    // The tracker owns this capture. A weak reference prevents the stream's
    // cancellation handler from keeping the entire dispatch alive in a cycle.
    continuation.onTermination = { [weak tracker] termination in
      guard case .cancelled = termination else { return }
      tracker?.cancel()
    }
  }
}

/// A handle to the complete effect tree started by one ``Store/send(_:)`` call.
///
/// `FlowTask` connects a caller's structured-concurrency lifetime to reducer
/// effects. ``finish()`` waits for descendant effects and the actions they emit,
/// while ``cancel()`` cancels only work descended from this dispatch.
public struct FlowTask: Sendable {
  private let tracker: FlowTaskTracker?

  package init(tracker: FlowTaskTracker) {
    self.tracker = tracker
  }

  private init() {
    self.tracker = nil
  }

  /// A handle that has already completed.
  public static let completed = Self()

  /// Whether cancellation has been requested through this handle.
  public var isCancelled: Bool {
    tracker?.isCancelled ?? false
  }

  /// Whether this dispatch tree has reached its terminal idle state.
  public var isFinished: Bool {
    tracker?.isFinished ?? true
  }

  /// Cancels only effects and follow-up actions descended from this dispatch.
  public func cancel() {
    tracker?.cancel()
  }

  /// Waits until the complete descendant effect tree becomes idle.
  public func finish() async {
    guard let tracker else { return }
    await withTaskCancellationHandler {
      await tracker.finish()
    } onCancel: {
      tracker.cancel()
    }
  }

  package func observeCompletion(
    _ observer: @escaping @Sendable () -> Void
  ) {
    guard let tracker else {
      observer()
      return
    }
    tracker.observeCompletion(observer)
  }
}

/// A dispatch lifetime paired with outputs emitted only by that action tree.
///
/// The stream is created before the root action is enqueued, so synchronous
/// outputs are buffered according to the policy passed to
/// ``Store/send(_:capturingOutputs:)`` and cannot race subscription setup.
/// The stream finishes when the complete descendant effect tree becomes idle.
/// It is a single-consumer sequence; create a separate captured dispatch when
/// independent consumers need their own delivery contract.
/// Cancelling a task awaiting the stream cancels this dispatch's effect tree.
/// Exiting iteration early with `break` does not cancel a retained stream;
/// explicitly call ``cancel()`` when abandoning the dispatch in that case.
public struct OutputFlowTask<Output: Sendable>: Sendable {
  /// Outputs emitted by the root action and all of its descendant effects.
  public let outputs: AsyncStream<Output>

  private let flowTask: FlowTask

  package init(flowTask: FlowTask, outputs: AsyncStream<Output>) {
    self.flowTask = flowTask
    self.outputs = outputs
  }

  /// A completed handle whose output stream is already finished.
  public static var completed: Self {
    let pair = AsyncStream<Output>.makeStream()
    pair.continuation.finish()
    return .init(flowTask: .completed, outputs: pair.stream)
  }

  /// Whether cancellation has been requested through this handle.
  public var isCancelled: Bool {
    flowTask.isCancelled
  }

  /// Whether this dispatch tree has reached its terminal idle state.
  public var isFinished: Bool {
    flowTask.isFinished
  }

  /// Cancels only effects and follow-up actions descended from this dispatch.
  public func cancel() {
    flowTask.cancel()
  }

  /// Waits until the complete descendant effect tree becomes idle.
  public func finish() async {
    await flowTask.finish()
  }

  package func observeCompletion(
    _ observer: @escaping @Sendable () -> Void
  ) {
    flowTask.observeCompletion(observer)
  }

  package var flowTaskReference: FlowTask {
    flowTask
  }
}

/// Runtime-owned completion for work shared by multiple dispatches.
///
/// A completion subscription retains its dispatch until the physical task returns
/// or that dispatch cancels its interest. Unlike a Task awaiting another Task,
/// removing a subscription releases all of its captures immediately.
package final class FlowTaskCompletion: Sendable {
  private struct State {
    var isComplete = false
    var observers: [UUID: @Sendable () -> Void] = [:]
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  package init() {}

  package var observerCount: Int {
    state.withLock { $0.observers.count }
  }

  fileprivate func observe(_ token: UUID, _ observer: @escaping @Sendable () -> Void) {
    let callsImmediately = state.withLock { state in
      guard !state.isComplete else { return true }
      state.observers[token] = observer
      return false
    }
    if callsImmediately { observer() }
  }

  fileprivate func removeObserver(_ token: UUID) {
    _ = state.withLock { $0.observers.removeValue(forKey: token) }
  }

  package func complete() {
    let observers = state.withLock { state in
      guard !state.isComplete else { return [@Sendable () -> Void]() }
      state.isComplete = true
      let observers = Array(state.observers.values)
      state.observers.removeAll(keepingCapacity: false)
      return observers
    }
    for observer in observers { observer() }
  }
}

/// Thread-safe ownership shared by a root action, its effect interpreters, and
/// every follow-up action they enqueue.
package final class FlowTaskTracker: Sendable {
  private struct WeakCancellationScope {
    weak var value: EffectCancellationScope?
  }

  private struct State {
    var activities: Set<UUID> = []
    var tasks: [UUID: Task<Void, Never>] = [:]
    var sharedCompletions: [UUID: FlowTaskCompletion] = [:]
    var cancellationScopes: [UUID: WeakCancellationScope] = [:]
    var waiters: [CheckedContinuation<Void, Never>] = []
    var completionObservers: [UUID: @Sendable () -> Void] = [:]
    var isCancelled = false
    var isFinished = false
  }

  private let state = OSAllocatedUnfairLock(initialState: State())
  private let outputCapture: (any FlowTaskOutputCapturing)?
  package let dispatchID: DispatchID
  private let onFinish: (@Sendable (DispatchID) -> Void)?
  private let onCancel: (@Sendable (DispatchID) -> Void)?

  package init(
    dispatchID: DispatchID = DispatchID(),
    outputCapture: (any FlowTaskOutputCapturing)? = nil,
    onFinish: (@Sendable (DispatchID) -> Void)? = nil,
    onCancel: (@Sendable (DispatchID) -> Void)? = nil
  ) {
    self.dispatchID = dispatchID
    self.outputCapture = outputCapture
    self.onFinish = onFinish
    self.onCancel = onCancel
  }

  package var isCancelled: Bool {
    state.withLock(\.isCancelled)
  }

  package var isFinished: Bool {
    state.withLock(\.isFinished)
  }

  package func beginActivity() -> UUID {
    let token = UUID()
    _ = state.withLock { state in
      guard state.isFinished == false else { return false }
      return state.activities.insert(token).inserted
    }
    return token
  }

  package func attach(_ task: Task<Void, Never>, to token: UUID) {
    let shouldCancel = state.withLock { state in
      guard state.activities.contains(token) else { return true }
      state.tasks[token] = task
      return state.isCancelled
    }
    if shouldCancel {
      task.cancel()
    }
  }

  /// Tracks an interest in runtime-owned shared work without owning its Task.
  /// Normal completion and cancellation both remove the subscription exactly
  /// once. The runtime completion retains this tracker even if callers discard
  /// their FlowTask; cancellation releases it without awaiting shared work.
  package func trackCompletion(of completion: FlowTaskCompletion) {
    let token = beginActivity()
    completion.observe(token) { [self] in
      endActivity(token)
    }
    let shouldDetach = state.withLock { state in
      guard state.activities.contains(token), !state.isCancelled else { return true }
      state.sharedCompletions[token] = completion
      return false
    }
    if shouldDetach {
      completion.removeObserver(token)
      endActivity(token)
    }
  }

  package func registerCancellationScope(_ scope: EffectCancellationScope) {
    let registrationID = UUID()
    let shouldCancel = state.withLock { state in
      guard !state.activities.isEmpty else { return true }
      state.cancellationScopes = state.cancellationScopes.filter { $0.value.value != nil }
      state.cancellationScopes[registrationID] = WeakCancellationScope(value: scope)
      return state.isCancelled
    }
    if shouldCancel {
      scope.cancelAll()
    }
  }

  package func captureOutput<Output: Sendable>(
    _ output: Output
  ) -> StoreOutputYieldDisposition? {
    outputCapture?.yield(output)
  }

  package func endActivity(_ token: UUID) {
    let completion:
      (
        waiters: [CheckedContinuation<Void, Never>],
        observers: [@Sendable () -> Void],
        finishesOutput: Bool,
        sharedCompletion: FlowTaskCompletion?
      ) =
        state.withLock { state in
          guard state.activities.remove(token) != nil else { return ([], [], false, nil) }
          state.tasks.removeValue(forKey: token)
          let sharedCompletion = state.sharedCompletions.removeValue(forKey: token)
          guard state.activities.isEmpty else { return ([], [], false, sharedCompletion) }
          state.isFinished = true
          state.cancellationScopes.removeAll(keepingCapacity: false)
          let waiters = state.waiters
          let observers = Array(state.completionObservers.values)
          state.waiters.removeAll(keepingCapacity: false)
          state.completionObservers.removeAll(keepingCapacity: false)
          return (waiters, observers, true, sharedCompletion)
        }
    completion.sharedCompletion?.removeObserver(token)
    if completion.finishesOutput {
      outputCapture?.finish()
      onFinish?(dispatchID)
    }
    for waiter in completion.waiters {
      waiter.resume()
    }
    for observer in completion.observers {
      observer()
    }
  }

  package func observeCompletion(
    _ observer: @escaping @Sendable () -> Void
  ) {
    let shouldCallNow = state.withLock { state in
      guard state.isFinished == false else { return true }
      state.completionObservers[UUID()] = observer
      return false
    }
    if shouldCallNow {
      observer()
    }
  }

  package func cancel() {
    let snapshot:
      (
        tasks: [Task<Void, Never>],
        scopes: [EffectCancellationScope],
        sharedCompletions: [UUID: FlowTaskCompletion],
        didCancel: Bool
      ) = state.withLock { state in
        guard state.isCancelled == false, state.isFinished == false else {
          return ([], [], [:], false)
        }
        state.isCancelled = true
        let liveScopes = state.cancellationScopes.compactMap(\.value.value)
        state.cancellationScopes = state.cancellationScopes.filter { $0.value.value != nil }
        let sharedCompletions = state.sharedCompletions
        state.sharedCompletions.removeAll(keepingCapacity: false)
        return (Array(state.tasks.values), liveScopes, sharedCompletions, true)
      }
    for scope in snapshot.scopes {
      scope.cancelAll()
    }
    if snapshot.didCancel {
      onCancel?(dispatchID)
    }
    for task in snapshot.tasks {
      task.cancel()
    }
    for (token, completion) in snapshot.sharedCompletions {
      completion.removeObserver(token)
      endActivity(token)
    }
  }

  package func finish() async {
    await withCheckedContinuation { continuation in
      let shouldResume = state.withLock { state in
        guard state.activities.isEmpty == false, state.isFinished == false else { return true }
        state.waiters.append(continuation)
        return false
      }
      if shouldResume {
        continuation.resume()
      }
    }
  }

  deinit {
    outputCapture?.finish()
  }
}
