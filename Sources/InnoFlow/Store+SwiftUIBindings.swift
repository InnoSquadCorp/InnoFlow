// MARK: - Store+SwiftUIBindings.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import SwiftUI

extension Store {
  /// Creates a SwiftUI `Binding` for properties marked with `@BindableField`.
  ///
  /// Pass the projected key path of the bindable field, for example `\.$step`.
  /// Always spell the argument label explicitly. Unlabeled calls are an
  /// intentional 3.x migration break. Swift currently diagnoses the
  /// trailing-closure spelling `store.binding(\.$step) { Feature.Action.setStep($0) }`
  /// as an ambiguity with notes that point callers to `send:` or `to:`, while
  /// the parenthesized unlabeled form surfaces a no-exact-matches error with
  /// the same explicit-label guidance.
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
  /// `send:` or `to:` label because unlabeled calls are an intentional 3.x
  /// migration break.
  public func binding<Value>(
    _ keyPath: KeyPath<R.State, BindableProperty<Value>>,
    to action: @escaping @Sendable (Value) -> R.Action
  ) -> Binding<Value> where Value: Equatable & Sendable {
    binding(keyPath, send: action)
  }

  /// Intentional 3.x source break marker for unlabeled spellings. External
  /// callers still surface Swift's explicit-label diagnostics rather than this
  /// message directly.
  @available(
    *,
    unavailable,
    message: "Use 'binding(_:send:)' or 'binding(_:to:)' — unlabeled trailing-closure calls are an intentional 3.x migration break."
  )
  public func binding<Value>(
    _ keyPath: KeyPath<R.State, BindableProperty<Value>>,
    _ action: @escaping @Sendable (Value) -> R.Action
  ) -> Binding<Value> where Value: Equatable & Sendable {
    fatalError("unavailable")
  }
}

extension ScopedStore {
  /// Creates a SwiftUI `Binding` for projected bindable child fields such as `\.$step`.
  /// Always spell the argument label explicitly. Unlabeled calls are an
  /// intentional 3.x migration break. Swift currently diagnoses the
  /// trailing-closure spelling with explicit-label notes, while the
  /// parenthesized unlabeled form surfaces a no-exact-matches error with the
  /// same guidance.
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
  /// unlabeled calls are an intentional 3.x migration break.
  public func binding<Value>(
    _ keyPath: KeyPath<ChildState, BindableProperty<Value>>,
    to action: @escaping @Sendable (Value) -> ChildAction
  ) -> Binding<Value> where Value: Equatable & Sendable {
    binding(keyPath, send: action)
  }

  /// Intentional 3.x source break marker for unlabeled spellings. External
  /// callers still surface Swift's explicit-label diagnostics rather than this
  /// message directly.
  @available(
    *,
    unavailable,
    message: "Use 'binding(_:send:)' or 'binding(_:to:)' — unlabeled trailing-closure calls are an intentional 3.x migration break."
  )
  public func binding<Value>(
    _ keyPath: KeyPath<ChildState, BindableProperty<Value>>,
    _ action: @escaping @Sendable (Value) -> ChildAction
  ) -> Binding<Value> where Value: Equatable & Sendable {
    fatalError("unavailable")
  }
}
