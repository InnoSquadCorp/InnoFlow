// MARK: - PhaseMap.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

/// A declarative phase transition specification applied after a base reducer runs.
///
/// ## Resolution complexity
///
/// Per dispatched action, the post-reduce decorator does:
///
/// 1. An `O(1)` lookup of the source phase's rule list via the precomputed
///    `rulesBySourcePhase` dictionary.
/// 2. A linear walk over the declared transitions for that source phase
///    until a matcher returns a payload. Walk length is bounded by the number
///    of `On(...)` declarations under the corresponding `From(...)`.
///
/// Total work per action is therefore `O(transitions in matched phase)`, not
/// `O(total transitions)`. Adding more phases does not increase per-action
/// cost; only adding more `On(...)` rules under a single `From(...)` does.
///
/// Baseline measurements (release configuration, see
/// `Tests/InnoFlowTests/PhaseMapPerfTests.swift`) place dispatch at well
/// under one microsecond even for 64-phase fixtures with 5 transitions per
/// phase. A future per-phase transition index that collapses the linear walk
/// to a single hash lookup would require a `Hashable` constraint on `Action`
/// and an explicit opt-in `PhaseMap` shape; it is intentionally deferred until
/// real workloads show the linear walk is on the hot path.
public enum PhaseMapViolation<Action: Sendable, Phase: Hashable & Sendable>: Sendable {
  case directPhaseMutation(action: Action, previousPhase: Phase, postReducePhase: Phase)
  case undeclaredTarget(
    action: Action,
    sourcePhase: Phase,
    target: Phase,
    declaredTargets: Set<Phase>
  )
}

public struct PhaseMapDiagnostics<Action: Sendable, Phase: Hashable & Sendable>: Sendable {
  public let report: @Sendable (PhaseMapViolation<Action, Phase>) -> Void

  public init(
    report: @escaping @Sendable (PhaseMapViolation<Action, Phase>) -> Void
  ) {
    self.report = report
  }

  public static var disabled: Self {
    .init { _ in }
  }
}

public struct PhaseMap<State: Sendable, Action: Sendable, Phase: Hashable & Sendable> {
  package let phaseKeyPath: WritableKeyPath<State, Phase>
  package let rules: [PhaseRule<State, Action, Phase>]
  package let rulesBySourcePhase: [Phase: [PhaseRule<State, Action, Phase>]]
  package let diagnostics: PhaseMapDiagnostics<Action, Phase>
  /// Source phases that appear in more than one `From(...)` block. Each entry
  /// is reported at most once and preserves the order the duplicate was first
  /// observed. Surfaced through `validationReport(...)`.
  package let duplicateSourcePhases: [Phase]

  public init(
    _ phaseKeyPath: WritableKeyPath<State, Phase>,
    diagnostics: PhaseMapDiagnostics<Action, Phase> = .disabled,
    @PhaseRuleBuilder<State, Action, Phase> _ rules: () -> [PhaseRule<State, Action, Phase>]
  ) {
    self.phaseKeyPath = phaseKeyPath
    self.diagnostics = diagnostics
    let declaredRules = rules()
    self.rules = declaredRules
    self.rulesBySourcePhase = Self.makeRulesBySourcePhase(from: declaredRules)
    self.duplicateSourcePhases = Self.findDuplicateSourcePhases(in: declaredRules)
  }

  public var derivedGraph: PhaseTransitionGraph<Phase> {
    var adjacency: [Phase: Set<Phase>] = [:]
    for rule in rules {
      for transition in rule.transitions {
        adjacency[rule.sourcePhase, default: []].formUnion(transition.declaredTargets)
      }
    }
    return .init(adjacency)
  }

