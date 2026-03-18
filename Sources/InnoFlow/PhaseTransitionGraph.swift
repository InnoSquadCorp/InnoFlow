// MARK: - PhaseTransitionGraph.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

/// A single legal phase transition for phase-driven feature modeling.
///
/// `PhaseTransition` is intentionally small and deterministic. It is not a
/// general automata runtime and does not model guards, stacks, or
/// non-deterministic transitions. Use it to document and validate feature
/// phases where InnoFlow should remain the top-level orchestration layer.
public struct PhaseTransition<Phase: Hashable & Sendable>: Hashable, Sendable {
  public let from: Phase
  public let to: Phase

  public init(from: Phase, to: Phase) {
    self.from = from
    self.to = to
  }
}

/// A compact graph describing legal phase-to-phase transitions.
///
/// This type is designed for feature-level finite state machine modeling on top
/// of InnoFlow reducers. It keeps the reducer contract unchanged while making
/// legal transitions explicit for documentation, debug assertions, and tests.
public struct PhaseTransitionGraph<Phase: Hashable & Sendable>: Sendable {
  private let adjacency: [Phase: Set<Phase>]
  private let suggestedRoot: Phase?

  /// Creates a graph from an explicit list of legal transitions.
  public init(_ transitions: some Sequence<PhaseTransition<Phase>>) {
    var adjacency: [Phase: Set<Phase>] = [:]
    for transition in transitions {
      adjacency[transition.from, default: []].insert(transition.to)
    }
    self.adjacency = adjacency
    self.suggestedRoot = nil
  }

  /// Creates a graph from adjacency data keyed by source phase.
  public init(_ adjacency: [Phase: Set<Phase>]) {
    self.adjacency = adjacency
    self.suggestedRoot = nil
  }

  /// Returns `true` when a phase can legally move to the next phase.
  public func allows(from: Phase, to: Phase) -> Bool {
    adjacency[from]?.contains(to) == true
  }

  /// Returns all known next phases for the provided phase.
  public func successors(from phase: Phase) -> Set<Phase> {
    adjacency[phase] ?? []
  }

  /// Returns all known outgoing transitions.
  public var transitions: Set<PhaseTransition<Phase>> {
    Set(
      adjacency.flatMap { from, successors in
        successors.map { PhaseTransition(from: from, to: $0) }
      }
    )
  }

  public enum ValidationIssue: Hashable, Sendable {
    case rootNotDeclared(Phase)
    case unreachablePhase(Phase)
    case unknownSuccessor(from: Phase, to: Phase)
    case nonTerminalDeadEnd(Phase)
    case terminalHasOutgoingEdges(Phase)
  }

  public struct ValidationReport: Hashable, Sendable {
    public let issues: [ValidationIssue]
    public let reachable: Set<Phase>
    public let unreachable: Set<Phase>
    public let declaredPhases: Set<Phase>
    public let terminalPhases: Set<Phase>

    public init(
      issues: [ValidationIssue],
      reachable: Set<Phase>,
      unreachable: Set<Phase>,
      declaredPhases: Set<Phase>,
      terminalPhases: Set<Phase>
    ) {
      self.issues = issues
      self.reachable = reachable
      self.unreachable = unreachable
      self.declaredPhases = declaredPhases
      self.terminalPhases = terminalPhases
    }
  }

  /// Validates reachability and terminal-state consistency for a declared phase set.
  public func validate(
    allPhases: Set<Phase>,
    root: Phase,
    terminalPhases: Set<Phase> = []
  ) -> [ValidationIssue] {
    validationReport(
      allPhases: allPhases,
      root: root,
      terminalPhases: terminalPhases
    ).issues
  }

  /// Returns a detailed static validation report for a declared phase set.
  public func validationReport(
    allPhases: Set<Phase>,
    root: Phase,
    terminalPhases: Set<Phase> = []
  ) -> ValidationReport {
    let declaredPhases = allPhases.union(terminalPhases)
    var issues = Set<ValidationIssue>()

    if !allPhases.contains(root) {
      issues.insert(.rootNotDeclared(root))
    }

    for (from, successors) in adjacency {
      for to in successors where !declaredPhases.contains(from) || !declaredPhases.contains(to) {
        issues.insert(.unknownSuccessor(from: from, to: to))
      }
    }

    var visited: Set<Phase> = [root]
    var stack: [Phase] = [root]
    while let phase = stack.popLast() {
      for successor in successors(from: phase) where declaredPhases.contains(successor) {
        if visited.insert(successor).inserted {
          stack.append(successor)
        }
      }
    }

    let unreachable = declaredPhases.subtracting(visited)
    for phase in unreachable {
      issues.insert(.unreachablePhase(phase))
    }

    for phase in declaredPhases {
      let knownSuccessors = successors(from: phase).filter { declaredPhases.contains($0) }
      if terminalPhases.contains(phase), !knownSuccessors.isEmpty {
        issues.insert(.terminalHasOutgoingEdges(phase))
      }
      if !terminalPhases.contains(phase), knownSuccessors.isEmpty {
        issues.insert(.nonTerminalDeadEnd(phase))
      }
    }

    return .init(
      issues: issues.sorted { String(reflecting: $0) < String(reflecting: $1) },
      reachable: visited.intersection(declaredPhases.union([root])),
      unreachable: unreachable,
      declaredPhases: declaredPhases,
      terminalPhases: terminalPhases
    )
  }
}

extension PhaseTransitionGraph: ExpressibleByDictionaryLiteral {
  public init(dictionaryLiteral elements: (Phase, Set<Phase>)...) {
    self.init(Dictionary(uniqueKeysWithValues: elements))
  }
}

public extension PhaseTransitionGraph {
  /// Creates a simple linear phase graph where each phase points to the next.
  ///
  /// Example:
  /// ```swift
  /// let graph = PhaseTransitionGraph.linear(.idle, .loading, .loaded)
  /// ```
  static func linear(_ phases: Phase...) -> Self {
    guard phases.count > 1 else { return .init([:]) }

    var adjacency: [Phase: Set<Phase>] = [:]
    for index in phases.indices.dropLast() {
      adjacency[phases[index], default: []].insert(phases[index + 1])
    }
    return .init(adjacency, suggestedRoot: phases.first)
  }

  /// Validates a graph using the root inferred by `linear(_:)`.
  func validate(
    allPhases: Set<Phase>,
    terminalPhases: Set<Phase> = []
  ) -> [ValidationIssue] {
    guard let suggestedRoot else { return [] }
    return validate(allPhases: allPhases, root: suggestedRoot, terminalPhases: terminalPhases)
  }

  /// Returns a detailed validation report using the root inferred by `linear(_:)`.
  func validationReport(
    allPhases: Set<Phase>,
    terminalPhases: Set<Phase> = []
  ) -> ValidationReport {
    guard let suggestedRoot else {
      return .init(
        issues: [],
        reachable: [],
        unreachable: [],
        declaredPhases: allPhases.union(terminalPhases),
        terminalPhases: terminalPhases
      )
    }
    return validationReport(
      allPhases: allPhases,
      root: suggestedRoot,
      terminalPhases: terminalPhases
    )
  }
}

private extension PhaseTransitionGraph {
  init(_ adjacency: [Phase: Set<Phase>], suggestedRoot: Phase?) {
    self.adjacency = adjacency
    self.suggestedRoot = suggestedRoot
  }
}
