// MARK: - TestStore+Public.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
@_exported public import InnoFlowCore

extension TestStore {
  // MARK: - Public APIs

  /// Sends a user action and verifies its state transition.
  ///
  /// Buffered effect actions are reduced first. Exhaustive stores report
  /// those actions as unreceived; non-exhaustive stores continue silently or
  /// emit warnings according to ``exhaustivity``. Recovery is bounded by the
  /// store's effect timeout so a recursively emitted action cannot block the
  /// send forever.
  @discardableResult
  public func send(
    _ action: R.Action,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
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
    _ action: R.Action,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    file: StaticString,
    line: UInt = #line
  ) async -> TestStoreDispatch {
    await send(
      action, assert: updateExpectedState,
      location: .init(fileID: file, filePath: file, line: line, column: 1))
  }

  @discardableResult
  package func send(
    _ action: R.Action,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    location: TestStoreSourceLocation
  ) async -> TestStoreDispatch {
    await prepareForSend(location: location)
    let dispatch = makeDispatch()
    defer { dispatch.tracker.endActivity(dispatch.activity) }
    let previousState = state

    let effect = reduceAction(
      action,
      source: .send,
      location: location
    )
    assertStateTransition(
      from: previousState,
      expectedStateMutation: updateExpectedState.map { update in
        { state in
          update(&state)
          return true
        }
      },
      eventDescription: "mismatch after action.",
      location: location
    )

    await walker.walk(
      effect,
      context: nextEffectContext(
        for: effect, location: location, flowTaskTracker: dispatch.tracker),
      awaited: false
    )
    return dispatch.task
  }

  public func receive(
    _ expectedAction: R.Action,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) async where R.Action: Equatable {
    await receive(
      expectedAction, assert: updateExpectedState,
      location: .init(fileID: fileID, filePath: filePath, line: line, column: column))
  }

  /// Compatibility overload for an explicitly supplied legacy source file.
  public func receive(
    _ expectedAction: R.Action,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    file: StaticString,
    line: UInt = #line
  ) async where R.Action: Equatable {
    await receive(
      expectedAction, assert: updateExpectedState,
      location: .init(fileID: file, filePath: file, line: line, column: 1))
  }

  package func receive(
    _ expectedAction: R.Action,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    location: TestStoreSourceLocation
  ) async where R.Action: Equatable {
    await receiveExact(
      expectedAction,
      timeout: nil,
      assert: updateExpectedState,
      location: location
    )
  }

  /// Receives an exact action using a timeout for this assertion only.
  ///
  /// The timeout is one total wall-clock budget, including time spent
  /// discarding actions invalidated by effect cancellation or reducing
  /// mismatches in non-exhaustive mode.
  public func receive(
    _ expectedAction: R.Action,
    timeout: Duration,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) async where R.Action: Equatable {
    await receive(
      expectedAction, timeout: timeout, assert: updateExpectedState,
      location: .init(fileID: fileID, filePath: filePath, line: line, column: column))
  }

  /// Compatibility overload for an explicitly supplied legacy source file.
  public func receive(
    _ expectedAction: R.Action,
    timeout: Duration,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    file: StaticString,
    line: UInt = #line
  ) async where R.Action: Equatable {
    await receive(
      expectedAction, timeout: timeout, assert: updateExpectedState,
      location: .init(fileID: file, filePath: file, line: line, column: 1))
  }

  package func receive(
    _ expectedAction: R.Action,
    timeout: Duration,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    location: TestStoreSourceLocation
  ) async where R.Action: Equatable {
    await receiveExact(
      expectedAction,
      timeout: timeout,
      assert: updateExpectedState,
      location: location
    )
  }

  /// Receives the next action, requires it to match a case path, and returns
  /// its payload.
  ///
  /// In exhaustive mode, a valid action that does not match is reduced and
  /// reported immediately. In non-exhaustive mode, mismatches are reduced and
  /// receiving continues under one total timeout. When `Value` is optional,
  /// the nested optional return distinguishes a matched `nil` payload from a
  /// mismatch, timeout, or cancellation.
  @discardableResult
  public func receive<Value>(
    _ path: CasePath<R.Action, Value>,
    caseName: String? = nil,
    timeout: Duration? = nil,
    assert updateExpectedState: ((inout R.State, Value) -> Void)? = nil,
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
    _ path: CasePath<R.Action, Value>,
    caseName: String? = nil,
    timeout: Duration? = nil,
    assert updateExpectedState: ((inout R.State, Value) -> Void)? = nil,
    file: StaticString,
    line: UInt = #line
  ) async -> Value? {
    await receive(
      path, caseName: caseName, timeout: timeout, assert: updateExpectedState,
      location: .init(fileID: file, filePath: file, line: line, column: 1))
  }