  /// Returns a lightweight report describing which explicitly expected phase triggers
  /// are not covered by the current `PhaseMap` declaration, plus any source phases
  /// that were split across more than one `From(...)` block.
  ///
  /// This helper is intentionally opt-in. `PhaseMap` remains partial by default and
  /// unmatched actions are still legal runtime no-ops. Pass an empty dictionary to
  /// only surface duplicate-`From` diagnostics.
  public func validationReport(
    expectedTriggersByPhase: [Phase: [PhaseMapExpectedTrigger<Action>]] = [:]
  ) -> PhaseMapValidationReport<Phase> {
    var missingTriggers: [PhaseMapValidationReport<Phase>.MissingTrigger] = []

    for (phase, expectedTriggers) in expectedTriggersByPhase {
      let declaredTransitions = (rulesBySourcePhase[phase] ?? []).flatMap(\.transitions)

      for expectedTrigger in expectedTriggers {
        let isCovered = declaredTransitions.contains(where: { transition in
          transition.matches(expectedTrigger.sampleAction)
        })

        guard !isCovered else { continue }
        missingTriggers.append(.init(sourcePhase: phase, trigger: expectedTrigger.label))
      }
    }

    return .init(
      missingTriggers: missingTriggers,
      duplicateSourcePhases: duplicateSourcePhases
    )
  }

  private static func makeRulesBySourcePhase(
    from rules: [PhaseRule<State, Action, Phase>]
  ) -> [Phase: [PhaseRule<State, Action, Phase>]] {
    var rulesBySourcePhase: [Phase: [PhaseRule<State, Action, Phase>]] = [:]
    for rule in rules {
      rulesBySourcePhase[rule.sourcePhase, default: []].append(rule)
    }
    return rulesBySourcePhase
  }

  /// Returns the source phases that appear in more than one `From(...)` block.
  /// Splitting transitions across separate `From(.x)` blocks for the same `.x`
  /// is supported at runtime (ordering is preserved) but is almost always a
  /// declaration mistake; surface it through `validationReport(...)` so authors
  /// can opt into a hard failure.
  private static func findDuplicateSourcePhases(
    in rules: [PhaseRule<State, Action, Phase>]
  ) -> [Phase] {
    var seen: Set<Phase> = []
    var duplicateSet: Set<Phase> = []
    var duplicateOrder: [Phase] = []
    for rule in rules {
      if !seen.insert(rule.sourcePhase).inserted {
        if duplicateSet.insert(rule.sourcePhase).inserted {
          duplicateOrder.append(rule.sourcePhase)
        }
      }
    }
    return duplicateOrder
  }
}

/// An opt-in expected trigger used to validate that a `PhaseMap` explicitly covers
/// the phase transitions a feature considers part of its contract.
public struct PhaseMapExpectedTrigger<Action: Sendable>: Sendable {
  public let label: String
  public let sampleAction: Action

  public init(
    _ label: String,
    sampleAction: Action
  ) {
    self.label = label
    self.sampleAction = sampleAction
  }
}

extension PhaseMapExpectedTrigger where Action: Equatable {
  public static func action(
    _ action: Action,
    label: String? = nil
  ) -> Self {
    .init(label ?? String(reflecting: action), sampleAction: action)
  }
}

extension PhaseMapExpectedTrigger {
  public static func casePath<Value: Sendable>(
    _ path: CasePath<Action, Value>,
    label: String,
    sample payload: Value
  ) -> Self {
    .init(label, sampleAction: path.embed(payload))
  }

  public static func predicate(
    _ label: String,
    sampleAction: Action
  ) -> Self {
    .init(label, sampleAction: sampleAction)
  }
}

public struct PhaseMapValidationReport<Phase: Hashable & Sendable>: Sendable, Equatable {
  public struct MissingTrigger: Sendable, Equatable, Hashable {
    public let sourcePhase: Phase
    public let trigger: String

    public init(sourcePhase: Phase, trigger: String) {
      self.sourcePhase = sourcePhase
      self.trigger = trigger
    }
  }

  public let missingTriggers: [MissingTrigger]
  /// Source phases that were declared via more than one `From(...)` block.
  /// Empty for the canonical "one `From(.x)` block per phase" layout.
  public let duplicateSourcePhases: [Phase]

  public init(
    missingTriggers: [MissingTrigger],
    duplicateSourcePhases: [Phase] = []
  ) {
    self.missingTriggers = missingTriggers
    self.duplicateSourcePhases = duplicateSourcePhases
  }

  public var isEmpty: Bool {
    missingTriggers.isEmpty && duplicateSourcePhases.isEmpty
  }
}

public struct From<State: Sendable, Action: Sendable, Phase: Hashable & Sendable>: Sendable {
  package let rule: PhaseRule<State, Action, Phase>

