import Foundation

public enum SampleCategory: String, Sendable {
  case fundamentals
  case flow
  case crossFramework
}

public enum SampleBoundaryTag: String, Sendable {
  case core
  case navigation
  case transport
  case dependencies
}

public struct SampleDemoMetadata: Identifiable, Hashable, Sendable {
  public let demo: SampleDemo
  public let title: String
  public let subtitle: String
  public let category: SampleCategory
  public let boundaryTag: SampleBoundaryTag
  public let launchTokens: [String]
  public let accessibilityIdentifier: String
  public let accessibilityLabel: String
  public let accessibilityHint: String
  public let prefersModalPresentation: Bool

  public init(
    demo: SampleDemo,
    title: String,
    subtitle: String,
    category: SampleCategory,
    boundaryTag: SampleBoundaryTag,
    launchTokens: [String],
    accessibilityIdentifier: String,
    accessibilityLabel: String,
    accessibilityHint: String,
    prefersModalPresentation: Bool
  ) {
    self.demo = demo
    self.title = title
    self.subtitle = subtitle
    self.category = category
    self.boundaryTag = boundaryTag
    self.launchTokens = launchTokens
    self.accessibilityIdentifier = accessibilityIdentifier
    self.accessibilityLabel = accessibilityLabel
    self.accessibilityHint = accessibilityHint
    self.prefersModalPresentation = prefersModalPresentation
  }

  public var id: String { accessibilityIdentifier }
  public var titleAccessibilityIdentifier: String { "\(accessibilityIdentifier).title" }
}

public enum SampleDemo: String, CaseIterable, Identifiable, Hashable, Sendable {
  case basics
  case orchestration
  case phaseDrivenFSM
  case routerComposition
  case authenticationFlow
  case listDetailPagination
  case offlineFirst
  case realtimeStream
  case formValidation
  case bidirectionalWebSocket

  public var id: String { rawValue }

