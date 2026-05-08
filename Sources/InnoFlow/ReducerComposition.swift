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
///
/// The builder preserves reducer semantics while keeping its intermediate
/// implementation wrappers out of the public API.
@resultBuilder
public enum ReducerBuilder<State: Sendable, Action: Sendable> {
  @inlinable
  public static func buildBlock() -> Reduce<State, Action> {
    Reduce { _, _ in .none }
  }

  @inlinable
  public static func buildExpression<R: Reducer>(
    _ reducer: R
  ) -> Reduce<State, Action> where R.State == State, R.Action == Action {
    Reduce { state, action in
      reducer.reduce(into: &state, action: action)
    }
  }

  @inlinable
  public static func buildPartialBlock(
    first component: Reduce<State, Action>
  ) -> Reduce<State, Action> {
    component
  }

  @inlinable
  public static func buildPartialBlock(
    accumulated: Reduce<State, Action>,
    next component: Reduce<State, Action>
  ) -> Reduce<State, Action> {
    Reduce { state, action in
      let accumulatedEffect = accumulated.reduce(into: &state, action: action)
      let componentEffect = component.reduce(into: &state, action: action)
      return .merge(accumulatedEffect, componentEffect)
    }
  }

  @inlinable
  public static func buildOptional(
    _ component: Reduce<State, Action>?
  ) -> Reduce<State, Action> {
    Reduce { state, action in
      component?.reduce(into: &state, action: action) ?? .none
    }
  }

  @inlinable
  public static func buildEither(
    first component: Reduce<State, Action>
  ) -> Reduce<State, Action> {
    Reduce { state, action in
      component.reduce(into: &state, action: action)
    }
  }

  @inlinable
  public static func buildEither(
    second component: Reduce<State, Action>
  ) -> Reduce<State, Action> {
    Reduce { state, action in
      component.reduce(into: &state, action: action)
    }
  }

  @inlinable
  public static func buildArray(
    _ components: [Reduce<State, Action>]
  ) -> Reduce<State, Action> {
    Reduce { state, action in
      guard !components.isEmpty else { return .none }
      var effects: [EffectTask<Action>] = []
      effects.reserveCapacity(components.count)
      for component in components {
        effects.append(component.reduce(into: &state, action: action))
      }
      return .merge(effects)
    }
  }

  @inlinable
  public static func buildLimitedAvailability<R: Reducer>(
    _ component: R
  ) -> Reduce<State, Action> where R.State == State, R.Action == Action {
    Reduce { state, action in
      component.reduce(into: &state, action: action)
    }
  }
}

/// Runs multiple reducers in declaration order and merges their effects.
public struct CombineReducers<State: Sendable, Action: Sendable>: Reducer {
  @usableFromInline let reduceContent: (inout State, Action) -> EffectTask<Action>

  @inlinable
  public init<Content: Reducer>(
    @ReducerBuilder<State, Action> _ content: () -> Content
  )
  where Content.State == State, Content.Action == Action {
    let builtContent = content()
    self.reduceContent = { state, action in
      builtContent.reduce(into: &state, action: action)
    }
  }

  @inlinable
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

  public func reduce(into state: inout ParentState, action: ParentAction) -> EffectTask<
    ParentAction
  > {
    guard let childAction = extractAction(action) else {
      return .none
    }

    let childEffect = reducer.reduce(into: &state[keyPath: self.state], action: childAction)
    return childEffect.map(embedAction)
  }
}

/// Policy that controls how `IfLet` / `IfCaseLet` react when a child action
/// arrives while child state is unavailable (optional is `nil`, or the parent
/// enum is in a different case).
///
/// - `assertOnly` (default): debug builds emit `assertionFailure`, release
///   builds drop the action as a silent no-op. Preserves source compatibility
///   with releases prior to the introduction of this policy.
/// - `ignore`: silent no-op in every build configuration. Use when the
///   late-arriving action is a known race (e.g. an effect that fired after a
///   dismiss completed) and a debug abort would be more disruptive than the
///   drop itself.
/// - `crash`: traps with `preconditionFailure` in every build configuration.
///   Use when receiving the action is treated as a programming bug that must
///   never reach production.
public enum OnMissingPolicy: Sendable {
  case ignore
  case assertOnly
  case crash
}

