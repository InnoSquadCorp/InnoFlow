// MARK: - TestStore.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import InnoFlow
import SwiftUI

#if canImport(Testing)
  import Testing
#elseif canImport(XCTest)
  import XCTest
#endif

private actor ActionQueue<Action: Sendable> {
  private var buffer: [Action] = []
  private var waiters: [UUID: CheckedContinuation<Action?, Never>] = [:]

  func enqueue(_ action: Action) {
    if let waiterID = waiters.keys.first,
      let continuation = waiters.removeValue(forKey: waiterID)
    {
      continuation.resume(returning: action)
      return
    }

    buffer.append(action)
  }

  func next() async -> Action? {
    if !buffer.isEmpty {
      return buffer.removeFirst()
    }

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

  func popBuffered() -> Action? {
    guard !buffer.isEmpty else { return nil }
    return buffer.removeFirst()
  }

  private func cancelWaiter(_ waiterID: UUID) {
    guard let continuation = waiters.removeValue(forKey: waiterID) else { return }
    continuation.resume(returning: nil)
  }
}

@MainActor
private final class TestStoreRunEndpoint<Action: Sendable> {
  private let isTaskActiveImpl: (UUID) -> Bool
  private let finishTrackedTaskImpl: (UUID, EffectID?) -> Void

  init(
    isTaskActive: @escaping (UUID) -> Bool,
    finishTrackedTask: @escaping (UUID, EffectID?) -> Void
  ) {
    self.isTaskActiveImpl = isTaskActive
    self.finishTrackedTaskImpl = finishTrackedTask
  }

  func isTaskActive(token: UUID) -> Bool {
    isTaskActiveImpl(token)
  }

  func finishTrackedTask(token: UUID, cancellationID: EffectID?) {
    finishTrackedTaskImpl(token, cancellationID)
  }
}

private actor TestStoreRunBridge<Action: Sendable> {
  private let endpoint: TestStoreRunEndpoint<Action>
  private let queue: ActionQueue<Action>
  private let token: UUID
  private let cancellationID: EffectID?

  init(
    endpoint: TestStoreRunEndpoint<Action>,
    queue: ActionQueue<Action>,
    token: UUID,
    cancellationID: EffectID?
  ) {
    self.endpoint = endpoint
    self.queue = queue
    self.token = token
    self.cancellationID = cancellationID
  }

  func emit(_ action: Action) async {
    guard await endpoint.isTaskActive(token: token) else { return }
    await queue.enqueue(action)
  }

  func finish() async {
    await endpoint.finishTrackedTask(token: token, cancellationID: cancellationID)
  }
}

private actor TestStoreRunStartGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard isOpen == false else { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func open() {
    guard isOpen == false else { return }
    isOpen = true
    let continuations = waiters
    waiters.removeAll()
    continuations.forEach { $0.resume() }
  }
}

/// A deterministic test harness for InnoFlow v2 reducers.
///
/// `TestStore` asserts state transitions and captures effect-emitted actions.
/// Timeout behavior is controlled with structured-concurrency races,
/// avoiding arbitrary polling sleeps. Follow-up actions are observed using the
/// same queue-based vocabulary as `Store`.
@MainActor
public final class TestStore<R: Reducer> where R.State: Equatable {

  // MARK: - Properties

  public private(set) var state: R.State

  private let reducer: R
  private let effectTimeout: Duration
  private let diffLineLimit: Int
  private let wallClock = ContinuousClock()
  private let manualClock: ManualTestClock?
  private let queue = ActionQueue<R.Action>()

  private var runningTasks: [UUID: Task<Void, Never>] = [:]
  private var taskIDsByEffectID: [EffectID: Set<UUID>] = [:]
  private var debounceDelayTasksByID: [EffectID: Task<Void, Never>] = [:]
  private var debounceGenerationByID: [EffectID: UUID] = [:]
  package let throttleState = ThrottleStateMap<R.Action>()

  private var walker: EffectWalker<TestStore<R>> {
    EffectWalker(driver: self)
  }

  // MARK: - Initialization

  public init(
    reducer: R,
    initialState: R.State,
    clock: ManualTestClock? = nil,
    effectTimeout: Duration = .seconds(1),
    diffLineLimit: Int? = nil
  ) {
    self.reducer = reducer
    self.state = initialState
    self.manualClock = clock
    self.effectTimeout = effectTimeout
    self.diffLineLimit = resolveDiffLineLimit(
      explicit: diffLineLimit,
      environment: ProcessInfo.processInfo.environment
    )
  }

  public convenience init(
    reducer: R,
    initialState: R.State? = nil,
    clock: ManualTestClock? = nil,
    effectTimeout: Duration = .seconds(1),
    diffLineLimit: Int? = nil
  ) where R.State: DefaultInitializable {
    self.init(
      reducer: reducer,
      initialState: initialState ?? R.State(),
      clock: clock,
      effectTimeout: effectTimeout,
      diffLineLimit: diffLineLimit
    )
  }

  isolated deinit {
    for task in runningTasks.values {
      task.cancel()
    }
    for task in debounceDelayTasksByID.values {
      task.cancel()
    }
    throttleState.clearAll()
  }

  // MARK: - Public APIs

  public func send(
    _ action: R.Action,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    file: StaticString = #file,
    line: UInt = #line
  ) async {
    var expectedState = state
    updateExpectedState?(&expectedState)

    let effect = reducer.reduce(into: &state, action: action)

    if updateExpectedState != nil, state != expectedState {
      let diffSection = renderStateDiff(
        expected: expectedState,
        actual: state,
        lineLimit: diffLineLimit
      ).map {
        "Diff:\n\($0)\n\n"
      } ?? ""
      testStoreAssertionFailure(
        """
        State mismatch after action.

        \(diffSection)Expected:
        \(expectedState)

        Actual:
        \(state)
        """,
        file: file,
        line: line
      )
    }

    await walker.walk(effect, awaited: false)
  }

  public func receive(
    _ expectedAction: R.Action,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    file: StaticString = #file,
    line: UInt = #line
  ) async where R.Action: Equatable {
    guard let action = await nextActionWithinTimeout() else {
      testStoreAssertionFailure(
        """
        Expected to receive action:
        \(expectedAction)

        But timed out after \(effectTimeout).
        """,
        file: file,
        line: line
      )
      return
    }

    if action != expectedAction {
      testStoreAssertionFailure(
        """
        Received unexpected action.

        Expected:
        \(expectedAction)

        Received:
        \(action)
        """,
        file: file,
        line: line
      )
      return
    }

    var expectedState = state
    updateExpectedState?(&expectedState)

    let effect = reducer.reduce(into: &state, action: action)

    if updateExpectedState != nil, state != expectedState {
      let diffSection = renderStateDiff(
        expected: expectedState,
        actual: state,
        lineLimit: diffLineLimit
      ).map {
        "Diff:\n\($0)\n\n"
      } ?? ""
      testStoreAssertionFailure(
        """
        State mismatch after receiving action.

        \(diffSection)Expected:
        \(expectedState)

        Actual:
        \(state)
        """,
        file: file,
        line: line
      )
    }

    await walker.walk(effect, awaited: false)
  }

  public func assertNoMoreActions(
    file: StaticString = #file,
    line: UInt = #line
  ) async {
    if let buffered = await queue.popBuffered() {
      testStoreAssertionFailure(
        """
        Unhandled received action:
        \(buffered)

        All effect actions should be verified with `receive(_:assert:)`.
        """,
        file: file,
        line: line
      )
      return
    }

    let queue = self.queue
    let leftover = await withTimeout(effectTimeout) {
      await queue.next()
    }

    if let leftover {
      testStoreAssertionFailure(
        """
        Unhandled received action:
        \(leftover)

        All effect actions should be verified with `receive(_:assert:)`.
        """,
        file: file,
        line: line
      )
    }
  }

  public func cancelEffects(identifiedBy id: EffectID) async {
    cancelEffectsSynchronously(identifiedBy: id)
  }

  public func cancelAllEffects() async {
    cancelAllEffectsSynchronously()
  }

  fileprivate func makeScopedTestStore<ChildState: Equatable, ChildAction>(
    state: WritableKeyPath<R.State, ChildState>,
    extractAction: @escaping @Sendable (R.Action) -> ChildAction?,
    embedAction: @escaping @Sendable (ChildAction) -> R.Action
  ) -> ScopedTestStore<R, ChildState, ChildAction> {
    ScopedTestStore(
      parent: self,
      stateReader: { $0[keyPath: state] },
      expectedStateUpdater: { rootState, update in
        var childState = rootState[keyPath: state]
        update(&childState)
        rootState[keyPath: state] = childState
      },
      actionExtractor: extractAction,
      actionEmbedder: embedAction
    )
  }

  public func scope<ChildState: Equatable, ChildAction>(
    state: WritableKeyPath<R.State, ChildState>,
    action: CasePath<R.Action, ChildAction>
  ) -> ScopedTestStore<R, ChildState, ChildAction> {
    makeScopedTestStore(
      state: state,
      extractAction: action.extract,
      embedAction: action.embed
    )
  }

  fileprivate func makeScopedCollectionTestStore<CollectionState, ChildAction>(
    collection: WritableKeyPath<R.State, CollectionState>,
    id: CollectionState.Element.ID,
    extractAction: @escaping @Sendable (R.Action) -> (CollectionState.Element.ID, ChildAction)?,
    embedAction: @escaping @Sendable (CollectionState.Element.ID, ChildAction) -> R.Action
  ) -> ScopedTestStore<R, CollectionState.Element, ChildAction>
  where
    CollectionState: MutableCollection & RandomAccessCollection,
    CollectionState.Element: Identifiable & Equatable,
    CollectionState.Element.ID: Sendable
  {
    let staleMessage = scopedStoreFailureMessage(
      parentType: R.self,
      childType: CollectionState.Element.self,
      stableID: AnyHashable(id),
      kind: .collectionEntryRemoved
    )

    return ScopedTestStore(
      parent: self,
      stateReader: { rootState in
        guard let element = rootState[keyPath: collection].first(where: { $0.id == id }) else {
          preconditionFailure(staleMessage)
        }
        return element
      },
      expectedStateUpdater: { rootState, update in
        var collectionState = rootState[keyPath: collection]
        guard let index = collectionState.firstIndex(where: { $0.id == id }) else {
          preconditionFailure(staleMessage)
        }
        update(&collectionState[index])
        rootState[keyPath: collection] = collectionState
      },
      actionExtractor: { rootAction in
        guard let (receivedID, childAction) = extractAction(rootAction), receivedID == id else {
          return nil
        }
        return childAction
      },
      actionEmbedder: { childAction in
        embedAction(id, childAction)
      },
      stableID: AnyHashable(id)
    )
  }

  public func scope<CollectionState, ChildAction>(
    collection: WritableKeyPath<R.State, CollectionState>,
    id: CollectionState.Element.ID,
    action: CollectionActionPath<R.Action, CollectionState.Element.ID, ChildAction>
  ) -> ScopedTestStore<R, CollectionState.Element, ChildAction>
  where
    CollectionState: MutableCollection & RandomAccessCollection,
    CollectionState.Element: Identifiable & Equatable,
    CollectionState.Element.ID: Sendable
  {
    makeScopedCollectionTestStore(
      collection: collection,
      id: id,
      extractAction: action.extract,
      embedAction: action.embed
    )
  }

  fileprivate func applyScopedAction(_ action: R.Action) -> EffectTask<R.Action> {
    reducer.reduce(into: &state, action: action)
  }

  fileprivate func walkScopedEffect(_ effect: EffectTask<R.Action>) async {
    await walker.walk(effect, awaited: false)
  }

  fileprivate func nextScopedActionWithinTimeout() async -> R.Action? {
    await nextActionWithinTimeout()
  }

  fileprivate var scopedEffectTimeout: Duration {
    effectTimeout
  }

  package var resolvedDiffLineLimit: Int {
    diffLineLimit
  }
  // MARK: - Task Management

  private func startRunTask(
    priority: TaskPriority?,
    operation: @escaping @Sendable (Send<R.Action>, EffectContext) async -> Void,
    context: EffectExecutionContext?
  ) -> Task<Void, Never> {
    let token = UUID()
    let startGate = TestStoreRunStartGate()
    let endpoint = TestStoreRunEndpoint<R.Action>(
      isTaskActive: { [weak self] token in
        self?.isRunTaskActive(token: token) ?? false
      },
      finishTrackedTask: { [weak self] token, cancellationID in
        self?.finishTrackedRunTask(token: token, cancellationID: cancellationID)
      }
    )
    let runBridge = TestStoreRunBridge(
      endpoint: endpoint,
      queue: queue,
      token: token,
      cancellationID: context?.cancellationID
    )
    let manualClock = self.manualClock
    let wallClock = self.wallClock

    let task = Task(priority: priority) {
      await startGate.wait()

      let send = Send<R.Action> { action in
        await runBridge.emit(action)
      }

      let effectContext = EffectContext(
        now: {
          if let manualClock {
            return await manualClock.now
          }
          return wallClock.now
        },
        sleep: { duration in
          if let manualClock {
            try await manualClock.sleep(for: duration)
          } else {
            try await Task.sleep(for: duration)
          }
        },
        isCancelled: {
          Task.isCancelled
        },
        checkCancellation: {
          let isTaskActive = await MainActor.run {
            endpoint.isTaskActive(token: token)
          }
          if Task.isCancelled || isTaskActive == false {
            throw CancellationError()
          }
        }
      )

      await operation(send, effectContext)
      await runBridge.finish()
    }

    runningTasks[token] = task

    if let id = context?.cancellationID {
      taskIDsByEffectID[id, default: []].insert(token)
    }

    Task {
      await startGate.open()
    }

    return task
  }

  private func cancelEffectsSynchronously(identifiedBy id: EffectID) {
    debounceDelayTasksByID.removeValue(forKey: id)?.cancel()
    debounceGenerationByID.removeValue(forKey: id)
    throttleState.clearState(for: id)
    guard let ids = taskIDsByEffectID.removeValue(forKey: id) else { return }

    for token in ids {
      runningTasks.removeValue(forKey: token)?.cancel()
    }
  }

  private func cancelAllEffectsSynchronously() {
    for task in runningTasks.values {
      task.cancel()
    }
    for task in debounceDelayTasksByID.values {
      task.cancel()
    }
    throttleState.clearAll()
    runningTasks.removeAll()
    taskIDsByEffectID.removeAll()
    debounceDelayTasksByID.removeAll()
    debounceGenerationByID.removeAll()
  }

  private func removeTrackedTask(token: UUID, cancellationID: EffectID?) {
    runningTasks.removeValue(forKey: token)

    guard let id = cancellationID,
      var tokens = taskIDsByEffectID[id]
    else { return }
    tokens.remove(token)
    if tokens.isEmpty {
      taskIDsByEffectID.removeValue(forKey: id)
    } else {
      taskIDsByEffectID[id] = tokens
    }
  }

  // MARK: - Receiving

  private func nextActionWithinTimeout() async -> R.Action? {
    let queue = self.queue
    return await withTimeout(effectTimeout) {
      await queue.next()
    }
  }

  private func withTimeout<T: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async -> T?
  ) async -> T? {
    await withTaskGroup(of: T?.self) { group in
      group.addTask {
        await operation()
      }

      group.addTask {
        try? await Task.sleep(for: timeout)
        return nil
      }

      let result = await group.next() ?? nil
      group.cancelAll()
      return result
    }
  }

  private func isRunTaskActive(token: UUID) -> Bool {
    runningTasks[token] != nil
  }

  private func finishTrackedRunTask(token: UUID, cancellationID: EffectID?) {
    removeTrackedTask(token: token, cancellationID: cancellationID)
  }

  private func sleepForDriver(_ duration: Duration) async throws {
    if let manualClock {
      try await manualClock.sleep(for: duration)
    } else {
      try await Task.sleep(for: duration)
    }
  }
}