  public init(
    _ sourcePhase: Phase,
    @PhaseTransitionRuleBuilder<State, Action, Phase> _ transitions: () -> [AnyPhaseTransition<
      State, Action, Phase
    >]
  ) {
    self.rule = .init(sourcePhase: sourcePhase, transitions: transitions())
  }
}

public struct On<State: Sendable, Action: Sendable, Phase: Hashable & Sendable>: Sendable {
  package let transition: AnyPhaseTransition<State, Action, Phase>

  package init<Payload: Sendable>(
    matcher: ActionMatcher<Action, Payload>,
    declaredTargets: Set<Phase>,
    resolve: @escaping @Sendable (State, Payload) -> Phase?
  ) {
    self.transition = .init(
      matches: { matcher.match($0) != nil },
      resolve: { state, action in
        guard let payload = matcher.match(action) else { return nil }
        return resolve(state, payload)
      },
      declaredTargets: declaredTargets
    )
  }
}

extension On where Action: Equatable {
  public init(_ action: Action, to target: Phase) {
    self.init(
      matcher: .action(action),
      declaredTargets: [target]
    ) { _, _ in target }
  }

  public init(
    _ action: Action,
    targets: Set<Phase>,
    resolve: @escaping @Sendable (State) -> Phase?
  ) {
    self.init(
      matcher: .action(action),
      declaredTargets: targets
    ) { state, _ in resolve(state) }
  }
}

extension On {
  public init<Value: Sendable>(_ path: CasePath<Action, Value>, to target: Phase) {
    self.init(
      matcher: .casePath(path),
      declaredTargets: [target]
    ) { _, _ in target }
  }

  public init<Value: Sendable>(
    _ path: CasePath<Action, Value>,
    targets: Set<Phase>,
    resolve: @escaping @Sendable (State, Value) -> Phase?
  ) {
    self.init(
      matcher: .casePath(path),
      declaredTargets: targets,
      resolve: resolve
    )
  }

  public init(
    where predicate: @escaping @Sendable (Action) -> Bool,
    to target: Phase
  ) {
    self.init(
      matcher: .init { action in
        predicate(action) ? action : nil
      },
      declaredTargets: [target]
    ) { _, _ in target }
  }

  public init(
    where predicate: @escaping @Sendable (Action) -> Bool,
    targets: Set<Phase>,
    resolve: @escaping @Sendable (State, Action) -> Phase?
  ) {
    self.init(
      matcher: .init { action in
        predicate(action) ? action : nil
      },
      declaredTargets: targets,
      resolve: resolve
    )
  }
}

@resultBuilder
public enum PhaseRuleBuilder<State: Sendable, Action: Sendable, Phase: Hashable & Sendable> {
  public static func buildBlock(
    _ components: [PhaseRule<State, Action, Phase>]...
  ) -> [PhaseRule<State, Action, Phase>] {
    components.flatMap { $0 }
  }

  public static func buildExpression(
    _ from: From<State, Action, Phase>
  ) -> [PhaseRule<State, Action, Phase>] {
    [from.rule]
  }

  public static func buildOptional(
    _ component: [PhaseRule<State, Action, Phase>]?
  ) -> [PhaseRule<State, Action, Phase>] {
    component ?? []
  }

  public static func buildEither(
    first component: [PhaseRule<State, Action, Phase>]
  ) -> [PhaseRule<State, Action, Phase>] {
    component
  }

  public static func buildEither(
    second component: [PhaseRule<State, Action, Phase>]
  ) -> [PhaseRule<State, Action, Phase>] {
    component
  }

  public static func buildArray(
    _ components: [[PhaseRule<State, Action, Phase>]]
  ) -> [PhaseRule<State, Action, Phase>] {
    components.flatMap { $0 }
  }
}

@resultBuilder
public enum PhaseTransitionRuleBuilder<
  State: Sendable, Action: Sendable, Phase: Hashable & Sendable
