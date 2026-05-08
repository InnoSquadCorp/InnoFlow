// MARK: - PhaseValidationReducer.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

/// A violation produced by `validatePhaseTransitions(...)` when a base reducer
/// moves the tracked phase along an edge that is not declared in the supplied
/// `PhaseTransitionGraph`.
public enum PhaseValidationViolation<Action: Sendable, Phase: Hashable & Sendable>: Sendable {
  case undeclaredTransition(
    action: Action,
    previousPhase: Phase,
    nextPhase: Phase,
    allowedNextPhases: Set<Phase>
  )
}

/// Optional reporter for phase-validation violations.
///
/// `PhaseTransitionGraph` historically reported illegal transitions through
/// `assertionFailure` only, which collapses to a no-op in release builds. Pass
/// a non-`.disabled` value here to forward the violation to logs, signposts,
/// metrics, or any other observability backend in every build configuration.
///
/// When a non-`.disabled` reporter is supplied the debug-build assertion is
/// suppressed because the reporter is treated as the authoritative observation
/// surface. With `.disabled` the legacy debug assertion is preserved verbatim.
public struct PhaseValidationDiagnostics<Action: Sendable, Phase: Hashable & Sendable>: Sendable {
  package let report: (@Sendable (PhaseValidationViolation<Action, Phase>) -> Void)?

  public init(
    report: @escaping @Sendable (PhaseValidationViolation<Action, Phase>) -> Void
  ) {
    self.report = report
  }

  fileprivate init(disabled: Void) {
    self.report = nil
  }

  /// No reporter. Preserves the legacy debug-build assertion behaviour.
  public static var disabled: Self {
    .init(disabled: ())
  }
}

private struct PhaseValidatedReducer<Base: Reducer, Phase: Hashable & Sendable>: Reducer {
  typealias State = Base.State
  typealias Action = Base.Action

  let base: Base
  let phase: KeyPath<State, Phase>
  let graph: PhaseTransitionGraph<Phase>
  let diagnostics: PhaseValidationDiagnostics<Action, Phase>

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    let previousPhase = state[keyPath: phase]
    let effect = base.reduce(into: &state, action: action)
    let nextPhase = state[keyPath: phase]

    guard previousPhase != nextPhase else {
      return effect
    }

    guard graph.allows(from: previousPhase, to: nextPhase) else {
      let allowed = graph.successors(from: previousPhase)

      if let report = diagnostics.report {
        report(
          .undeclaredTransition(
            action: action,
            previousPhase: previousPhase,
            nextPhase: nextPhase,
            allowedNextPhases: allowed
          )
        )
      } else {
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
          \(allowed)
          """
        )
      }
      return effect
    }

    return effect
  }
}

extension Reducer {
  /// Validates legal phase changes after each base reducer run.
  ///
  /// - Parameters:
  ///   - phase: The key path to the tracked phase on `State`.
  ///   - graph: The legal transitions for that phase.
  ///   - diagnostics: Optional reporter for illegal transitions. Defaults to
  ///     `.disabled`, which preserves the historical debug-only
  ///     `assertionFailure`. Pass a non-`.disabled` value to also surface
  ///     violations in release builds.
  public func validatePhaseTransitions<Phase: Hashable & Sendable>(
    tracking phase: KeyPath<State, Phase>,
    through graph: PhaseTransitionGraph<Phase>,
    diagnostics: PhaseValidationDiagnostics<Action, Phase> = .disabled
  ) -> some Reducer<State, Action> {
    PhaseValidatedReducer(
      base: self,
      phase: phase,
      graph: graph,
      diagnostics: diagnostics
    )
  }
}