  public var metadata: SampleDemoMetadata {
    switch self {
    case .basics:
      return .init(
        demo: self,
        title: "Basics",
        subtitle: "Reducer basics, bindable state, and queue-based follow-up actions.",
        category: .fundamentals,
        boundaryTag: .core,
        launchTokens: ["basics", "sample.basics"],
        accessibilityIdentifier: "sample.basics",
        accessibilityLabel:
          "Basics. Reducer basics, bindable state, and queue-based follow-up actions.",
        accessibilityHint:
          "Opens the basics demo for queue-based actions and bindable reducer state",
        prefersModalPresentation: false
      )
    case .orchestration:
      return .init(
        demo: self,
        title: "Orchestration",
        subtitle: "Parent-child orchestration, cancellation fan-out, and long-running pipelines.",
        category: .flow,
        boundaryTag: .dependencies,
        launchTokens: ["orchestration", "sample.orchestration"],
        accessibilityIdentifier: "sample.orchestration",
        accessibilityLabel:
          "Orchestration. Parent-child orchestration, cancellation fan-out, and long-running pipelines.",
        accessibilityHint:
          "Opens the orchestration demo for parent-child coordination and cancellation",
        prefersModalPresentation: false
      )
    case .phaseDrivenFSM:
      return .init(
        demo: self,
        title: "Phase-Driven FSM",
        subtitle: "Business lifecycle modeling with a documented phase graph.",
        category: .flow,
        boundaryTag: .core,
        launchTokens: ["phase-driven-fsm", "phaseDrivenFSM", "sample.phase-driven-fsm"],
        accessibilityIdentifier: "sample.phase-driven-fsm",
        accessibilityLabel:
          "Phase-Driven FSM. Business lifecycle modeling with a documented phase graph.",
        accessibilityHint:
          "Opens the phase-driven finite-state-machine demo with documented legal transitions",
        prefersModalPresentation: false
      )
    case .routerComposition:
      return .init(
        demo: self,
        title: "App-Boundary Navigation",
        subtitle: "Pure SwiftUI route state driven at the app/coordinator boundary.",
        category: .crossFramework,
        boundaryTag: .navigation,
        launchTokens: ["router-composition", "routerComposition", "sample.router-composition"],
        accessibilityIdentifier: "sample.router-composition",
        accessibilityLabel:
          "App-Boundary Navigation. Pure SwiftUI route state driven at the app and coordinator boundary.",
        accessibilityHint:
          "Opens the app-boundary navigation demo in a modal presentation",
        prefersModalPresentation: true
      )
    case .authenticationFlow:
      return .init(
        demo: self,
        title: "Authentication Flow",
        subtitle: "Multi-step credential + MFA flow modeled with PhaseMap and cancellable retry.",
        category: .flow,
        boundaryTag: .dependencies,
        launchTokens: ["authentication-flow", "authenticationFlow", "sample.authentication-flow"],
        accessibilityIdentifier: "sample.authentication-flow",
        accessibilityLabel:
          "Authentication Flow. Multi-step credential and MFA flow modeled with PhaseMap and cancellable retry.",
        accessibilityHint:
          "Opens the multi-step authentication sample with PhaseMap and cancellable retry",
        prefersModalPresentation: false
      )
    case .listDetailPagination:
      return .init(
        demo: self,
        title: "List + Detail + Pagination",
        subtitle: "Paginated list with per-row ForEachReducer and scoped detail projection.",
        category: .flow,
        boundaryTag: .core,
        launchTokens: [
          "list-detail-pagination", "listDetailPagination", "sample.list-detail-pagination",
        ],
        accessibilityIdentifier: "sample.list-detail-pagination",
        accessibilityLabel:
          "List plus Detail plus Pagination. Paginated list with per-row ForEachReducer and scoped detail projection.",
        accessibilityHint:
          "Opens the paginated list sample with per-row child reducer and scoped detail",
        prefersModalPresentation: false
      )
    case .offlineFirst:
      return .init(
        demo: self,
        title: "Offline-First",
        subtitle: "Optimistic local update with debounced save and server-side rollback.",
        category: .flow,
        boundaryTag: .dependencies,
        launchTokens: ["offline-first", "offlineFirst", "sample.offline-first"],
        accessibilityIdentifier: "sample.offline-first",
        accessibilityLabel:
          "Offline-First. Optimistic local update with debounced save and server-side rollback.",
        accessibilityHint:
          "Opens the offline-first sample with optimistic update, debounce, and rollback",
        prefersModalPresentation: false
      )
    case .realtimeStream:
      return .init(
        demo: self,
        title: "Realtime Stream",
        subtitle: "Looping .run subscription driven by an injectable clock dependency.",
        category: .flow,
        boundaryTag: .dependencies,
        launchTokens: ["realtime-stream", "realtimeStream", "sample.realtime-stream"],
        accessibilityIdentifier: "sample.realtime-stream",
        accessibilityLabel:
          "Realtime Stream. Looping run subscription driven by an injectable clock dependency.",
        accessibilityHint:
          "Opens the realtime stream sample driven by an injectable clock",
        prefersModalPresentation: false
      )
    case .formValidation:
      return .init(
        demo: self,
        title: "Form Validation",
        subtitle:
          "Multiple bindable fields, cross-field validation, and submit-or-reset ownership.",
        category: .flow,
        boundaryTag: .core,
        launchTokens: ["form-validation", "formValidation", "sample.form-validation"],
        accessibilityIdentifier: "sample.form-validation",
        accessibilityLabel:
          "Form Validation. Multiple bindable fields, cross-field validation, and submit-or-reset ownership.",
        accessibilityHint:
          "Opens the form-heavy validation sample with multiple bindable fields and reset flow",
        prefersModalPresentation: false
      )
    case .bidirectionalWebSocket:
      return .init(
        demo: self,
        title: "Bidirectional WebSocket",
        subtitle: "Explicitly labeled cross-framework demo with an injected websocket adapter.",
        category: .crossFramework,
        boundaryTag: .transport,
        launchTokens: [
          "bidirectional-websocket", "bidirectionalWebSocket", "sample.bidirectional-websocket",
        ],
        accessibilityIdentifier: "sample.bidirectional-websocket",
        accessibilityLabel:
          "Bidirectional WebSocket. Explicitly labeled cross-framework demo with an injected websocket adapter.",
        accessibilityHint:
          "Opens the cross-framework websocket sample with adapter-owned transport lifecycle",
        prefersModalPresentation: false
      )
    }
  }

  public static var catalog: [SampleDemoMetadata] {
    allCases.map(\.metadata)
  }

  public static func demo(forLaunchToken launchToken: String) -> SampleDemo? {
    allCases.first { $0.metadata.launchTokens.contains(launchToken) }
  }

  public init?(launchToken: String) {
    guard let demo = Self.demo(forLaunchToken: launchToken) else {
      return nil
    }
    self = demo
  }
}