// MARK: - EffectDriver Conformance

extension TestStore: EffectDriver {
  package typealias Action = R.Action

  package func deliverAction(_ action: R.Action, context: EffectExecutionContext?) {
    Task {
      await queue.enqueue(action)
    }
  }

  package func startRun(
    priority: TaskPriority?,
    operation: @escaping @Sendable (Send<R.Action>, EffectContext) async -> Void,
    context: EffectExecutionContext?,
    awaited: Bool
  ) async {
    let task = startRunTask(
      priority: priority,
      operation: operation,
      context: context
    )

    if awaited {
      _ = await task.result
    }
  }

  package func cancelEffects(id: EffectID, context: EffectExecutionContext?) async {
    cancelEffectsSynchronously(identifiedBy: id)
  }

  package func cancelInFlightEffects(id: EffectID, context: EffectExecutionContext?) async {
    cancelEffectsSynchronously(identifiedBy: id)
  }

  package func shouldProceed(context: EffectExecutionContext?) -> Bool {
    true
  }

  package func debounce(
    _ nested: EffectTask<R.Action>,
    id: EffectID,
    interval: Duration,
    context: EffectExecutionContext?,
    awaited: Bool,
    recurse: @escaping @MainActor @Sendable (
      EffectTask<R.Action>, EffectExecutionContext?, Bool
    ) async -> Void
  ) async {
    debounceDelayTasksByID[id]?.cancel()
    cancelEffectsSynchronously(identifiedBy: id)

    let generation = UUID()
    debounceGenerationByID[id] = generation

    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if self.debounceGenerationByID[id] == generation {
          self.debounceDelayTasksByID.removeValue(forKey: id)
          self.debounceGenerationByID.removeValue(forKey: id)
        }
      }

