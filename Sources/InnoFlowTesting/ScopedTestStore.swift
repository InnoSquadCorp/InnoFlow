// MARK: - ScopedTestStore.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
@_exported public import InnoFlowCore

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

  public subscript<Value>(dynamicMember keyPath: KeyPath<ChildState, BindableProperty<Value>>)
    -> Value
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

  public func assertNoBufferedActions(
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    await parent.assertNoBufferedActions(file: file, line: line)
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
    let diffSection =
      renderStateDiff(
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
