import SwiftUI

public struct InnoFlowSampleAppRootView: View {
  private let launchDemo = ProcessInfo.processInfo.environment["INNOFLOW_SAMPLE_DEMO"].flatMap(
    SampleDemo.init(launchToken:))
  @State private var presentedModalDemo: SampleDemo?

  public init() {}

  public var body: some View {
    Group {
      if let launchDemo {
        sampleDemoView(for: launchDemo)
      } else {
        sampleHubView
      }
    }
  }

  @ViewBuilder
  private func sampleDemoView(for demo: SampleDemo) -> some View {
    switch demo {
    case .basics:
      BasicsDemoView()
    case .orchestration:
      OrchestrationDemoView()
    case .phaseDrivenFSM:
      PhaseDrivenFSMDemoView()
    case .routerComposition:
      RouterCompositionDemoView()
    case .authenticationFlow:
      AuthenticationFlowDemoView()
    case .listDetailPagination:
      ListDetailPaginationDemoView()
    case .offlineFirst:
      OfflineFirstDemoView()
    case .realtimeStream:
      RealtimeStreamDemoView()
    }
  }

  private var sampleHubView: some View {
    NavigationStack {
      List(SampleDemo.allCases) { demo in
        if demo.prefersModalPresentation {
          Button {
            presentedModalDemo = demo
          } label: {
            sampleRow(for: demo)
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier(demo.accessibilityIdentifier)
          .accessibilityLabel(demo.accessibilityLabel)
          .accessibilityHint(demo.accessibilityHint)
        } else {
          NavigationLink(value: demo) {
            sampleRow(for: demo)
          }
          .accessibilityIdentifier(demo.accessibilityIdentifier)
          .accessibilityLabel(demo.accessibilityLabel)
          .accessibilityHint(demo.accessibilityHint)
        }
      }
      .navigationTitle("InnoFlow Samples")
      .safeAreaInset(edge: .top) {
        DemoCard(
          title: "Canonical Reference App",
          summary:
            "Explore queue-based dispatch, orchestration, phase-driven state, and app-boundary navigation in one place."
        )
        .padding(.horizontal)
        .padding(.top, 8)
      }
      .navigationDestination(for: SampleDemo.self) { demo in
        sampleDemoView(for: demo)
      }
    }
    .modalPresentation(item: $presentedModalDemo) { demo in
      modalSampleDemoView(for: demo)
    }
  }

  private func sampleRow(for demo: SampleDemo) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(demo.title)
        .font(.headline)
        .accessibilityIdentifier(demo.titleAccessibilityIdentifier)
      Text(demo.subtitle)
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }

  private func modalSampleDemoView(for demo: SampleDemo) -> some View {
    ZStack(alignment: .topTrailing) {
      sampleDemoView(for: demo)

      Button("Close") {
        presentedModalDemo = nil
      }
      .buttonStyle(.borderedProminent)
      .padding()
      .accessibilityIdentifier("sample.dismiss-modal")
      .accessibilityLabel("Close sample demo")
      .accessibilityHint("Dismisses the full-screen demo and returns to the sample hub")
    }
  }
}

extension View {
  @ViewBuilder
  fileprivate func modalPresentation<Item: Identifiable, Content: View>(
    item: Binding<Item?>,
    @ViewBuilder content: @escaping (Item) -> Content
  ) -> some View {
    #if os(macOS)
      sheet(item: item, content: content)
    #else
      fullScreenCover(item: item, content: content)
    #endif
  }
}

enum SampleDemo: String, CaseIterable, Identifiable, Hashable {
  case basics
  case orchestration
  case phaseDrivenFSM
  case routerComposition
  case authenticationFlow
  case listDetailPagination
  case offlineFirst
  case realtimeStream

  var id: String { rawValue }

  var title: String {
    switch self {
    case .basics:
      "Basics"
    case .orchestration:
      "Orchestration"
    case .phaseDrivenFSM:
      "Phase-Driven FSM"
    case .routerComposition:
      "App-Boundary Navigation"
    case .authenticationFlow:
      "Authentication Flow"
    case .listDetailPagination:
      "List + Detail + Pagination"
    case .offlineFirst:
      "Offline-First"
    case .realtimeStream:
      "Realtime Stream"
    }
  }