      do {
        try await self.sleepForDriver(interval)
      } catch {
        return
      }

      guard !Task.isCancelled else { return }
      guard self.debounceGenerationByID[id] == generation else { return }
      await recurse(nested, context, true)
    }

    debounceDelayTasksByID[id] = task

    if awaited {
      _ = await task.result
    }
  }

  package func scheduleTrailingDrain(
    for id: EffectID,
    interval: Duration,
    recurse: @escaping @MainActor @Sendable (
      EffectTask<R.Action>, EffectExecutionContext?, Bool
    ) async -> Void
  ) {
    throttleState.cancelTrailingTask(for: id)
    let generation = throttleState.nextGeneration(for: id)
    let task = Task { [weak self] in
      guard let self else { return }
      do {
        try await self.sleepForDriver(interval)
      } catch {
        return
      }
      guard self.throttleState.generation(for: id) == generation else { return }
      defer {
        if self.throttleState.generation(for: id) == generation {
          self.throttleState.clearState(for: id)
        }
      }
      guard let pending = self.throttleState.pending(for: id) else { return }
      await recurse(pending.effect, pending.context, false)
    }
    throttleState.setTrailingTask(task, for: id)
  }

  package var now: ContinuousClock.Instant {
    get async {
      if let manualClock {
        return await manualClock.now
      }
      return wallClock.now
    }
  }

  package func runConcurrently(
    _ children: [EffectTask<R.Action>],
    context: EffectExecutionContext?,
    awaited: Bool,
    recurse: @escaping @MainActor @Sendable (
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
    recurse: @escaping @MainActor @Sendable (
      EffectTask<R.Action>, EffectExecutionContext?, Bool
    ) async -> Void
  ) async {
    if awaited {
      for child in children {
        await recurse(child, context, true)
      }
    } else {
      let token = UUID()
      let cancellationID = context?.cancellationID
      let task = Task { @MainActor [weak self] in
        guard let self else { return }
        defer {
          self.removeTrackedTask(token: token, cancellationID: cancellationID)
        }
        for child in children {
          guard !Task.isCancelled else { break }
          await recurse(child, context, true)
        }
      }
      runningTasks[token] = task
      if let id = cancellationID {
        taskIDsByEffectID[id, default: []].insert(token)
      }
    }
  }
}

