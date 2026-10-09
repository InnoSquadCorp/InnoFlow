import InnoFlowCore
import InnoFlowInspector
import Testing

@Suite("Inspector graph is display-only")
struct InspectorGraphConsistencyTests {
  private enum Phase: Hashable, Sendable { case idle, loading, complete }
  @Test func currentPhaseAndTopologyArePreserved() {
    let source = PhaseTransitionGraph<Phase>([
      .init(from: .idle, to: .loading), .init(from: .loading, to: .complete),
    ])
    let graph = FlowInspectorPhaseGraph(graph: source, currentPhase: .loading) {
      String(describing: $0)
    }
    #expect(graph.nodes.count == 3)
    #expect(graph.edges.count == 2)
    #expect(graph.nodes.filter(\.isCurrent).map(\.label) == ["loading"])
    #expect(
      graph.edges.allSatisfy {
        graph.nodes.indices.contains($0.source) && graph.nodes.indices.contains($0.target)
      })
    #expect(source.allows(from: .idle, to: .loading))
  }
  @Test func duplicateLabelsDoNotMergeDistinctPhases() {
    let source = PhaseTransitionGraph<Phase>([.init(from: .idle, to: .loading)])
    let graph = FlowInspectorPhaseGraph(graph: source, currentPhase: .loading) { _ in "phase" }
    #expect(graph.nodes.count == 2)
    #expect(graph.nodes.filter(\.isCurrent).count == 1)
    #expect(graph.edges[0].source != graph.edges[0].target)
  }
  @Test func isolatedCurrentPhaseIsStillVisible() {
    let graph = FlowInspectorPhaseGraph(
      graph: PhaseTransitionGraph<Phase>([]), currentPhase: .complete
    ) { _ in "Done" }
    #expect(graph.nodes.count == 1 && graph.nodes[0].isCurrent)
    #expect(graph.edges.isEmpty)
  }
}
