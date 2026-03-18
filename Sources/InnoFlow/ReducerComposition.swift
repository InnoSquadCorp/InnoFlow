// MARK: - ReducerComposition.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

/// A closure-backed reducer primitive.
public struct Reduce<State: Sendable, Action: Sendable>: Reducer {
  private let reducer: (inout State, Action) -> EffectTask<Action>

  public init(
    _ reducer: @escaping (inout State, Action) -> EffectTask<Action>
  ) {
    self.reducer = reducer
  }

  public func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    reducer(&state, action)
  }
}

/// A result builder for reducer composition.
@resultBuilder
public enum ReducerBuilder<State: Sendable, Action: Sendable> {
  public static func buildBlock() -> Reduce<State, Action> {
    .init { _, _ in .none }
  }

  public static func buildExpression<R: Reducer>(
    _ reducer: R
  ) -> Reduce<State, Action> where R.State == State, R.Action == Action {
    .init { state, action in
      reducer.reduce(into: &state, action: action)
    }
  }

  public static func buildPartialBlock(
    first component: Reduce<State, Action>
  ) -> Reduce<State, Action> {
    component
  }

  public static func buildPartialBlock(
    accumulated: Reduce<State, Action>,
    next component: Reduce<State, Action>
  ) -> Reduce<State, Action> {
    .init { state, action in
      let firstEffect = accumulated.reduce(into: &state, action: action)
      let secondEffect = component.reduce(into: &state, action: action)
      return .merge(firstEffect, secondEffect)
    }
  }

  public static func buildOptional(
    _ component: Reduce<State, Action>?
  ) -> Reduce<State, Action> {
    .init { state, action in
      component?.reduce(into: &state, action: action) ?? .none
    }
  }

  public static func buildEither(
    first component: Reduce<State, Action>
  ) -> Reduce<State, Action> {
    component
  }

  public static func buildEither(
    second component: Reduce<State, Action>
  ) -> Reduce<State, Action> {
    component
  }

  public static func buildArray(
    _ components: [Reduce<State, Action>]
  ) -> Reduce<State, Action> {
    .init { state, action in
      let effects = components.map { reducer in
        reducer.reduce(into: &state, action: action)
      }
      return .merge(effects)
    }
  }

  public static func buildLimitedAvailability(
    _ component: Reduce<State, Action>
  ) -> Reduce<State, Action> {
    component
  }
}

/// Runs multiple reducers in declaration order and merges their effects.
public struct CombineReducers<State: Sendable, Action: Sendable>: Reducer {
  private let reduceContent: (inout State, Action) -> EffectTask<Action>

  public init<Content: Reducer>(
    @ReducerBuilder<State, Action> _ content: () -> Content
  )
  where Content.State == State, Content.Action == Action {
    let builtContent = content()
    self.reduceContent = { state, action in
      builtContent.reduce(into: &state, action: action)
    }
  }

  public func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    reduceContent(&state, action)
  }
}

/// Lifts a child reducer into a parent's state and action space.
public struct Scope<ParentState: Sendable, ParentAction: Sendable, Child: Reducer>: Reducer {
  public typealias State = ParentState
  public typealias Action = ParentAction

  private let state: WritableKeyPath<ParentState, Child.State>
  private let extractAction: @Sendable (ParentAction) -> Child.Action?
  private let embedAction: @Sendable (Child.Action) -> ParentAction
  private let reducer: Child

  private init(
    state: WritableKeyPath<ParentState, Child.State>,
    extractAction: @escaping @Sendable (ParentAction) -> Child.Action?,
    embedAction: @escaping @Sendable (Child.Action) -> ParentAction,
    reducer: Child
  ) {
    self.state = state
    self.extractAction = extractAction
    self.embedAction = embedAction
    self.reducer = reducer
  }

  public init(
    state: WritableKeyPath<ParentState, Child.State>,
    action: CasePath<ParentAction, Child.Action>,
    reducer: Child
  ) {
    self.init(
      state: state,
      extractAction: action.extract,
      embedAction: action.embed,
      reducer: reducer
    )
  }

  public func reduce(into state: inout ParentState, action: ParentAction) -> EffectTask<ParentAction> {
    guard let childAction = extractAction(action) else {
      return .none
    }

    let childEffect = reducer.reduce(into: &state[keyPath: self.state], action: childAction)
    return childEffect.map(embedAction)
  }
}

/// Runs a child reducer only while optional child state is present.
public struct IfLet<ParentState: Sendable, ParentAction: Sendable, Child: Reducer>: Reducer {
  public typealias State = ParentState
  public typealias Action = ParentAction