@dynamicMemberLookup
@MainActor
public struct ScopedTestStore<Root: Reducer, ChildState: Equatable, ChildAction>
where Root.State: Equatable {
  private let parent: TestStore<Root>
  private let diffLineLimit: Int
  private let stateReader: (Root.State) -> ChildState
  private let expectedStateUpdater: (inout Root.State, (inout ChildState) -> Void) -> Void
  private let actionExtractor: @Sendable (Root.Action) -> ChildAction?
  private let actionEmbedder: @Sendable (ChildAction) -> Root.Action
  private let failureContext: String?
  private let stateMismatchLabel: String

  public var state: ChildState {
    stateReader(parent.state)
  }

  public subscript<Value>(dynamicMember keyPath: KeyPath<ChildState, Value>) -> Value {
    state[keyPath: keyPath]
  }

  public subscript<Value>(dynamicMember keyPath: KeyPath<ChildState, BindableProperty<Value>>) -> Value
  where Value: Equatable & Sendable {
    state[keyPath: keyPath].value
  }

  init(
    parent: TestStore<Root>,
    stateReader: @escaping (Root.State) -> ChildState,
    expectedStateUpdater: @escaping (inout Root.State, (inout ChildState) -> Void) -> Void,
    actionExtractor: @escaping @Sendable (Root.Action) -> ChildAction?,
    actionEmbedder: @escaping @Sendable (ChildAction) -> Root.Action,
    stableID: AnyHashable? = nil
  ) {
    self.parent = parent
    self.diffLineLimit = parent.resolvedDiffLineLimit
    self.stateReader = stateReader
    self.expectedStateUpdater = expectedStateUpdater
    self.actionExtractor = actionExtractor
    self.actionEmbedder = actionEmbedder
    self.failureContext = scopedTestStoreFailureContext(stableID: stableID)
    self.stateMismatchLabel = scopedTestStoreStateMismatchLabel(stableID: stableID)
  }

  public func send(
    _ action: ChildAction,
    assert updateExpectedState: ((inout ChildState) -> Void)? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    var expectedState = state
    updateExpectedState?(&expectedState)

    let effect = parent.applyScopedAction(actionEmbedder(action))
    let actualState = stateReader(parent.state)

    if updateExpectedState != nil, actualState != expectedState {
      reportStateMismatch(
        expected: expectedState,
        actual: actualState,
        eventDescription: "mismatch after action.",
        file: file,
        line: line
      )
    }

    await parent.walkScopedEffect(effect)
  }

  public func receive(
    _ expectedAction: ChildAction,
    assert updateExpectedState: ((inout ChildState) -> Void)? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async where ChildAction: Equatable {
    guard let rootAction = await parent.nextScopedActionWithinTimeout() else {
      testStoreAssertionFailure(
        decorateFailure(
          """
        Expected to receive child action:
        \(expectedAction)

        But timed out after \(parent.scopedEffectTimeout).
        """
        ),
        file: file,
        line: line
      )
      return
    }

    guard let childAction = actionExtractor(rootAction) else {
      testStoreAssertionFailure(
        decorateFailure(
          """
        Received unexpected parent action for scoped test store.

        Expected child action:
        \(expectedAction)

        Received parent action:
        \(rootAction)
        """
        ),
        file: file,
        line: line
      )
      return
    }

    if childAction != expectedAction {
      testStoreAssertionFailure(
        decorateFailure(
          """
        Received unexpected child action.

        Expected:
        \(expectedAction)

        Received:
        \(childAction)
        """
        ),
        file: file,
        line: line
      )
      return
    }

    var expectedState = state
    updateExpectedState?(&expectedState)

    let effect = parent.applyScopedAction(rootAction)
    let actualState = stateReader(parent.state)

    if updateExpectedState != nil, actualState != expectedState {
      reportStateMismatch(
        expected: expectedState,
        actual: actualState,
        eventDescription: "mismatch after receiving action.",
        file: file,
        line: line
      )
    }

    await parent.walkScopedEffect(effect)
  }

  public func assert(
    _ updateExpectedState: (inout ChildState) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    var expectedState = state
    updateExpectedState(&expectedState)
    let actualState = stateReader(parent.state)

    if actualState != expectedState {
      reportStateMismatch(
        expected: expectedState,
        actual: actualState,
        eventDescription: "mismatch.",
        file: file,
        line: line
      )
    }
  }

  public func assertNoMoreActions(
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    await parent.assertNoMoreActions(file: file, line: line)
  }

  package var resolvedDiffLineLimit: Int {
    diffLineLimit
  }

  private func decorateFailure(_ message: String) -> String {
    guard let failureContext else { return message }
    return "\(failureContext)\n\n\(message)"
  }

  private func reportStateMismatch(
    expected: ChildState,
    actual: ChildState,
    eventDescription: String,
    file: StaticString,
    line: UInt
  ) {
    let diffSection = renderStateDiff(
      expected: expected,
      actual: actual,
      lineLimit: diffLineLimit
    ).map {
      "Diff:\n\($0)\n\n"
    } ?? ""

    testStoreAssertionFailure(
      decorateFailure(
        """
        \(stateMismatchLabel) \(eventDescription)

        \(diffSection)Expected:
        \(expected)

        Actual:
        \(actual)
        """
      ),
      file: file,
      line: line
    )
  }
}

// MARK: - Assertion Helper

func testStoreAssertionFailure(
  _ message: String,
  file: StaticString,
  line: UInt
) {
  #if DEBUG
    print("❌ TestStore Assertion Failed:")
    print(message)
    print("File: \(file), Line: \(line)")
  #endif

  #if canImport(Testing)
    Issue.record(
      TestStoreAssertionIssue(
        message: "\(file):\(line): \(message)"
      )
    )
  #elseif canImport(XCTest)
    XCTFail(message, file: file, line: line)
  #else
    Swift.assertionFailure(message, file: file, line: line)
  #endif
}

func scopedTestStoreFailureContext(stableID: AnyHashable?) -> String? {
  guard let stableID else { return nil }
  return "Scoped collection element (id: \(String(describing: stableID)))"
}

func scopedTestStoreStateMismatchLabel(stableID: AnyHashable?) -> String {
  guard let failureContext = scopedTestStoreFailureContext(stableID: stableID) else {
    return "Scoped state"
  }
  return "\(failureContext) state"
}

#if canImport(Testing)
  private struct TestStoreAssertionIssue: Error, Sendable, CustomStringConvertible {
    let message: String
    var description: String { message }
  }
#endif
