import SwiftUI

public struct InnoFlowSampleAppRootView: View {
  private let launchDemo = ProcessInfo.processInfo.environment["INNOFLOW_SAMPLE_DEMO"].flatMap(
    SampleDemo.init(launchToken:)
  )
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
    case .formValidation:
      FormValidationDemoView()
    case .bidirectionalWebSocket:
      BidirectionalWebSocketDemoView()
    }
  }

  private var sampleHubView: some View {
    NavigationStack {
      List(SampleDemo.catalog) { metadata in
        let demo = metadata.demo
        if metadata.prefersModalPresentation {
          Button {
            presentedModalDemo = demo
          } label: {
            sampleRow(for: metadata)
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier(metadata.accessibilityIdentifier)
          .accessibilityLabel(metadata.accessibilityLabel)
          .accessibilityHint(metadata.accessibilityHint)
        } else {
          NavigationLink(value: demo) {
            sampleRow(for: metadata)
          }
          .accessibilityIdentifier(metadata.accessibilityIdentifier)
          .accessibilityLabel(metadata.accessibilityLabel)
          .accessibilityHint(metadata.accessibilityHint)
        }
      }
      .navigationTitle("InnoFlow Samples")
      .safeAreaInset(edge: .top) {
        DemoCard(
          title: "Canonical Reference App",
          summary:
            "Explore queue-based dispatch, orchestration, phase-driven state, app-boundary navigation, form-heavy bindings, and explicit cross-framework transport composition in one place."
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

  private func sampleRow(for metadata: SampleDemoMetadata) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(metadata.title)
        .font(.headline)
        .accessibilityIdentifier(metadata.titleAccessibilityIdentifier)
      Text(metadata.subtitle)
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