/// Runs a child reducer only while optional child state is present.
public struct IfLet<ParentState: Sendable, ParentAction: Sendable, Child: Reducer>: Reducer {
  public typealias State = ParentState
  public typealias Action = ParentAction

  private let state: WritableKeyPath<ParentState, Child.State?>
  private let extractAction: @Sendable (ParentAction) -> Child.Action?
  private let embedAction: @Sendable (Child.Action) -> ParentAction
  private let reducer: Child
  private let onMissing: OnMissingPolicy

  private init(
    state: WritableKeyPath<ParentState, Child.State?>,
    extractAction: @escaping @Sendable (ParentAction) -> Child.Action?,
    embedAction: @escaping @Sendable (Child.Action) -> ParentAction,
    reducer: Child,
    onMissing: OnMissingPolicy
  ) {
    self.state = state
    self.extractAction = extractAction
    self.embedAction = embedAction
    self.reducer = reducer
    self.onMissing = onMissing
  }

  public init(
    state: WritableKeyPath<ParentState, Child.State?>,
    action: CasePath<ParentAction, Child.Action>,
    reducer: Child,
    onMissing: OnMissingPolicy = .assertOnly
  ) {
    self.init(
      state: state,
      extractAction: action.extract,
      embedAction: action.embed,
      reducer: reducer,
      onMissing: onMissing
    )
  }

  public func reduce(into state: inout ParentState, action: ParentAction) -> EffectTask<
    ParentAction
  > {
    guard let childAction = extractAction(action) else {
      return .none
    }
    guard var childState = state[keyPath: self.state] else {
      switch onMissing {
      case .ignore:
        break
      case .assertOnly:
        assertionFailure("IfLet received a child action while child state was nil.")
      case .crash:
        preconditionFailure("IfLet received a child action while child state was nil.")
      }
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
  private let onMissing: OnMissingPolicy

  private init(
    state: CasePath<ParentState, Child.State>,
    extractAction: @escaping @Sendable (ParentAction) -> Child.Action?,
    embedAction: @escaping @Sendable (Child.Action) -> ParentAction,
    reducer: Child,
    onMissing: OnMissingPolicy
  ) {
    self.state = state
    self.extractAction = extractAction
    self.embedAction = embedAction
    self.reducer = reducer
    self.onMissing = onMissing
  }

  public init(
    state: CasePath<ParentState, Child.State>,
    action: CasePath<ParentAction, Child.Action>,
    reducer: Child,
    onMissing: OnMissingPolicy = .assertOnly
  ) {
    self.init(
      state: state,
      extractAction: action.extract,
      embedAction: action.embed,
      reducer: reducer,
      onMissing: onMissing
    )
  }

  public func reduce(into state: inout ParentState, action: ParentAction) -> EffectTask<
    ParentAction
  > {
    guard let childAction = extractAction(action) else {
      return .none
    }
    guard var childState = self.state.extract(state) else {
      switch onMissing {
      case .ignore:
        break
      case .assertOnly:
        assertionFailure(
          "IfCaseLet received a child action while parent state was in a different case.")
      case .crash:
        preconditionFailure(
          "IfCaseLet received a child action while parent state was in a different case.")
      }
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

  public func reduce(into state: inout ParentState, action parentAction: ParentAction)
    -> EffectTask<ParentAction>
  {
    guard let (id, childAction) = action.extract(parentAction) else {
      return .none
    }

    guard let index = state[keyPath: self.state].firstIndex(where: { $0.id == id }) else {
      return .none
    }

    let childEffect = reducer.reduce(
      into: &state[keyPath: self.state][index],
      action: childAction
    )
    let actionPath = self.action
    let elementID = id
    return childEffect.map { followUpAction in
      actionPath.embed(elementID, followUpAction)
    }
  }
}
