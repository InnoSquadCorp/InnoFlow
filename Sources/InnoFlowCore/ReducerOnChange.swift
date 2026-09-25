// MARK: - ReducerOnChange.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

/// Runs an additional effect when a small equatable state projection changes.
public struct OnChangeReducer<Base: Reducer, Value: Equatable & Sendable>: Reducer {
  public typealias State = Base.State
  public typealias Action = Base.Action
  public typealias Output = Base.Output

  private let base: Base
  private let value: KeyPath<State, Value>
  private let operation: (Value, Value) -> ReducerEffect<Action, Output>

  package init(
    base: Base,
    value: KeyPath<State, Value>,
    operation: @escaping (Value, Value) -> ReducerEffect<Action, Output>
  ) {
    self.base = base
    self.value = value
    self.operation = operation
  }

  public func reduce(into state: inout State, action: Action) -> ReducerEffect<Action, Output> {
    let oldValue = state[keyPath: value]
    let baseEffect = base.reduce(into: &state, action: action)
    let newValue = state[keyPath: value]
    guard oldValue != newValue else { return baseEffect }
    return .merge(baseEffect, operation(oldValue, newValue))
  }
}

extension Reducer {
  /// Observes one equatable state slice after this reducer handles each action.
  ///
  /// Keep the observed value narrow. Comparing an entire app state on every
  /// action can turn an otherwise local effect boundary into global work.
  public func onChange<Value: Equatable & Sendable>(
    of value: KeyPath<State, Value>,
    perform operation: @escaping (Value, Value) -> ReducerEffect<Action, Output>
  ) -> OnChangeReducer<Self, Value> {
    OnChangeReducer(base: self, value: value, operation: operation)
  }
}
