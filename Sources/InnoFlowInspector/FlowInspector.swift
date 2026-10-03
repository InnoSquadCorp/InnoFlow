#if canImport(SwiftUI)
  public import SwiftUI
  public import InnoFlowCore
  import Foundation

  /// An opt-in, read-only diagnostic surface for development builds.
  ///
  /// Mount it behind an app-controlled DEBUG presentation. It reads only bounded,
  /// payload-free StoreDiagnostics and an explicitly supplied phase graph. It
  /// does not send actions, cancel work, or change feature state. watchOS and tvOS
  /// use the same compact list presentation without platform-specific controls.
  @MainActor
  public struct FlowInspector: View {
    private let diagnostics: StoreDiagnostics
    private let graph: FlowInspectorPhaseGraph?
    private let recordLimit: Int
    private let laneSnapshots: (@MainActor () -> [EffectRunLaneSnapshot])?

    public init(
      diagnostics: StoreDiagnostics,
      graph: FlowInspectorPhaseGraph? = nil,
      recordLimit: Int = 32,
      laneSnapshots: (@MainActor () -> [EffectRunLaneSnapshot])? = nil
    ) {
      self.diagnostics = diagnostics
      self.graph = graph
      self.recordLimit = max(0, min(recordLimit, 200))
      self.laneSnapshots = laneSnapshots
    }

    public var body: some View {
      TimelineView(.periodic(from: .now, by: 0.5)) { _ in
        let snapshot = diagnostics.snapshot(activeLimit: recordLimit)
        List {
          if let graph {
            Section("Phase graph") {
              ForEach(graph.nodes) { node in
                HStack {
                  Text(verbatim: node.label)
                  if node.isCurrent {
                    Spacer()
                    Text("Current").foregroundStyle(.tint)
                  }
                }
                .accessibilityLabel(
                  Text(verbatim: node.label + (node.isCurrent ? ", current phase" : "")))
              }
              ForEach(graph.edges) { edge in
                Text(
                  verbatim: "\(graph.nodes[edge.source].label) → \(graph.nodes[edge.target].label)"
                )
                .font(.caption)
              }
            }
          }
          Section("Active dispatches") {
            if snapshot.activeDispatches.isEmpty { Text("No active dispatches") }
            ForEach(snapshot.activeDispatches, id: \.dispatchID) { dispatch in
              VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: dispatch.dispatchID.description).font(.caption.monospaced())
                Text("Running: \(dispatch.activeRunCount), queued: \(dispatch.queuedRunCount)")
                if dispatch.isCancellationRequested {
                  Text("Cancellation requested").foregroundStyle(.secondary)
                }
              }
            }
          }
          if let laneSnapshots {
            Section("Scheduler lane admission") {
              ForEach(Array(laneSnapshots().prefix(recordLimit)), id: \.id) { lane in
                VStack(alignment: .leading, spacing: 4) {
                  Text(verbatim: String(describing: lane.policy)).font(.caption)
                  Text("Pending: \(lane.pendingRequestCount)")
                  Text(lane.isStartAdmitted ? "Head admitted" : "Head awaiting admission")
                  if lane.isCancellationRequested {
                    Text("Cancellation requested").foregroundStyle(.secondary)
                  }
                }
              }
              Text("Head admission is separate from physical running work.").font(.caption)
            }
          }
          Section("Recent lifecycle") {
            ForEach(Array(snapshot.records.suffix(recordLimit)), id: \.index) { record in
              VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: String(describing: record.kind)).font(.caption)
                Text(verbatim: record.dispatchID.description).font(.caption2.monospaced())
                  .foregroundStyle(.secondary)
              }
            }
            Text("Older records discarded: \(snapshot.droppedRecordCount)").font(.caption)
          }
        }
      }
      .navigationTitle("Flow Inspector")
      .accessibilityIdentifier("innoflow.inspector")
    }
  }
#endif
