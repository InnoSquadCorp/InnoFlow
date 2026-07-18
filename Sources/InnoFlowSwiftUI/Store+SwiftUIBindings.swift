// MARK: - Store+SwiftUIBindings.swift
// InnoFlow - SwiftUI integration
// Copyright © 2025 InnoSquad. All rights reserved.

@_exported public import InnoFlowCore
public import SwiftUI

extension Store {
  /// Compatibility spelling of the canonical ``binding(_:to:)``.
  ///
  /// The two labels are semantically identical; prefer `to:` in new code.
  /// Existing `send:` and unlabeled trailing-closure call sites continue to
  /// resolve here without deprecation.
  @_disfavoredOverload
  public func binding<Value>(
    _ keyPath: KeyPath<R.State, BindableProperty<Value>>,
    send action: @escaping @Sendable (Value) -> R.Action
  ) -> Binding<Value> where Value: Equatable & Sendable {
    Binding(
      get: { self.state[keyPath: keyPath].value },
      set: { self.send(action($0)) }
    )
  }

  /// Creates a SwiftUI `Binding` for properties marked with `@BindableField`.
  ///
  /// This is the canonical binding spelling. Pass the projected key path of
  /// the bindable field and the action constructor that carries the new
  /// value back into the reducer, for example
  /// `store.binding(\.$step, to: Feature.Action.setStep)`.
  ///
  /// The `send:` overload and the unlabeled trailing-closure form are
  /// compatibility spellings — semantically identical, kept without
  /// deprecation. Prefer `to:` in new code.
  @_disfavoredOverload
  public func binding<Value>(
    _ keyPath: KeyPath<R.State, BindableProperty<Value>>,
    to action: @escaping @Sendable (Value) -> R.Action
  ) -> Binding<Value> where Value: Equatable & Sendable {
    binding(keyPath, send: action)
  }

  /// Compatibility spelling of the canonical ``binding(_:to:)`` for existing
  /// trailing-closure call sites such as
  /// `store.binding(\.$step) { Feature.Action.setStep($0) }`.
  public func binding<Value>(
    _ keyPath: KeyPath<R.State, BindableProperty<Value>>,
    _ action: @escaping @Sendable (Value) -> R.Action
  ) -> Binding<Value> where Value: Equatable & Sendable {
    binding(keyPath, send: action)
  }
}

extension ScopedStore {
  /// Compatibility spelling of the canonical ``binding(_:to:)``.
  ///
  /// The two labels are semantically identical; prefer `to:` in new code.
  /// Existing `send:` and unlabeled trailing-closure call sites continue to
  /// resolve here without deprecation.
  @_disfavoredOverload
  public func binding<Value>(
    _ keyPath: KeyPath<ChildState, BindableProperty<Value>>,
    send action: @escaping @Sendable (Value) -> ChildAction
  ) -> Binding<Value> where Value: Equatable & Sendable {
    Binding(
      get: { self.state[keyPath: keyPath].value },
      set: { self.send(action($0)) }
    )
  }

  /// Creates a SwiftUI `Binding` for projected bindable child fields.
  ///
  /// This is the canonical binding spelling for scoped stores, for example
  /// `rowStore.binding(\.$isFavorite, to: RowFeature.Action.setIsFavorite)`.
  /// The `send:` overload and the unlabeled trailing-closure form are
  /// compatibility spellings — semantically identical, kept without
  /// deprecation. Prefer `to:` in new code.
  @_disfavoredOverload
  public func binding<Value>(
    _ keyPath: KeyPath<ChildState, BindableProperty<Value>>,
    to action: @escaping @Sendable (Value) -> ChildAction
  ) -> Binding<Value> where Value: Equatable & Sendable {
    binding(keyPath, send: action)
  }

  /// Compatibility spelling of the canonical ``binding(_:to:)`` for existing
  /// trailing-closure call sites such as
  /// `rowStore.binding(\.$isFavorite) { RowFeature.Action.setIsFavorite($0) }`.
  public func binding<Value>(
    _ keyPath: KeyPath<ChildState, BindableProperty<Value>>,
    _ action: @escaping @Sendable (Value) -> ChildAction
  ) -> Binding<Value> where Value: Equatable & Sendable {
    binding(keyPath, send: action)
  }
}