  @discardableResult
  package func receive<Value>(
    _ path: CasePath<R.Action, Value>,
    caseName: String? = nil,
    timeout: Duration? = nil,
    assert updateExpectedState: ((inout R.State, Value) -> Void)? = nil,
    location: TestStoreSourceLocation
  ) async -> Value? {
    let result = await receiveMatchingResult(timeout: timeout, location: location) { action in
      switch path.extract(action) {
      case .some(let value):
        return .matched(value)
      case .none:
        return .mismatched
      }
    }

    let expectation = caseName.map { "case path '\($0)'" } ?? "the supplied case path"

    switch result {
    case .matched(let action, let value):
      let stateAssertion: ((inout R.State) -> Void)? = updateExpectedState.map { update in
        { state in update(&state, value) }
      }
      await applyReceivedAction(
        action,
        assert: stateAssertion,
        location: location
      )
      return .some(value)

    case .mismatched(let action):
      issueReporter(
        """
        Received action did not match \(expectation).

        Received:
        \(action.action)
        """,
        location
      )
      return nil

    case .timedOut(let resolvedTimeout):
      issueReporter(
        """
        Expected to receive an action matching \(expectation).

        But timed out after \(resolvedTimeout).
        """,
        location
      )
      return nil

    case .cancelled:
      return nil
    }
  }

  /// Receives and returns the next action accepted by a predicate.
  ///
  /// In exhaustive mode, a valid action rejected by the predicate is reduced
  /// and reported immediately. In non-exhaustive mode, rejected actions are
  /// reduced and receiving continues under one total timeout. The predicate
  /// and assertion execute on the main actor.
  @discardableResult
  public func receive(
    where predicate: (R.Action) -> Bool,
    description: String? = nil,
    timeout: Duration? = nil,
    assert updateExpectedState: ((inout R.State, R.Action) -> Void)? = nil,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) async -> R.Action? {
    await receive(
      where: predicate, description: description, timeout: timeout, assert: updateExpectedState,
      location: .init(fileID: fileID, filePath: filePath, line: line, column: column))
  }

  /// Compatibility overload for an explicitly supplied legacy source file.
  @discardableResult
  public func receive(
    where predicate: (R.Action) -> Bool,
    description: String? = nil,
    timeout: Duration? = nil,
    assert updateExpectedState: ((inout R.State, R.Action) -> Void)? = nil,
    file: StaticString,
    line: UInt = #line
  ) async -> R.Action? {
    await receive(
      where: predicate, description: description, timeout: timeout, assert: updateExpectedState,
      location: .init(fileID: file, filePath: file, line: line, column: 1))
  }

  @discardableResult
  package func receive(
    where predicate: (R.Action) -> Bool,
    description: String? = nil,
    timeout: Duration? = nil,
    assert updateExpectedState: ((inout R.State, R.Action) -> Void)? = nil,
    location: TestStoreSourceLocation
  ) async -> R.Action? {
    let result = await receiveMatchingResult(timeout: timeout, location: location) { action in
      predicate(action) ? .matched(action) : .mismatched
    }
    let expectation = description.map { "predicate '\($0)'" } ?? "the supplied predicate"

    switch result {
    case .matched(let action, _):
      let stateAssertion: ((inout R.State) -> Void)? = updateExpectedState.map { update in
        { state in update(&state, action.action) }
      }
      await applyReceivedAction(
        action,
        assert: stateAssertion,
        location: location
      )
      return .some(action.action)

    case .mismatched(let action):
      issueReporter(
        """
        Received action did not satisfy \(expectation).

        Received:
        \(action.action)
        """,
        location
      )
      return nil

    case .timedOut(let resolvedTimeout):
      issueReporter(
        """
        Expected to receive an action satisfying \(expectation).

        But timed out after \(resolvedTimeout).
        """,
        location
      )
      return nil

    case .cancelled:
      return nil
    }
  }

