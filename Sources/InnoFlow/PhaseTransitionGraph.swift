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

  /// Creates a graph from an explicit list of legal transitions.
  public init(_ transitions: some Sequence<PhaseTransition<Phase>>) {
    var adjacency: [Phase: Set<Phase>] = [:]
    for transition in transitions {
      adjacency[transition.from, default: []].insert(transition.to)
    }
    self.adjacency = adjacency
  }

  /// Creates a graph from adjacency data keyed by source phase.
  public init(_ adjacency: [Phase: Set<Phase>]) {
    self.adjacency = adjacency
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
    return .init(adjacency)
  }
}
