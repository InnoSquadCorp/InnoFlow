// MARK: - Reducer.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

/// A protocol that defines a feature's state transition logic.
///
/// InnoFlow uses a single reducer entry point:
/// `Action -> reduce(into:action:) -> ReducerEffect<Action, Output>`
///
/// Reducers synchronously mutate state and return asynchronous work as
/// `ReducerEffect<Action, Output>`. Reducers without output may use the
/// `EffectTask<Action>` alias.
///
/// Reducers are not required to be `Sendable`. Composition-oriented reducers such as
/// `Scope` and phase validators naturally capture key paths, and reducer instances
/// themselves are never sent across actor boundaries by the runtime.
public protocol Reducer<State, Action, Output> {

  /// The state managed by this reducer.
  associatedtype State: Sendable

  /// The actions accepted by this reducer.
  associatedtype Action: Sendable

  /// Ephemeral events emitted to an app-boundary coordinator.
  ///
  /// State that must render or restore belongs in `State`; `Output` is for
  /// one-shot commands such as routing or opening a system surface.
  associatedtype Output: Sendable = Never

  /// Applies `action` to mutable `state` and returns follow-up effects.
  ///
  /// - Returns: The effect task describing async follow-up work.
  func reduce(into state: inout State, action: Action) -> ReducerEffect<Action, Output>
}

extension Reducer {
  /// Creates an effect that emits this reducer's declared `Output` type.
  ///
  /// Using `Self.output(...)` keeps the payload tied to the feature's
  /// associated output type instead of relying on an untyped event bus.
  public static func output(_ output: Output) -> ReducerEffect<Action, Output> {
    .output(output)
  }
}