  private func receiveExact(
    _ expectedAction: R.Action,
    timeout: Duration?,
    assert updateExpectedState: ((inout R.State) -> Void)?,
    location: TestStoreSourceLocation
  ) async where R.Action: Equatable {
    let result = await receiveMatchingResult(timeout: timeout, location: location) { action in
      action == expectedAction ? .matched(()) : .mismatched
    }

    switch result {
    case .matched(let action, _):
      await applyReceivedAction(
        action,
        assert: updateExpectedState,
        location: location
      )

    case .mismatched(let action):
      issueReporter(
        """
        Received unexpected action.

        Expected:
        \(expectedAction)

        Received:
        \(action.action)
        """,
        location
      )

    case .timedOut(let resolvedTimeout):
      issueReporter(
        """
        Expected to receive action:
        \(expectedAction)

        But timed out after \(resolvedTimeout).
        """,
        location
      )

    case .cancelled:
      return
    }
  }

  private func applyReceivedAction(
    _ queuedAction: ActionQueue<R.Action>.QueuedAction,
    assert updateExpectedState: ((inout R.State) -> Void)?,
    location: TestStoreSourceLocation
  ) async {
    defer { queuedAction.finish() }
    guard shouldProceed(context: queuedAction.context) else { return }
    let action = queuedAction.action
    let previousState = state

    let effect = reduceAction(
      action,
      source: .receive,
      location: location
    )
    assertStateTransition(
      from: previousState,
      expectedStateMutation: updateExpectedState.map { update in
        { state in
          update(&state)
          return true
        }
      },
      eventDescription: "mismatch after receiving action.",
      location: location
    )

    await walker.walk(
      effect,
      context: nextEffectContext(
        for: effect, location: location, flowTaskTracker: queuedAction.context?.flowTaskTracker),
      awaited: false
    )
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
    if let buffered = await popBufferedAction() {
      issueReporter(
        """
        Unhandled buffered action:
        \(buffered)

        All already-buffered effect actions should be verified with `receive(_:assert:)`.
        """,
        location
      )
    }
  }

  public func cancelEffects<ID: Hashable & Sendable>(identifiedBy id: EffectID<ID>) async {
    let erasedID = AnyEffectID(id)
    let sequence = markCancelled(id: erasedID)
    cancelEffectsSynchronously(identifiedBy: erasedID, upTo: sequence)
  }

  public func cancelAllEffects() async {
    let sequence = markCancelledAll()
    cancelAllEffectsSynchronously(upTo: sequence)
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
        return true
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
          return false
        }
        update(&collectionState[index])
        rootState[keyPath: collection] = collectionState
        return true
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

  /// Projects the parent harness onto a single identifiable child element of a
  /// collection slice (`\.todos[id: targetID]`-style targeting).
  ///
  /// ## Identity caching
  ///
  /// The returned `ScopedTestStore` caches its child snapshot keyed by `id`.
  /// Sibling updates within the same collection do not invalidate this row's
  /// observers — only state changes that touch the *element matching `id`*
  /// trigger refresh. This mirrors the runtime `ScopedStore` collection
  /// scoping contract so test harnesses observe the same per-element
  /// invalidation surface as the production runtime.
  ///
  /// ## Stale-row policy
  ///
  /// Once the parent reducer removes the element with the supplied `id`, any
  /// further interaction with the previously returned `ScopedTestStore` is
  /// treated as programmer error and traps via `preconditionFailure`. The
  /// recommended pattern is:
  ///
  /// 1. assert removal at the parent `TestStore` level (`store.send(...)`)
  /// 2. discard the old row-scoped handle
  /// 3. recreate any later projection from the parent `TestStore`
  ///
  /// Direct access to a removed row's `ScopedTestStore` is intentionally
  /// loud, not silently no-op, because tests that hold stale row handles
  /// almost always reflect a real bug in the feature under test.
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

  package func applyScopedAction(
    _ action: R.Action,
    source: TestStoreReductionSource,
    location: TestStoreSourceLocation
  ) -> ReducerEffect<R.Action, R.Output> {
    reduceAction(action, source: source, location: location)
  }

  package func walkScopedEffect(
    _ effect: ReducerEffect<R.Action, R.Output>,
    context: EffectExecutionContext? = nil,
    flowTaskTracker: FlowTaskTracker? = nil,
    location: TestStoreSourceLocation
  ) async {
    await walker.walk(
      effect,
      context: nextEffectContext(
        for: effect, location: location,
        flowTaskTracker: flowTaskTracker ?? context?.flowTaskTracker),
      awaited: false
    )
  }

  package func walkScopedEffect(_ effect: ReducerEffect<R.Action, R.Output>) async {
    let source = terminalVerificationSource ?? .init()
    await walkScopedEffect(effect, location: source)
  }

  package var resolvedDiffLineLimit: Int {
    diffLineLimit
  }
}
