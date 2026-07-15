// MARK: - TestStore+Public.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
@_exported public import InnoFlowCore

extension TestStore {
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
      let diffSection =
        renderStateDiff(
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

    let sequence = nextSequence()
    await walker.walk(effect, context: .init(sequence: sequence), awaited: false)
  }

  public func receive(
    _ expectedAction: R.Action,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    file: StaticString = #file,
    line: UInt = #line
  ) async where R.Action: Equatable {
    await receiveExact(
      expectedAction,
      timeout: nil,
      assert: updateExpectedState,
      file: file,
      line: line
    )
  }

  /// Receives an exact action using a timeout for this assertion only.
  ///
  /// The timeout is one total wall-clock budget, including time spent
  /// discarding actions invalidated by effect cancellation.
  public func receive(
    _ expectedAction: R.Action,
    timeout: Duration,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    file: StaticString = #file,
    line: UInt = #line
  ) async where R.Action: Equatable {
    await receiveExact(
      expectedAction,
      timeout: timeout,
      assert: updateExpectedState,
      file: file,
      line: line
    )
  }

  /// Receives the next action, requires it to match a case path, and returns
  /// its payload.
  ///
  /// A valid action that does not match is consumed and reported immediately.
  /// When `Value` is optional, the nested optional return distinguishes a
  /// matched `nil` payload from a mismatch, timeout, or cancellation.
  @discardableResult
  public func receive<Value>(
    _ path: CasePath<R.Action, Value>,
    caseName: String? = nil,
    timeout: Duration? = nil,
    assert updateExpectedState: ((inout R.State, Value) -> Void)? = nil,
    file: StaticString = #file,
    line: UInt = #line
  ) async -> Value? {
    let result = await receiveResult(timeout: timeout) { action in
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
        file: file,
        line: line
      )
      return .some(value)

    case .mismatched(let action):
      testStoreAssertionFailure(
        """
        Received action did not match \(expectation).

        Received:
        \(action)
        """,
        file: file,
        line: line
      )
      return nil

    case .timedOut(let resolvedTimeout):
      testStoreAssertionFailure(
        """
        Expected to receive an action matching \(expectation).

        But timed out after \(resolvedTimeout).
        """,
        file: file,
        line: line
      )
      return nil

    case .cancelled:
      return nil
    }
  }

  /// Receives and returns the next action accepted by a predicate.
  ///
  /// A valid action rejected by the predicate is consumed and reported
  /// immediately. The predicate and assertion execute on the main actor.
  @discardableResult
  public func receive(
    where predicate: (R.Action) -> Bool,
    description: String? = nil,
    timeout: Duration? = nil,
    assert updateExpectedState: ((inout R.State, R.Action) -> Void)? = nil,
    file: StaticString = #file,
    line: UInt = #line
  ) async -> R.Action? {
    let result = await receiveResult(timeout: timeout) { action in
      predicate(action) ? .matched(action) : .mismatched
    }
    let expectation = description.map { "predicate '\($0)'" } ?? "the supplied predicate"

    switch result {
    case .matched(let action, _):
      let stateAssertion: ((inout R.State) -> Void)? = updateExpectedState.map { update in
        { state in update(&state, action) }
      }
      await applyReceivedAction(
        action,
        assert: stateAssertion,
        file: file,
        line: line
      )
      return .some(action)

    case .mismatched(let action):
      testStoreAssertionFailure(
        """
        Received action did not satisfy \(expectation).

        Received:
        \(action)
        """,
        file: file,
        line: line
      )
      return nil

    case .timedOut(let resolvedTimeout):
      testStoreAssertionFailure(
        """
        Expected to receive an action satisfying \(expectation).

        But timed out after \(resolvedTimeout).
        """,
        file: file,
        line: line
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
    file: StaticString,
    line: UInt
  ) async where R.Action: Equatable {
    let result = await receiveResult(timeout: timeout) { action in
      action == expectedAction ? .matched(()) : .mismatched
    }

    switch result {
    case .matched(let action, _):
      await applyReceivedAction(
        action,
        assert: updateExpectedState,
        file: file,
        line: line
      )

    case .mismatched(let action):
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

    case .timedOut(let resolvedTimeout):
      testStoreAssertionFailure(
        """
        Expected to receive action:
        \(expectedAction)

        But timed out after \(resolvedTimeout).
        """,
        file: file,
        line: line
      )

    case .cancelled:
      return
    }
  }

  private func applyReceivedAction(
    _ action: R.Action,
    assert updateExpectedState: ((inout R.State) -> Void)?,
    file: StaticString,
    line: UInt
  ) async {
    var expectedState = state
    updateExpectedState?(&expectedState)

    let effect = reducer.reduce(into: &state, action: action)

    if updateExpectedState != nil, state != expectedState {
      let diffSection =
        renderStateDiff(
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

    let sequence = nextSequence()
    await walker.walk(effect, context: .init(sequence: sequence), awaited: false)
  }

  public func assertNoMoreActions(
    file: StaticString = #file,
    line: UInt = #line
  ) async {
    if let buffered = await popBufferedAction() {
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

    let leftover = await nextActionWithinTimeout()

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

  public func assertNoBufferedActions(
    file: StaticString = #file,
    line: UInt = #line
  ) async {
    if let buffered = await popBufferedAction() {
      testStoreAssertionFailure(
        """
        Unhandled buffered action:
        \(buffered)

        All already-buffered effect actions should be verified with `receive(_:assert:)`.
        """,
        file: file,
        line: line
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

  package func applyScopedAction(_ action: R.Action) -> EffectTask<R.Action> {
    reducer.reduce(into: &state, action: action)
  }

  package func walkScopedEffect(_ effect: EffectTask<R.Action>) async {
    let sequence = nextSequence()
    await walker.walk(effect, context: .init(sequence: sequence), awaited: false)
  }

  package var resolvedDiffLineLimit: Int {
    diffLineLimit
  }
}
