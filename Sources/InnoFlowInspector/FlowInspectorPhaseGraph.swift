public import InnoFlowCore

/// A display-only graph snapshot. Labels are explicitly supplied by the app;
/// the Inspector never reads or serializes feature State or action payloads.
public struct FlowInspectorPhaseGraph: Sendable, Equatable {
  public struct Node: Sendable, Equatable, Identifiable {
    public let id: Int
    public let label: String
    public let isCurrent: Bool
  }
  public struct Edge: Sendable, Equatable, Identifiable {
    public let source: Int
    public let target: Int
    public var id: String { "\(source):\(target)" }
  }
  public let nodes: [Node]
  public let edges: [Edge]

  public init<Phase: Hashable & Sendable>(
    graph: PhaseTransitionGraph<Phase>, currentPhase: Phase,
    label: (Phase) -> String
  ) {
    var phases = Set(graph.transitions.flatMap { [$0.from, $0.to] })
    phases.insert(currentPhase)
    let ordered = phases.map { ($0, label($0)) }.sorted { $0.1 < $1.1 }
    let indices = Dictionary(
      uniqueKeysWithValues: ordered.enumerated().map { ($0.element.0, $0.offset) })
    nodes = ordered.enumerated().map {
      Node(id: $0.offset, label: $0.element.1, isCurrent: $0.element.0 == currentPhase)
    }
    edges = graph.transitions.map { Edge(source: indices[$0.from]!, target: indices[$0.to]!) }
      .sorted { ($0.source, $0.target) < ($1.source, $1.target) }
  }
}
