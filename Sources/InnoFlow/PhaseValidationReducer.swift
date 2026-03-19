// MARK: - PhaseValidationReducer.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

private struct PhaseValidatedReducer<Base: Reducer, Phase: Hashable & Sendable>: Reducer {
  typealias State = Base.State
  typealias Action = Base.Action

  let base: Base
  let phase: KeyPath<State, Phase>
  let graph: PhaseTransitionGraph<Phase>

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    let previousPhase = state[keyPath: phase]
    let effect = base.reduce(into: &state, action: action)
    let nextPhase = state[keyPath: phase]

    guard previousPhase != nextPhase else {
      return effect
    }

    guard graph.allows(from: previousPhase, to: nextPhase) else {
      assertionFailure(
        """
        Illegal phase transition detected.

        Action:
        \(action)

        From:
        \(previousPhase)

        To:
        \(nextPhase)

        Allowed next phases:
        \(graph.successors(from: previousPhase))
        """
      )
      return effect
    }

    return effect
  }
}

extension Reducer {
  /// Validates legal phase changes in debug builds while keeping the reducer contract unchanged.
  public func validatePhaseTransitions<Phase: Hashable & Sendable>(
    tracking phase: KeyPath<State, Phase>,
    through graph: PhaseTransitionGraph<Phase>
  ) -> some Reducer<State, Action> {
    PhaseValidatedReducer(base: self, phase: phase, graph: graph)
  }
}
