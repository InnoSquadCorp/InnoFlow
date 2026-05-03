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

// MARK: - Builder-internal composition types
//
// These five types are emitted by the `ReducerBuilder` result-builder chain:
// `_EmptyReducer` plus the four composition wrappers.
// They preserve concrete reducer types across builder steps so the compiler
// can specialize and inline the aggregate `reduce(into:action:)` call, and
// so the builder chain never materializes an O(N) tower of nested closures.
//
// They are `public` because the builder's return types must cross module
// boundaries (e.g. a reducer authored in a downstream module consumes the
// builder chain emitted here). The leading underscore marks them as
// implementation detail — canonical authoring uses only `CombineReducers`,
// `Reduce`, `Scope`, `IfLet`, `IfCaseLet`, and `ForEachReducer`. The
// principle gates block documentation and canonical samples from exposing
// these names.

/// An empty composition. Emitted by `ReducerBuilder.buildBlock()` when a
/// composition body is syntactically empty. Produces no state mutation
/// and no effect.
public struct _EmptyReducer<State: Sendable, Action: Sendable>: Reducer {
  @inlinable
  public init() {}

  @inlinable
  public func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    .none
  }
}

/// A left-leaning pair composition that runs `first` then `second`, merging
/// their effects. Emitted by `ReducerBuilder.buildPartialBlock(accumulated:next:)`
/// so that a block of N reducers produces a
/// `_ReducerSequence<_ReducerSequence<_ReducerSequence<A, B>, C>, D>` tower
/// of concrete types — the optimizer sees the full composition and can
/// inline or specialize each step instead of going through the type-erased
/// closures the previous builder produced.
///
/// The binary-tree shape is a deliberate fallback from a flat N-way pack:
/// Swift does not yet support same-element requirements on parameter packs
/// (e.g. `repeat (each R).State == State`), which makes a single variadic
/// pack of reducers impossible to constrain to a shared state/action space.
public struct _ReducerSequence<First: Reducer, Second: Reducer>: Reducer
where
  First.State == Second.State,
  First.Action == Second.Action
{
  public typealias State = First.State
  public typealias Action = First.Action

  @usableFromInline let first: First
  @usableFromInline let second: Second

  @inlinable
  init(first: First, second: Second) {
    self.first = first
    self.second = second
  }

  @inlinable
  public func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    let firstEffect = first.reduce(into: &state, action: action)
    let secondEffect = second.reduce(into: &state, action: action)
    return .merge(firstEffect, secondEffect)
  }
}

/// Runs the wrapped reducer when present, or produces no effect.
/// Emitted by `ReducerBuilder.buildOptional(_:)`.
public struct _OptionalReducer<Wrapped: Reducer>: Reducer {
  public typealias State = Wrapped.State
  public typealias Action = Wrapped.Action

  @usableFromInline let wrapped: Wrapped?

  @inlinable
  init(_ wrapped: Wrapped?) {
    self.wrapped = wrapped
  }

  @inlinable
  public func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    wrapped?.reduce(into: &state, action: action) ?? .none
  }
}

/// Runs exactly one of two reducers depending on which branch the
/// builder selected. Emitted by `ReducerBuilder.buildEither(first:)` and
/// `buildEither(second:)`.
public struct _ConditionalReducer<First: Reducer, Second: Reducer>: Reducer
where
  First.State == Second.State,
  First.Action == Second.Action
{
  public typealias State = First.State
  public typealias Action = First.Action

  @usableFromInline enum Branch {
    case first(First)
    case second(Second)
  }

  @usableFromInline let branch: Branch

  @inlinable
  init(branch: Branch) {
    self.branch = branch
  }

  @inlinable
  public func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch branch {
    case .first(let reducer):
      return reducer.reduce(into: &state, action: action)
    case .second(let reducer):
      return reducer.reduce(into: &state, action: action)
    }
  }
}

/// Runs a homogeneous collection of reducers in order and merges their
/// effects. Emitted by `ReducerBuilder.buildArray(_:)` for `for`-loop
/// expansions inside a reducer block.
public struct _ArrayReducer<Element: Reducer>: Reducer {
  public typealias State = Element.State
  public typealias Action = Element.Action

  @usableFromInline let elements: [Element]

  @inlinable
  init(_ elements: [Element]) {
    self.elements = elements
  }

  @inlinable
  public func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    guard !elements.isEmpty else { return .none }
    var effects: [EffectTask<Action>] = []
    effects.reserveCapacity(elements.count)
    for element in elements {
      effects.append(element.reduce(into: &state, action: action))
    }
    return .merge(effects)
  }
}

/// A result builder for reducer composition.
///
/// The builder preserves concrete reducer types through every step so the
/// optimizer sees the full composition as a single generic expression and
/// can inline/specialize the aggregate `reduce(into:action:)` call. See
/// the `_EmptyReducer`, `_ReducerSequence`, `_OptionalReducer`,
/// `_ConditionalReducer`, and `_ArrayReducer` types for the emitted
/// intermediate values.
@resultBuilder
public enum ReducerBuilder<State: Sendable, Action: Sendable> {
  @inlinable
  public static func buildBlock() -> _EmptyReducer<State, Action> {
    _EmptyReducer()
  }

  @inlinable
  public static func buildExpression<R: Reducer>(
    _ reducer: R
  ) -> R where R.State == State, R.Action == Action {
    reducer
  }

  @inlinable
  public static func buildPartialBlock<R: Reducer>(
    first component: R
  ) -> R where R.State == State, R.Action == Action {
    component
  }

  @inlinable
  public static func buildPartialBlock<Accumulated: Reducer, Next: Reducer>(
    accumulated: Accumulated,
    next component: Next
  ) -> _ReducerSequence<Accumulated, Next>
  where
    Accumulated.State == State, Accumulated.Action == Action,
    Next.State == State, Next.Action == Action
  {
    _ReducerSequence(first: accumulated, second: component)
  }

  @inlinable
  public static func buildOptional<R: Reducer>(
    _ component: R?
  ) -> _OptionalReducer<R>
  where R.State == State, R.Action == Action {
    _OptionalReducer(component)
  }

  @inlinable
  public static func buildEither<First: Reducer, Second: Reducer>(
    first component: First
  ) -> _ConditionalReducer<First, Second>
  where
    First.State == State, First.Action == Action,
    Second.State == State, Second.Action == Action
  {
    _ConditionalReducer(branch: .first(component))
  }

  @inlinable
  public static func buildEither<First: Reducer, Second: Reducer>(
    second component: Second
  ) -> _ConditionalReducer<First, Second>
  where
    First.State == State, First.Action == Action,
    Second.State == State, Second.Action == Action
  {
    _ConditionalReducer(branch: .second(component))
  }

  @inlinable
  public static func buildArray<R: Reducer>(
    _ components: [R]
  ) -> _ArrayReducer<R>
  where R.State == State, R.Action == Action {
    _ArrayReducer(components)
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
