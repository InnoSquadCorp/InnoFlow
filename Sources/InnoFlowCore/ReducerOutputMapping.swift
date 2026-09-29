// MARK: - ReducerOutputMapping.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

/// A reducer wrapper that explicitly lifts child outputs into a parent type.
public struct MapOutputReducer<Base: Reducer, NewOutput: Sendable>: Reducer {
  public typealias State = Base.State
  public typealias Action = Base.Action
  public typealias Output = NewOutput

  private let base: Base
  private let transform: @Sendable (Base.Output) -> NewOutput

  package init(
    base: Base,
    transform: @escaping @Sendable (Base.Output) -> NewOutput
  ) {
    self.base = base
    self.transform = transform
  }

  public func reduce(into state: inout State, action: Action) -> ReducerEffect<Action, Output> {
    base.reduce(into: &state, action: action).mapOutput(transform)
  }
}

extension Reducer {
  /// Maps this reducer's outputs into a parent feature's output type.
  public func mapOutput<NewOutput: Sendable>(
    _ transform: @escaping @Sendable (Output) -> NewOutput
  ) -> MapOutputReducer<Self, NewOutput> {
    MapOutputReducer(base: self, transform: transform)
  }
}

extension Reducer where Output == Never {
  /// Adapts a feature that cannot emit outputs to a parent's output type.
  ///
  /// State transitions, actions, and effect lifetimes are preserved. This
  /// operation is only available for `Never`; use ``mapOutput(_:)`` to
  /// explicitly translate a child that actually emits outputs.
  public func promoteOutput<NewOutput: Sendable>(
    to outputType: NewOutput.Type
  ) -> MapOutputReducer<Self, NewOutput> {
    mapOutput { (never: Never) -> NewOutput in never }
  }
}

extension ReducerEffect where Output == Never {
  /// Reuses an output-free effect in a reducer with a typed output channel.
  ///
  /// No output is emitted or discarded. Action mapping, cancellation, and
  /// timing policies are preserved.
  public func promoteOutput<NewOutput: Sendable>(
    to outputType: NewOutput.Type
  ) -> ReducerEffect<Action, NewOutput> {
    mapOutput { (never: Never) -> NewOutput in never }
  }
}
