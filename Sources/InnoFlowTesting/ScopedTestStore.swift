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
  public func send(
    _ action: ChildAction,
    assert updateExpectedState: ((inout ChildState) -> Void)? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    await parent.prepareForSend(file: file, line: line)
    let previousRootState = parent.state
    // Preserve the stale-handle contract before routing any action. A valid
    // collection child may remove itself during reduction; that distinct
    // post-reduction case is handled by the failable expected-state updater.
    _ = stateReader(previousRootState)

    let effect = parent.applyScopedAction(actionEmbedder(action))
    parent.assertStateTransition(
      from: previousRootState,
      expectedStateMutation: rootStateUpdater(from: updateExpectedState),
      mismatchLabel: "Scoped root state",
      eventDescription: "mismatch after action.",
      failureContext: failureContext,
      exhaustiveGuidance: scopedExhaustivityGuidance,
      file: file,
      line: line
    )

    await parent.walkScopedEffect(effect)
  }

  public func receive(
    _ expectedAction: ChildAction,
    assert updateExpectedState: ((inout ChildState) -> Void)? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async where ChildAction: Equatable {
    await receiveExact(
      expectedAction,
      timeout: nil,
      assert: updateExpectedState,
      file: file,
      line: line
    )
  }

  /// Receives an exact child action using one total timeout for this assertion.
  /// In non-exhaustive mode, parent and non-matching child actions are reduced
  /// while receiving continues.
  public func receive(
    _ expectedAction: ChildAction,
    timeout: Duration,
    assert updateExpectedState: ((inout ChildState) -> Void)? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async where ChildAction: Equatable {
    await receiveExact(
      expectedAction,
      timeout: timeout,
      assert: updateExpectedState,
      file: file,
      line: line
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
    file: StaticString = #filePath,
    line: UInt = #line
  ) async -> Value? {
    let result = await receiveResult(timeout: timeout, file: file, line: line) { action in
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
        file: file,
        line: line
      )
      return .some(value)

    case .matched(let rootAction, .mismatchedParent), .mismatched(let rootAction):
      reportScopedParentMismatch(
        rootAction: rootAction,
        expectation: expectation,
        file: file,
        line: line
      )
      return nil

    case .matched(_, .mismatchedChild(let childAction)):
      reportScopedChildMismatch(
        childAction: childAction,
        expectation: expectation,
        file: file,
        line: line
      )
      return nil

    case .timedOut(let resolvedTimeout):
      parent.assertionFailureReporter(
        decorateFailure(
          """
          Expected to receive a child action matching \(expectation).

          But timed out after \(resolvedTimeout).
          """
        ),
        file,
        line
      )
      return nil

    case .cancelled:
      return nil
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
    file: StaticString = #filePath,
    line: UInt = #line
  ) async -> ChildAction? {
    let result = await receiveResult(timeout: timeout, file: file, line: line) { action in
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
        file: file,
        line: line
      )
      return .some(childAction)

    case .matched(let rootAction, .mismatchedParent), .mismatched(let rootAction):
      reportScopedParentMismatch(
        rootAction: rootAction,
        expectation: expectation,
        file: file,
        line: line
      )
      return nil

    case .matched(_, .mismatchedChild(let childAction)):
      reportScopedChildMismatch(
        childAction: childAction,
        expectation: expectation,
        file: file,
        line: line
      )
      return nil

    case .timedOut(let resolvedTimeout):
      parent.assertionFailureReporter(
        decorateFailure(
          """
          Expected to receive a child action satisfying \(expectation).

          But timed out after \(resolvedTimeout).
          """
        ),
        file,
        line
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
    file: StaticString,
    line: UInt
  ) async where ChildAction: Equatable {
    let result = await receiveResult(timeout: timeout, file: file, line: line) { childAction in
      childAction == expectedAction ? .matched(()) : .mismatched
    }

    switch result {
    case .matched(let rootAction, .matched):
      await applyReceivedRootAction(
        rootAction,
        assert: updateExpectedState,
        file: file,
        line: line
      )

    case .matched(let rootAction, .mismatchedParent), .mismatched(let rootAction):
      parent.assertionFailureReporter(
        decorateFailure(
          """
          Received unexpected parent action for scoped test store.

          Expected child action:
          \(expectedAction)

          Received parent action:
          \(rootAction)
          """
        ),
        file,
        line
      )

    case .matched(_, .mismatchedChild(let childAction)):
      parent.assertionFailureReporter(
        decorateFailure(
          """
          Received unexpected child action.

          Expected:
          \(expectedAction)

          Received:
          \(childAction)
          """
        ),
        file,
        line
      )

    case .timedOut(let resolvedTimeout):
      parent.assertionFailureReporter(
        decorateFailure(
          """
          Expected to receive child action:
          \(expectedAction)

          But timed out after \(resolvedTimeout).
          """
        ),
        file,
        line
      )

    case .cancelled:
      return
    }
  }

  private func receiveResult<Value>(
    timeout: Duration?,
    file: StaticString,
    line: UInt,
    matching matcher: (ChildAction) -> TestStoreActionMatch<Value>
  ) async -> TestStoreReceiveResult<
    Root.Action,
    ScopedTestStoreActionMatch<ChildAction, Value>
  > {
    _ = stateReader(parent.state)
    var lastMismatch: ScopedTestStoreActionMatch<ChildAction, Value>?
    let result: TestStoreReceiveResult<Root.Action, Value> =
      await parent.receiveMatchingResult(
        timeout: timeout,
        file: file,
        line: line
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
    _ rootAction: Root.Action,
    assert updateExpectedState: ((inout ChildState) -> Void)?,
    file: StaticString,
    line: UInt
  ) async {
    let previousRootState = parent.state
    _ = stateReader(previousRootState)

    let effect = parent.applyScopedAction(rootAction)
    parent.assertStateTransition(
      from: previousRootState,
      expectedStateMutation: rootStateUpdater(from: updateExpectedState),
      mismatchLabel: "Scoped root state",
      eventDescription: "mismatch after receiving action.",
      failureContext: failureContext,
      exhaustiveGuidance: scopedExhaustivityGuidance,
      file: file,
      line: line
    )

    await parent.walkScopedEffect(effect)
  }

  private func reportScopedParentMismatch(
    rootAction: Root.Action,
    expectation: String,
    file: StaticString,
    line: UInt
  ) {
    parent.assertionFailureReporter(
      decorateFailure(
        """
        Received unexpected parent action for scoped test store.

        Expected a child action matching \(expectation).

        Received parent action:
        \(rootAction)
        """
      ),
      file,
      line
    )
  }

  private func reportScopedChildMismatch(
    childAction: ChildAction,
    expectation: String,
    file: StaticString,
    line: UInt
  ) {
    parent.assertionFailureReporter(
      decorateFailure(
        """
        Received child action did not match \(expectation).

        Received:
        \(childAction)
        """
      ),
      file,
      line
    )
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

  /// Performs the parent harness's legacy single-action absence check.
  ///
  /// This does not wait for the complete effect lifecycle. Use `finish()` at
  /// the terminal test boundary or `assertNoBufferedActions()` for an
  /// intermediate queue checkpoint.
  @available(
    *,
    deprecated,
    message:
      "Use finish() for terminal verification, or assertNoBufferedActions() for an intermediate queue checkpoint."
  )
  public func assertNoMoreActions(
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    await parent.assertNoMoreActions(file: file, line: line)
  }

  /// Waits for all parent-owned effects to finish and asserts that every
  /// emitted action has been received through this shared test harness.
  public func finish(
    timeout: Duration? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    await parent.finish(timeout: timeout, file: file, line: line)
  }

  public func assertNoBufferedActions(
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    await parent.assertNoBufferedActions(file: file, line: line)
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
    file: StaticString,
    line: UInt
  ) {
    let diffSection =
      renderStateDiff(
        expected: expected,
        actual: actual,
        lineLimit: diffLineLimit
      ).map {
        "Diff:\n\($0)\n\n"
      } ?? ""

    parent.assertionFailureReporter(
      decorateFailure(
        """
        \(stateMismatchLabel) \(eventDescription)

        \(diffSection)Expected:
        \(expected)

        Actual:
        \(actual)
        """
      ),
      file,
      line
    )
  }
}
