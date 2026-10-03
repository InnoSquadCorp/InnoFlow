// MARK: - ScopedTestStore.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
@_exported public import InnoFlowCore

private enum ScopedTestStoreActionMatch<ChildAction, Value> {
  case matched(Value)
  case mismatchedParent
  case mismatchedChild(ChildAction)
}

@dynamicMemberLookup
@MainActor
public struct ScopedTestStore<Root: Reducer, ChildState: Equatable, ChildAction>
where Root.State: Equatable {
  private let parent: TestStore<Root>
  private let diffLineLimit: Int
  private let stateReader: (Root.State) -> ChildState
  private let expectedStateUpdater: (inout Root.State, (inout ChildState) -> Void) -> Bool
  private let actionExtractor: @Sendable (Root.Action) -> ChildAction?
  private let actionEmbedder: @Sendable (ChildAction) -> Root.Action
  private let failureContext: String?
  private let stateMismatchLabel: String

  public var state: ChildState {
    stateReader(parent.state)
  }

  public var exhaustivity: Exhaustivity {
    get { parent.exhaustivity }
    nonmutating set { parent.exhaustivity = newValue }
  }

  public subscript<Value>(dynamicMember keyPath: KeyPath<ChildState, Value>) -> Value {
    state[keyPath: keyPath]
  }

  public subscript<Value>(dynamicMember keyPath: KeyPath<ChildState, BindableProperty<Value>>)
    -> Value
  where Value: Equatable & Sendable {
    state[keyPath: keyPath].value
  }

  init(
    parent: TestStore<Root>,
    stateReader: @escaping (Root.State) -> ChildState,
    expectedStateUpdater: @escaping (inout Root.State, (inout ChildState) -> Void) -> Bool,
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

  /// Sends a child action after applying the parent harness's exhaustivity
  /// policy to any buffered effect actions.
  @discardableResult
  public func send(
    _ action: ChildAction,
    assert updateExpectedState: ((inout ChildState) -> Void)? = nil,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) async -> TestStoreDispatch {
    await send(
      action, assert: updateExpectedState,
      location: .init(fileID: fileID, filePath: filePath, line: line, column: column))
  }

  /// Compatibility overload for an explicitly supplied legacy source file.
  @discardableResult
  public func send(
    _ action: ChildAction,
    assert updateExpectedState: ((inout ChildState) -> Void)? = nil,
    file: StaticString,
    line: UInt = #line
  ) async -> TestStoreDispatch {
    await send(
      action, assert: updateExpectedState,
      location: .init(fileID: file, filePath: file, line: line, column: 1))
  }

  @discardableResult
  package func send(
    _ action: ChildAction,
    assert updateExpectedState: ((inout ChildState) -> Void)? = nil,
    location: TestStoreSourceLocation
  ) async -> TestStoreDispatch {
    await parent.prepareForSend(location: location)
    let dispatch = parent.makeDispatch()
    defer { dispatch.tracker.endActivity(dispatch.activity) }
    let previousRootState = parent.state
    // Preserve the stale-handle contract before routing any action. A valid
    // collection child may remove itself during reduction; that distinct
    // post-reduction case is handled by the failable expected-state updater.
    _ = stateReader(previousRootState)

    let effect = parent.applyScopedAction(
      actionEmbedder(action),
      source: .scopedSend,
      location: location
    )
    parent.assertStateTransition(
      from: previousRootState,
      expectedStateMutation: rootStateUpdater(from: updateExpectedState),
      mismatchLabel: "Scoped root state",
      eventDescription: "mismatch after action.",
      failureContext: failureContext,
      exhaustiveGuidance: scopedExhaustivityGuidance,
      location: location
    )

    await parent.walkScopedEffect(effect, flowTaskTracker: dispatch.tracker, location: location)
    return dispatch.task
  }

  public func receive(
    _ expectedAction: ChildAction,
    assert updateExpectedState: ((inout ChildState) -> Void)? = nil,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) async where ChildAction: Equatable {
    await receive(
      expectedAction, assert: updateExpectedState,
      location: .init(fileID: fileID, filePath: filePath, line: line, column: column))
  }

  /// Compatibility overload for an explicitly supplied legacy source file.
  public func receive(
    _ expectedAction: ChildAction,
    assert updateExpectedState: ((inout ChildState) -> Void)? = nil,
    file: StaticString,
    line: UInt = #line
  ) async where ChildAction: Equatable {
    await receive(
      expectedAction, assert: updateExpectedState,
      location: .init(fileID: file, filePath: file, line: line, column: 1))
  }

  package func receive(
    _ expectedAction: ChildAction,
    assert updateExpectedState: ((inout ChildState) -> Void)? = nil,
    location: TestStoreSourceLocation
  ) async where ChildAction: Equatable {
    await receiveExact(
      expectedAction,
      timeout: nil,
      assert: updateExpectedState,
      location: location
    )
  }

  /// Receives an exact child action using one total timeout for this assertion.
  /// In non-exhaustive mode, parent and non-matching child actions are reduced
  /// while receiving continues.
  public func receive(
    _ expectedAction: ChildAction,
    timeout: Duration,
    assert updateExpectedState: ((inout ChildState) -> Void)? = nil,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) async where ChildAction: Equatable {
    await receive(
      expectedAction, timeout: timeout, assert: updateExpectedState,
      location: .init(fileID: fileID, filePath: filePath, line: line, column: column))
  }

  /// Compatibility overload for an explicitly supplied legacy source file.
  public func receive(
    _ expectedAction: ChildAction,
    timeout: Duration,
    assert updateExpectedState: ((inout ChildState) -> Void)? = nil,
    file: StaticString,
    line: UInt = #line
  ) async where ChildAction: Equatable {
    await receive(
      expectedAction, timeout: timeout, assert: updateExpectedState,
      location: .init(fileID: file, filePath: file, line: line, column: 1))
  }

  package func receive(
    _ expectedAction: ChildAction,
    timeout: Duration,
    assert updateExpectedState: ((inout ChildState) -> Void)? = nil,
    location: TestStoreSourceLocation
  ) async where ChildAction: Equatable {
    await receiveExact(
      expectedAction,
      timeout: timeout,
      assert: updateExpectedState,
      location: location
    )
  }

  /// Receives the next child action, requires it to match a case path, and
  /// returns its payload. In non-exhaustive mode, parent and non-matching child
  /// actions are reduced while receiving continues under one total timeout.
  @discardableResult
  public func receive<Value>(
    _ path: CasePath<ChildAction, Value>,
    caseName: String? = nil,
    timeout: Duration? = nil,
    assert updateExpectedState: ((inout ChildState, Value) -> Void)? = nil,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) async -> Value? {
    await receive(
      path, caseName: caseName, timeout: timeout, assert: updateExpectedState,
      location: .init(fileID: fileID, filePath: filePath, line: line, column: column))
  }

  /// Compatibility overload for an explicitly supplied legacy source file.
  @discardableResult
  public func receive<Value>(
    _ path: CasePath<ChildAction, Value>,
    caseName: String? = nil,
    timeout: Duration? = nil,
    assert updateExpectedState: ((inout ChildState, Value) -> Void)? = nil,
    file: StaticString,
    line: UInt = #line
  ) async -> Value? {
    await receive(
      path, caseName: caseName, timeout: timeout, assert: updateExpectedState,
      location: .init(fileID: file, filePath: file, line: line, column: 1))
  }

  @discardableResult
  package func receive<Value>(
    _ path: CasePath<ChildAction, Value>,
    caseName: String? = nil,
    timeout: Duration? = nil,
    assert updateExpectedState: ((inout ChildState, Value) -> Void)? = nil,
    location: TestStoreSourceLocation
  ) async -> Value? {
    let result = await receiveResult(timeout: timeout, location: location) { action in
      switch path.extract(action) {
      case .some(let value):
        return .matched(value)
      case .none:
        return .mismatched
      }
    }
    let expectation = caseName.map { "case path '\($0)'" } ?? "the supplied case path"

    switch result {
    case .matched(let rootAction, .matched(let value)):
      let stateAssertion: ((inout ChildState) -> Void)? = updateExpectedState.map { update in
        { state in update(&state, value) }
      }
      await applyReceivedRootAction(
        rootAction,
        assert: stateAssertion,
        location: location
      )
      return .some(value)

    case .matched(let rootAction, .mismatchedParent), .mismatched(let rootAction):
      reportScopedParentMismatch(
        rootAction: rootAction.action,
        expectation: expectation,
        location: location
      )
      return nil

    case .matched(_, .mismatchedChild(let childAction)):
      reportScopedChildMismatch(
        childAction: childAction,
        expectation: expectation,
        location: location
      )
      return nil

    case .timedOut(let resolvedTimeout):
      parent.issueReporter(
        decorateFailure(
          """
          Expected to receive a child action matching \(expectation).

          But timed out after \(resolvedTimeout).
          """
        ),
        location
      )
      return nil

    case .cancelled:
      return nil
    }
  }

  /// Receives an exact root output through the shared root queue.
  public func receiveOutput(
    _ expectedOutput: Root.Output,
    timeout: Duration? = nil,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) async where Root.Output: Equatable {
    await parent.receiveOutput(
      expectedOutput, timeout: timeout,
      location: .init(fileID: fileID, filePath: filePath, line: line, column: column))
  }

  /// Compatibility overload for an explicitly supplied legacy source file.
  public func receiveOutput(
    _ expectedOutput: Root.Output,
    timeout: Duration? = nil,
    file: StaticString,
    line: UInt = #line
  ) async where Root.Output: Equatable {
    await parent.receiveOutput(
      expectedOutput, timeout: timeout,
      location: .init(fileID: file, filePath: file, line: line, column: 1))
  }

  /// Receives a root output matching a predicate under the root exhaustivity
  /// policy and one total timeout. Cancellation does not report a timeout.
  @discardableResult
  public func receiveOutput(
    where predicate: (Root.Output) -> Bool,
    description: String? = nil,
    timeout: Duration? = nil,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) async -> Root.Output? {
    await parent.receiveOutput(
      where: predicate, description: description, timeout: timeout,
      location: .init(fileID: fileID, filePath: filePath, line: line, column: column))
  }

  /// Compatibility overload for an explicitly supplied legacy source file.
  @discardableResult
  public func receiveOutput(
    where predicate: (Root.Output) -> Bool,
    description: String? = nil,
    timeout: Duration? = nil,
    file: StaticString,
    line: UInt = #line
  ) async -> Root.Output? {
    await parent.receiveOutput(
      where: predicate, description: description, timeout: timeout,
      location: .init(fileID: file, filePath: file, line: line, column: 1))
  }

  /// Receives a root reducer output while asserting through this scoped test
  /// handle. Output ownership remains at the root reducer, so the path is
  /// explicitly rooted in `Root.Output` and no duplicate scoped queue exists.
  ///
  /// Exhaustive and non-exhaustive mismatch behavior is identical to
  /// `TestStore.receiveOutput`, including preservation of optional `nil`
  /// payloads as `.some(nil)`.
  @discardableResult
  public func receiveOutput<Value>(
    _ path: CasePath<Root.Output, Value>,
    caseName: String? = nil,
    timeout: Duration? = nil,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) async -> Value? {
    await receiveOutput(
      path, caseName: caseName, timeout: timeout,
      location: .init(fileID: fileID, filePath: filePath, line: line, column: column))
  }

  /// Compatibility overload for an explicitly supplied legacy source file.
  @discardableResult
  public func receiveOutput<Value>(
    _ path: CasePath<Root.Output, Value>,
    caseName: String? = nil,
    timeout: Duration? = nil,
    file: StaticString,
    line: UInt = #line
  ) async -> Value? {
    await receiveOutput(
      path, caseName: caseName, timeout: timeout,
      location: .init(fileID: file, filePath: file, line: line, column: 1))
  }

  @discardableResult
  package func receiveOutput<Value>(
    _ path: CasePath<Root.Output, Value>,
    caseName: String? = nil,
    timeout: Duration? = nil,
    location: TestStoreSourceLocation
  ) async -> Value? {
    await parent.receiveMatchedOutput(
      expectation: caseName.map { "case path '\($0)'" } ?? "the supplied root output case path",
      timeout: timeout,
      location: location
    ) { output in
      switch path.extract(output) {
      case .some(let value): .matched(value)
      case .none: .mismatched
      }
    }
  }

  /// Receives and returns the next child action accepted by a predicate. In
  /// non-exhaustive mode, parent and rejected child actions are reduced while
  /// receiving continues under one total timeout.
  @discardableResult
  public func receive(
    where predicate: (ChildAction) -> Bool,
    description: String? = nil,
    timeout: Duration? = nil,
    assert updateExpectedState: ((inout ChildState, ChildAction) -> Void)? = nil,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) async -> ChildAction? {
    await receive(
      where: predicate, description: description, timeout: timeout, assert: updateExpectedState,
      location: .init(fileID: fileID, filePath: filePath, line: line, column: column))
  }

  /// Compatibility overload for an explicitly supplied legacy source file.
  @discardableResult
  public func receive(
    where predicate: (ChildAction) -> Bool,
    description: String? = nil,
    timeout: Duration? = nil,
    assert updateExpectedState: ((inout ChildState, ChildAction) -> Void)? = nil,
    file: StaticString,
    line: UInt = #line
  ) async -> ChildAction? {
    await receive(
      where: predicate, description: description, timeout: timeout, assert: updateExpectedState,
      location: .init(fileID: file, filePath: file, line: line, column: 1))
  }

  @discardableResult
  package func receive(
    where predicate: (ChildAction) -> Bool,
    description: String? = nil,
    timeout: Duration? = nil,
    assert updateExpectedState: ((inout ChildState, ChildAction) -> Void)? = nil,
    location: TestStoreSourceLocation
  ) async -> ChildAction? {
    let result = await receiveResult(timeout: timeout, location: location) { action in
      predicate(action) ? .matched(action) : .mismatched
    }
    let expectation = description.map { "predicate '\($0)'" } ?? "the supplied predicate"

    switch result {
    case .matched(let rootAction, .matched(let childAction)):
      let stateAssertion: ((inout ChildState) -> Void)? = updateExpectedState.map { update in
        { state in update(&state, childAction) }
      }
      await applyReceivedRootAction(
        rootAction,
        assert: stateAssertion,
        location: location
      )
      return .some(childAction)

    case .matched(let rootAction, .mismatchedParent), .mismatched(let rootAction):
      reportScopedParentMismatch(
        rootAction: rootAction.action,
        expectation: expectation,
        location: location
      )
      return nil

    case .matched(_, .mismatchedChild(let childAction)):
      reportScopedChildMismatch(
        childAction: childAction,
        expectation: expectation,
        location: location
      )
      return nil

    case .timedOut(let resolvedTimeout):
      parent.issueReporter(
        decorateFailure(
          """
          Expected to receive a child action satisfying \(expectation).

          But timed out after \(resolvedTimeout).
          """
        ),
        location
      )
      return nil

    case .cancelled:
      return nil
    }
  }

  private func receiveExact(
    _ expectedAction: ChildAction,
    timeout: Duration?,
    assert updateExpectedState: ((inout ChildState) -> Void)?,
    location: TestStoreSourceLocation
  ) async where ChildAction: Equatable {
    let result = await receiveResult(timeout: timeout, location: location) { childAction in
      childAction == expectedAction ? .matched(()) : .mismatched
    }

    switch result {
    case .matched(let rootAction, .matched):
      await applyReceivedRootAction(
        rootAction,
        assert: updateExpectedState,
        location: location
      )

    case .matched(let rootAction, .mismatchedParent), .mismatched(let rootAction):
      parent.issueReporter(
        decorateFailure(
          """
          Received unexpected parent action for scoped test store.

          Expected child action:
          \(expectedAction)

          Received parent action:
          \(rootAction.action)
          """
        ),
        location
      )

    case .matched(_, .mismatchedChild(let childAction)):
      parent.issueReporter(
        decorateFailure(
          """
          Received unexpected child action.

          Expected:
          \(expectedAction)

          Received:
          \(childAction)
          """
        ),
        location
      )

    case .timedOut(let resolvedTimeout):
      parent.issueReporter(
        decorateFailure(
          """
          Expected to receive child action:
          \(expectedAction)

          But timed out after \(resolvedTimeout).
          """
        ),
        location
      )

    case .cancelled:
      return
    }
  }

  private func receiveResult<Value>(
    timeout: Duration?,
    location: TestStoreSourceLocation,
    matching matcher: (ChildAction) -> TestStoreActionMatch<Value>
  ) async -> TestStoreReceiveResult<
    ActionQueue<Root.Action>.QueuedAction,
    ScopedTestStoreActionMatch<ChildAction, Value>
  > {
    _ = stateReader(parent.state)
    var lastMismatch: ScopedTestStoreActionMatch<ChildAction, Value>?
    let result: TestStoreReceiveResult<ActionQueue<Root.Action>.QueuedAction, Value> =
      await parent.receiveMatchingResult(
        timeout: timeout,
        location: location
      ) { rootAction in
        guard let childAction = actionExtractor(rootAction) else {
          lastMismatch = .mismatchedParent
          return .mismatched
        }

        switch matcher(childAction) {
        case .matched(let value):
          lastMismatch = nil
          return .matched(value)
        case .mismatched:
          lastMismatch = .mismatchedChild(childAction)
          return .mismatched
        }
      }

    switch result {
    case .matched(let rootAction, let value):
      return .matched(action: rootAction, value: .matched(value))
    case .mismatched(let rootAction):
      return .matched(
        action: rootAction,
        value: lastMismatch ?? .mismatchedParent
      )
    case .timedOut(let timeout):
      return .timedOut(timeout: timeout)
    case .cancelled:
      return .cancelled
    }
  }

  private func applyReceivedRootAction(
    _ queuedAction: ActionQueue<Root.Action>.QueuedAction,
    assert updateExpectedState: ((inout ChildState) -> Void)?,
    location: TestStoreSourceLocation
  ) async {
    defer { queuedAction.finish() }
    guard parent.shouldProceed(context: queuedAction.context) else { return }
    let rootAction = queuedAction.action
    let previousRootState = parent.state
    _ = stateReader(previousRootState)

    let effect = parent.applyScopedAction(
      rootAction,
      source: .scopedReceive,
      location: location
    )
    parent.assertStateTransition(
      from: previousRootState,
      expectedStateMutation: rootStateUpdater(from: updateExpectedState),
      mismatchLabel: "Scoped root state",
      eventDescription: "mismatch after receiving action.",
      failureContext: failureContext,
      exhaustiveGuidance: scopedExhaustivityGuidance,
      location: location
    )

    await parent.walkScopedEffect(effect, context: queuedAction.context, location: location)
  }

  private func reportScopedParentMismatch(
    rootAction: Root.Action,
    expectation: String,
    location: TestStoreSourceLocation
  ) {
    parent.issueReporter(
      decorateFailure(
        """
        Received unexpected parent action for scoped test store.

        Expected a child action matching \(expectation).

        Received parent action:
        \(rootAction)
        """
      ),
      location
    )
  }

  private func reportScopedChildMismatch(
    childAction: ChildAction,
    expectation: String,
    location: TestStoreSourceLocation
  ) {
    parent.issueReporter(
      decorateFailure(
        """
        Received child action did not match \(expectation).

        Received:
        \(childAction)
        """
      ),
      location
    )
  }

  public func assert(
    _ updateExpectedState: (inout ChildState) -> Void,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) {
    assert(
      updateExpectedState,
      location: .init(fileID: fileID, filePath: filePath, line: line, column: column))
  }

  /// Compatibility overload for an explicitly supplied legacy source file.
  public func assert(
    _ updateExpectedState: (inout ChildState) -> Void,
    file: StaticString,
    line: UInt = #line
  ) {
    assert(
      updateExpectedState, location: .init(fileID: file, filePath: file, line: line, column: 1))
  }

  package func assert(
    _ updateExpectedState: (inout ChildState) -> Void,
    location: TestStoreSourceLocation
  ) {
    var expectedState = state
    updateExpectedState(&expectedState)
    let actualState = stateReader(parent.state)

    if actualState != expectedState {
      reportStateMismatch(
        expected: expectedState,
        actual: actualState,
        eventDescription: "mismatch.",
        location: location
      )
    }
  }

  /// Waits for all parent-owned effects to finish and asserts that every
  /// emitted action has been received through this shared test harness.
  public func finish(
    timeout: Duration? = nil,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) async {
    await finish(
      timeout: timeout,
      location: .init(fileID: fileID, filePath: filePath, line: line, column: column))
  }

  /// Compatibility overload for an explicitly supplied legacy source file.
  public func finish(
    timeout: Duration? = nil,
    file: StaticString,
    line: UInt = #line
  ) async {
    await finish(
      timeout: timeout, location: .init(fileID: file, filePath: file, line: line, column: 1))
  }

  package func finish(
    timeout: Duration? = nil,
    location: TestStoreSourceLocation
  ) async {
    await parent.finish(timeout: timeout, location: location)
  }

  public func assertNoBufferedActions(
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) async {
    await assertNoBufferedActions(
      location: .init(fileID: fileID, filePath: filePath, line: line, column: column))
  }

  /// Compatibility overload for an explicitly supplied legacy source file.
  public func assertNoBufferedActions(
    file: StaticString,
    line: UInt = #line
  ) async {
    await assertNoBufferedActions(
      location: .init(fileID: file, filePath: file, line: line, column: 1))
  }

  package func assertNoBufferedActions(
    location: TestStoreSourceLocation
  ) async {
    await parent.assertNoBufferedActions(location: location)
  }

  package var resolvedDiffLineLimit: Int {
    diffLineLimit
  }

  private var scopedExhaustivityGuidance: String {
    "Scoped exhaustive assertions compare the full root state. Use the parent TestStore when the action intentionally changes parent or sibling state."
  }

  private func rootStateUpdater(
    from updateExpectedState: ((inout ChildState) -> Void)?
  ) -> ((inout Root.State) -> Bool)? {
    updateExpectedState.map { update in
      { rootState in
        expectedStateUpdater(&rootState, update)
      }
    }
  }

  private func decorateFailure(_ message: String) -> String {
    guard let failureContext else { return message }
    return "\(failureContext)\n\n\(message)"
  }

  private func reportStateMismatch(
    expected: ChildState,
    actual: ChildState,
    eventDescription: String,
    location: TestStoreSourceLocation
  ) {
    let diffSection =
      renderStateDiff(
        expected: expected,
        actual: actual,
        lineLimit: diffLineLimit
      ).map {
        "Diff:\n\($0)\n\n"
      } ?? ""

    parent.issueReporter(
      decorateFailure(
        """
        \(stateMismatchLabel) \(eventDescription)

        \(diffSection)Expected:
        \(expected)

        Actual:
        \(actual)
        """
      ),
      location
    )
  }
}
