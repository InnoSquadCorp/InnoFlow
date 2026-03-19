// MARK: - Store+SwiftUIBindings.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import SwiftUI

extension Store {
  /// Creates a SwiftUI `Binding` for properties marked with `@BindableField`.
  ///
  /// Pass the projected key path of the bindable field, for example `\.$step`.
  public func binding<Value>(
    _ keyPath: KeyPath<R.State, BindableProperty<Value>>,
    send action: @escaping @Sendable (Value) -> R.Action
  ) -> Binding<Value> where Value: Equatable & Sendable {
    Binding(
      get: { self.state[keyPath: keyPath].value },
      set: { self.send(action($0)) }
    )
  }
}

extension ScopedStore {
  /// Creates a SwiftUI `Binding` for projected bindable child fields such as `\.$step`.
  public func binding<Value>(
    _ keyPath: KeyPath<ChildState, BindableProperty<Value>>,
    send action: @escaping @Sendable (Value) -> ChildAction
  ) -> Binding<Value> where Value: Equatable & Sendable {
    Binding(
      get: { self.state[keyPath: keyPath].value },
      set: { self.send(action($0)) }
    )
  }
}
