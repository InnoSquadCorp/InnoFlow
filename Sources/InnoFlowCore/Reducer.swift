// MARK: - Reducer.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

/// A protocol that defines a feature's state transition logic.
///
/// InnoFlow uses a single reducer entry point:
/// `Action -> reduce(into:action:) -> EffectTask<Action>`
///
/// Reducers synchronously mutate state and return asynchronous work as `EffectTask`.
///
/// Reducers are not required to be `Sendable`. Composition-oriented reducers such as
/// `Scope` and phase validators naturally capture key paths, and reducer instances
/// themselves are never sent across actor boundaries by the runtime.
public protocol Reducer<State, Action> {

  /// The state managed by this reducer.
  associatedtype State: Sendable

  /// The actions accepted by this reducer.
  associatedtype Action: Sendable

  /// Applies an action to state and returns follow-up effects.
  ///
  /// - Parameters:
  ///   - state: Mutable state for synchronous transition.
  ///   - action: Incoming action.
  /// - Returns: The effect task describing async follow-up work.
  func reduce(into state: inout State, action: Action) -> EffectTask<Action>
}