  var subtitle: String {
    switch self {
    case .basics:
      "Reducer basics, bindable state, and queue-based follow-up actions."
    case .orchestration:
      "Parent-child orchestration, cancellation fan-out, and long-running pipelines."
    case .phaseDrivenFSM:
      "Business lifecycle modeling with a documented phase graph."
    case .routerComposition:
      "Pure SwiftUI route state driven at the app/coordinator boundary."
    case .authenticationFlow:
      "Multi-step credential + MFA flow modeled with PhaseMap and cancellable retry."
    case .listDetailPagination:
      "Paginated list with per-row ForEachReducer and scoped detail projection."
    case .offlineFirst:
      "Optimistic local update with debounced save and server-side rollback."
    case .realtimeStream:
      "Looping .run subscription driven by an injectable clock dependency."
    }
  }

  var accessibilityLabel: String {
    "\(title). \(subtitle)"
  }

  var accessibilityHint: String {
    switch self {
    case .basics:
      "Opens the basics demo for queue-based actions and bindable reducer state"
    case .orchestration:
      "Opens the orchestration demo for parent-child coordination and cancellation"
    case .phaseDrivenFSM:
      "Opens the phase-driven finite-state-machine demo with documented legal transitions"
    case .routerComposition:
      "Opens the app-boundary navigation demo in a modal presentation"
    case .authenticationFlow:
      "Opens the multi-step authentication sample with PhaseMap and cancellable retry"
    case .listDetailPagination:
      "Opens the paginated list sample with per-row child reducer and scoped detail"
    case .offlineFirst:
      "Opens the offline-first sample with optimistic update, debounce, and rollback"
    case .realtimeStream:
      "Opens the realtime stream sample driven by an injectable clock"
    }
  }

  var accessibilityIdentifier: String {
    switch self {
    case .basics:
      "sample.basics"
    case .orchestration:
      "sample.orchestration"
    case .phaseDrivenFSM:
      "sample.phase-driven-fsm"
    case .routerComposition:
      "sample.router-composition"
    case .authenticationFlow:
      "sample.authentication-flow"
    case .listDetailPagination:
      "sample.list-detail-pagination"
    case .offlineFirst:
      "sample.offline-first"
    case .realtimeStream:
      "sample.realtime-stream"
    }
  }

  var titleAccessibilityIdentifier: String {
    "\(accessibilityIdentifier).title"
  }

  var prefersModalPresentation: Bool {
    self == .routerComposition
  }

  init?(launchToken: String) {
    switch launchToken {
    case "basics", "sample.basics":
      self = .basics
    case "orchestration", "sample.orchestration":
      self = .orchestration
    case "phase-driven-fsm", "phaseDrivenFSM", "sample.phase-driven-fsm":
      self = .phaseDrivenFSM
    case "router-composition", "routerComposition", "sample.router-composition":
      self = .routerComposition
    case "authentication-flow", "authenticationFlow", "sample.authentication-flow":
      self = .authenticationFlow
    case "list-detail-pagination", "listDetailPagination", "sample.list-detail-pagination":
      self = .listDetailPagination
    case "offline-first", "offlineFirst", "sample.offline-first":
      self = .offlineFirst
    case "realtime-stream", "realtimeStream", "sample.realtime-stream":
      self = .realtimeStream
    default:
      return nil
    }
  }
}

struct DemoCard: View {
  let title: String
  let summary: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.headline)
      Text(summary)
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding()
    .background(Color.primary.opacity(0.06))
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}

struct LogSection: View {
  let title: String
  let entries: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.headline)

      if entries.isEmpty {
        Text("No events yet.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      } else {
        ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
          HStack(alignment: .top, spacing: 8) {
            Text("\(index + 1).")
              .font(.footnote.monospacedDigit())
              .foregroundStyle(.secondary)
            Text(entry)
              .font(.footnote)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding()
    .background(Color.primary.opacity(0.04))
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}