> {
  public static func buildBlock(
    _ components: [AnyPhaseTransition<State, Action, Phase>]...
  ) -> [AnyPhaseTransition<State, Action, Phase>] {
    components.flatMap { $0 }
  }

  public static func buildExpression(
    _ on: On<State, Action, Phase>
  ) -> [AnyPhaseTransition<State, Action, Phase>] {
    [on.transition]
  }

  public static func buildOptional(
    _ component: [AnyPhaseTransition<State, Action, Phase>]?
  ) -> [AnyPhaseTransition<State, Action, Phase>] {
    component ?? []
  }

  public static func buildEither(
    first component: [AnyPhaseTransition<State, Action, Phase>]
  ) -> [AnyPhaseTransition<State, Action, Phase>] {
    component
  }

  public static func buildEither(
    second component: [AnyPhaseTransition<State, Action, Phase>]
  ) -> [AnyPhaseTransition<State, Action, Phase>] {
    component
  }

  public static func buildArray(
    _ components: [[AnyPhaseTransition<State, Action, Phase>]]
  ) -> [AnyPhaseTransition<State, Action, Phase>] {
    components.flatMap { $0 }
  }
}

public struct PhaseRule<State: Sendable, Action: Sendable, Phase: Hashable & Sendable>: Sendable {
  package let sourcePhase: Phase
  package let transitions: [AnyPhaseTransition<State, Action, Phase>]
}

public struct AnyPhaseTransition<State: Sendable, Action: Sendable, Phase: Hashable & Sendable>:
  Sendable
{
  package let matches: @Sendable (Action) -> Bool
  package let resolve: @Sendable (State, Action) -> Phase?
  package let declaredTargets: Set<Phase>
}

private struct PhaseMappedReducer<Base: Reducer, Phase: Hashable & Sendable>: Reducer {
  typealias State = Base.State
  typealias Action = Base.Action

  let base: Base
  let phaseMap: PhaseMap<State, Action, Phase>

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    // Snapshot the entire state, not just the phase keypath. If the base
    // reducer illegally mutates the phase, it has very likely also touched
    // coupled domain fields based on that (illegal) phase transition.
    // Reverting only the phase keypath leaves those domain fields in an
    // inconsistent state in release builds where the assertion does not
    // trap. Atomic full-state revert is the only sound fallback.
    let previousState = state
    let previousPhase = state[keyPath: phaseMap.phaseKeyPath]
    let effect = base.reduce(into: &state, action: action)

    let postReducePhase = state[keyPath: phaseMap.phaseKeyPath]
    if postReducePhase != previousPhase {
      phaseMap.diagnostics.report(
        .directPhaseMutation(
          action: action,
          previousPhase: previousPhase,
          postReducePhase: postReducePhase
        )
      )
      assertionFailure(
        """
        Base reducer must not mutate phase directly when PhaseMap is active.
        The entire state has been reverted to its pre-reduce value to keep
        phase and coupled domain fields consistent.
        action: \(String(reflecting: action))
        previousPhase: \(String(reflecting: previousPhase))
        postReducePhase: \(String(reflecting: postReducePhase))
        phaseKeyPath: \(String(reflecting: phaseMap.phaseKeyPath))
        """
      )
      state = previousState
    }

    for rule in phaseMap.rulesBySourcePhase[previousPhase] ?? [] {
      for transition in rule.transitions {
        guard transition.matches(action) else { continue }

        guard let target = transition.resolve(state, action) else {
          return effect
        }

        guard target != previousPhase else {
          return effect
        }

        guard transition.declaredTargets.contains(target) else {
          phaseMap.diagnostics.report(
            .undeclaredTarget(
              action: action,
              sourcePhase: previousPhase,
              target: target,
              declaredTargets: transition.declaredTargets
            )
          )
          assertionFailure(
            """
            PhaseMap resolved a target outside the declared targets.
            action: \(String(reflecting: action))
            sourcePhase: \(String(reflecting: previousPhase))
            target: \(String(reflecting: target))
            declaredTargets: \(String(reflecting: transition.declaredTargets))
            """
          )
          return effect
        }

        state[keyPath: phaseMap.phaseKeyPath] = target
        return effect
      }
    }

    return effect
  }
}

extension Reducer {
  public func phaseMap<Phase: Hashable & Sendable>(
    _ map: PhaseMap<State, Action, Phase>
  ) -> some Reducer<State, Action> {
    PhaseMappedReducer(base: self, phaseMap: map)
  }
}
