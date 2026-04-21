// MARK: - Store+SwiftUIBindings.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import SwiftUI

extension Store {
  /// Creates a SwiftUI `Binding` for properties marked with `@BindableField`.
  ///
  /// Pass the projected key path of the bindable field, for example `\.$step`.
  /// Always spell the argument label explicitly: once ``binding(_:to:)`` is in
  /// scope, unlabeled trailing-closure calls like
  /// `store.binding(\.$step) { Feature.Action.setStep($0) }` are ambiguous.
  public func binding<Value>(
    _ keyPath: KeyPath<R.State, BindableProperty<Value>>,
    send action: @escaping @Sendable (Value) -> R.Action
  ) -> Binding<Value> where Value: Equatable & Sendable {
    Binding(
      get: { self.state[keyPath: keyPath].value },
      set: { self.send(action($0)) }
    )
  }

  /// Alias for ``binding(_:send:)`` that reads more naturally when passing an
  /// enum case constructor as the action builder, for example
  /// `store.binding(\.$step, to: Feature.Action.setStep)`.
  ///
  /// The `send:` overload continues to work without deprecation — the two
  /// spellings are semantically identical and both call into the same
  /// underlying `Binding` constructor. Calls must continue to use an explicit
  /// `send:` or `to:` label because unlabeled trailing-closure calls are now
  /// ambiguous.
  public func binding<Value>(
    _ keyPath: KeyPath<R.State, BindableProperty<Value>>,
    to action: @escaping @Sendable (Value) -> R.Action
  ) -> Binding<Value> where Value: Equatable & Sendable {
    binding(keyPath, send: action)
  }
}

extension ScopedStore {
  /// Creates a SwiftUI `Binding` for projected bindable child fields such as `\.$step`.
  /// Always spell the argument label explicitly: once ``binding(_:to:)`` is in
  /// scope, unlabeled trailing-closure calls are ambiguous.
  public func binding<Value>(
    _ keyPath: KeyPath<ChildState, BindableProperty<Value>>,
    send action: @escaping @Sendable (Value) -> ChildAction
  ) -> Binding<Value> where Value: Equatable & Sendable {
    Binding(
      get: { self.state[keyPath: keyPath].value },
      set: { self.send(action($0)) }
    )
  }

  /// Alias for ``binding(_:send:)`` that reads more naturally when passing an
  /// enum case constructor as the action builder, for example
  /// `rowStore.binding(\.$isFavorite, to: RowFeature.Action.setFavorite)`.
  /// Calls must continue to use an explicit `send:` or `to:` label because
  /// unlabeled trailing-closure calls are ambiguous.
  public func binding<Value>(
    _ keyPath: KeyPath<ChildState, BindableProperty<Value>>,
    to action: @escaping @Sendable (Value) -> ChildAction
  ) -> Binding<Value> where Value: Equatable & Sendable {
    binding(keyPath, send: action)
  }
}