  private let state: WritableKeyPath<ParentState, Child.State?>
  private let extractAction: @Sendable (ParentAction) -> Child.Action?
  private let embedAction: @Sendable (Child.Action) -> ParentAction
  private let reducer: Child

  private init(
    state: WritableKeyPath<ParentState, Child.State?>,
    extractAction: @escaping @Sendable (ParentAction) -> Child.Action?,
    embedAction: @escaping @Sendable (Child.Action) -> ParentAction,
    reducer: Child
  ) {
    self.state = state
    self.extractAction = extractAction
    self.embedAction = embedAction
    self.reducer = reducer
  }

  public init(
    state: WritableKeyPath<ParentState, Child.State?>,
    action: CasePath<ParentAction, Child.Action>,
    reducer: Child
  ) {
    self.init(
      state: state,
      extractAction: action.extract,
      embedAction: action.embed,
      reducer: reducer
    )
  }

  public func reduce(into state: inout ParentState, action: ParentAction) -> EffectTask<ParentAction> {
    guard let childAction = extractAction(action) else {
      return .none
    }
    guard var childState = state[keyPath: self.state] else {
      assertionFailure("IfLet received a child action while child state was nil.")
      return .none
    }

    let childEffect = reducer.reduce(into: &childState, action: childAction)
    state[keyPath: self.state] = childState
    return childEffect.map(embedAction)
  }
}

/// Runs a child reducer only while enum parent state matches the supplied case.
public struct IfCaseLet<ParentState: Sendable, ParentAction: Sendable, Child: Reducer>: Reducer {
  public typealias State = ParentState
  public typealias Action = ParentAction

  private let state: CasePath<ParentState, Child.State>
  private let extractAction: @Sendable (ParentAction) -> Child.Action?
  private let embedAction: @Sendable (Child.Action) -> ParentAction
  private let reducer: Child

  private init(
    state: CasePath<ParentState, Child.State>,
    extractAction: @escaping @Sendable (ParentAction) -> Child.Action?,
    embedAction: @escaping @Sendable (Child.Action) -> ParentAction,
    reducer: Child
  ) {
    self.state = state
    self.extractAction = extractAction
    self.embedAction = embedAction
    self.reducer = reducer
  }

  public init(
    state: CasePath<ParentState, Child.State>,
    action: CasePath<ParentAction, Child.Action>,
    reducer: Child
  ) {
    self.init(
      state: state,
      extractAction: action.extract,
      embedAction: action.embed,
      reducer: reducer
    )
  }

  public func reduce(into state: inout ParentState, action: ParentAction) -> EffectTask<ParentAction> {
    guard let childAction = extractAction(action) else {
      return .none
    }
    guard var childState = self.state.extract(state) else {
      assertionFailure("IfCaseLet received a child action while parent state was in a different case.")
      return .none
    }

    let childEffect = reducer.reduce(into: &childState, action: childAction)
    state = self.state.embed(childState)
    return childEffect.map(embedAction)
  }
}

/// Lifts a child reducer across an identifiable collection in parent state.
public struct ForEachReducer<
  ParentState: Sendable,
  ParentAction: Sendable,
  CollectionState,
  Child: Reducer
>: Reducer
where
  CollectionState: MutableCollection & RandomAccessCollection,
  CollectionState.Element: Equatable & Identifiable,
  CollectionState.Element.ID: Sendable,
  Child.State == CollectionState.Element
{
  public typealias State = ParentState
  public typealias Action = ParentAction

  private let state: WritableKeyPath<ParentState, CollectionState>
  private let action: CollectionActionPath<ParentAction, CollectionState.Element.ID, Child.Action>
  private let reducer: Child

  public init(
    state: WritableKeyPath<ParentState, CollectionState>,
    action: CollectionActionPath<ParentAction, CollectionState.Element.ID, Child.Action>,
    reducer: Child
  ) {
    self.state = state
    self.action = action
    self.reducer = reducer
  }

  public func reduce(into state: inout ParentState, action parentAction: ParentAction) -> EffectTask<ParentAction> {
    guard let (id, childAction) = action.extract(parentAction) else {
      return .none
    }

    var collection = state[keyPath: self.state]
    guard let index = collection.firstIndex(where: { $0.id == id }) else {
      return .none
    }

    var childState = collection[index]
    let childEffect = reducer.reduce(into: &childState, action: childAction)
    collection[index] = childState
    state[keyPath: self.state] = collection
    let actionPath = self.action
    let elementID = id
    return childEffect.map { followUpAction in
      actionPath.embed(elementID, followUpAction)
    }
  }
}
