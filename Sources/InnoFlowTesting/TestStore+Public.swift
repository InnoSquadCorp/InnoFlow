// MARK: - TestStore+Public.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import InnoFlow
import SwiftUI

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

  public func cancelEffects(identifiedBy id: EffectID) async {
    markCancelled(id: id)
    cancelEffectsSynchronously(identifiedBy: id)
  }

  public func cancelAllEffects() async {
    markCancelledAll()
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

  package func applyScopedAction(_ action: R.Action) -> EffectTask<R.Action> {
    reducer.reduce(into: &state, action: action)
  }

  package func walkScopedEffect(_ effect: EffectTask<R.Action>) async {
    let sequence = nextSequence()
    await walker.walk(effect, context: .init(sequence: sequence), awaited: false)
  }

  package func nextScopedActionWithinTimeout() async -> R.Action? {
    await nextActionWithinTimeout()
  }

  package var scopedEffectTimeout: Duration {
    effectTimeout
  }

  package var resolvedDiffLineLimit: Int {
    diffLineLimit
  }
}
