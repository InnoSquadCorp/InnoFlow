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
    case missingRoot
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

extension PhaseTransitionGraph {
  /// Creates a simple linear phase graph where each phase points to the next.
  ///
  /// Example:
  /// ```swift
  /// let graph = PhaseTransitionGraph.linear(.idle, .loading, .loaded)
  /// ```
  public static func linear(_ phases: Phase...) -> Self {
    guard phases.count > 1 else {
      return .init([:], suggestedRoot: phases.first)
    }

    var adjacency: [Phase: Set<Phase>] = [:]
    for index in phases.indices.dropLast() {
      adjacency[phases[index], default: []].insert(phases[index + 1])
    }
    return .init(adjacency, suggestedRoot: phases.first)
  }

  /// Validates a graph using its suggested root.
  ///
  /// A suggested root exists when the graph came from `linear(_:)`, from
  /// `PhaseMap.derivedGraph` with an unambiguous entry phase, or from
  /// `PhaseMap.derivedGraph(root:)`. Graphs built directly from transitions
  /// or adjacency have no suggested root and report `.missingRoot`; use the
  /// `validate(allPhases:root:terminalPhases:)` overload for those.
  public func validate(
    allPhases: Set<Phase>,
    terminalPhases: Set<Phase> = []
  ) -> [ValidationIssue] {
    validationReport(allPhases: allPhases, terminalPhases: terminalPhases).issues
  }

  /// Returns a detailed validation report using the graph's suggested root.
  ///
  /// See `validate(allPhases:terminalPhases:)` for which construction paths
  /// carry a suggested root; without one this reports `.missingRoot`.
  public func validationReport(
    allPhases: Set<Phase>,
    terminalPhases: Set<Phase> = []
  ) -> ValidationReport {
    let declaredPhases = allPhases.union(terminalPhases)
    guard let suggestedRoot else {
      let issues: [ValidationIssue] = declaredPhases.isEmpty ? [] : [.missingRoot]
      return .init(
        issues: issues,
        reachable: [],
        unreachable: declaredPhases,
        declaredPhases: declaredPhases,
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

extension PhaseTransitionGraph {
  /// Exports this graph as a deterministic Mermaid state diagram.
  public func mermaidDiagram() -> String {
    let phases = diagramPhases
    let identifiers = Dictionary(
      uniqueKeysWithValues: phases.enumerated().map { ($0.element, phaseID($0.offset)) }
    )
    var lines = ["stateDiagram-v2"]
    for phase in phases {
      guard let identifier = identifiers[phase] else { continue }
      lines.append("  state \"\(diagramLabel(phase))\" as \(identifier)")
    }
    for transition in sortedTransitions {
      guard
        let source = identifiers[transition.from],
        let target = identifiers[transition.to]
      else { continue }
      lines.append("  \(source) --> \(target)")
    }
    return lines.joined(separator: "\n")
  }

  /// Exports this graph as deterministic Graphviz DOT source.
  public func dotGraph(name: String = "PhaseMap") -> String {
    let phases = diagramPhases
    let identifiers = Dictionary(
      uniqueKeysWithValues: phases.enumerated().map { ($0.element, phaseID($0.offset)) }
    )
    var lines = ["digraph \"\(escapeDiagramText(name))\" {"]
    for phase in phases {
      guard let identifier = identifiers[phase] else { continue }
      lines.append("  \(identifier) [label=\"\(diagramLabel(phase))\"];")
    }
    for transition in sortedTransitions {
      guard
        let source = identifiers[transition.from],
        let target = identifiers[transition.to]
      else { continue }
      lines.append("  \(source) -> \(target);")
    }
    lines.append("}")
    return lines.joined(separator: "\n")
  }

  private var diagramPhases: [Phase] {
    Set(adjacency.keys).union(adjacency.values.flatMap { $0 })
      .sorted { String(reflecting: $0) < String(reflecting: $1) }
  }

  private var sortedTransitions: [PhaseTransition<Phase>] {
    transitions.sorted {
      let lhs = "\(String(reflecting: $0.from))->\(String(reflecting: $0.to))"
      let rhs = "\(String(reflecting: $1.from))->\(String(reflecting: $1.to))"
      return lhs < rhs
    }
  }

  private func phaseID(_ index: Int) -> String {
    "phase\(index)"
  }

  private func diagramLabel(_ phase: Phase) -> String {
    escapeDiagramText(String(describing: phase))
  }

  private func escapeDiagramText(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
  }
}

extension PhaseTransitionGraph {
  internal init(_ adjacency: [Phase: Set<Phase>], suggestedRoot: Phase?) {
    self.adjacency = adjacency
    self.suggestedRoot = suggestedRoot
  }

  /// Returns a copy of this graph whose suggested root is `root`.
  ///
  /// Used by `PhaseMap.derivedGraph(root:)` so cyclic graphs (where no
  /// unambiguous entry phase can be inferred from in-degrees) can still
  /// feed the root-inferring `validate` / `validationReport` overloads.
  internal func withSuggestedRoot(_ root: Phase) -> Self {
    .init(adjacency, suggestedRoot: root)
  }
}
