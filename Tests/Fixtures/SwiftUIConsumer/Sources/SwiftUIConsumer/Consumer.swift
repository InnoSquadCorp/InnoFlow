import InnoFlowCore
import InnoFlowInspector
import InnoFlowSwiftUI
import SwiftUI

private struct Feature: Reducer {
  struct State: Sendable { var child: Int? = 1 }
  enum Action: Sendable { case close, load }
  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    if case .close = action { state.child = nil }
    return .none
  }
}

/// This independent target must be built with a real Apple SDK.
@MainActor
public struct SwiftUIConsumer: View {
  private let store = Store(reducer: Feature(), initialState: .init())
  private let title = String("Dynamic title")
  private let substring: Substring = "Substring title"[...]
  private let key: LocalizedStringKey = "Localized title"
  public init() {}
  public var body: some View {
    Color.clear
      .innoFlowTask(store, action: .load)
      .innoFlowTask(store, id: 7, action: .load)
      .innoFlowSheet(
        store: store, state: \.child, onDismiss: { .close }, content: { Text("Child \($0)") }
      )
      .innoFlowNavigationDestination(
        store: store, state: \.child, onDismiss: { .close }, content: { Text("Child \($0)") })
  }

  private func compileAlertOverloads() {
    _ = Color.clear.innoFlowAlert(
      "Literal", store: store, state: \.child, onDismiss: { .close },
      actions: { _ in Button("OK") {} }, message: { _ in Text("Message") })
    _ = Color.clear.innoFlowAlert(
      key, store: store, state: \.child, onDismiss: { .close }, actions: { _ in EmptyView() },
      message: { _ in Text("Message") })
    _ = Color.clear.innoFlowAlert(
      title, store: store, state: \.child, onDismiss: { .close }, actions: { _ in EmptyView() },
      message: { _ in Text("Message") })
    _ = Color.clear.innoFlowAlert(
      substring, store: store, state: \.child, onDismiss: { .close }, actions: { _ in EmptyView() },
      message: { _ in Text("Message") })
    _ = Color.clear.innoFlowAlert(
      Text("Rich title").bold(), store: store, state: \.child, onDismiss: { .close },
      actions: { _ in EmptyView() }, message: { _ in Text("Message") })
  }

  private func compileDialogOverloads() {
    _ = Color.clear.innoFlowConfirmationDialog(
      "Literal", store: store, state: \.child, onDismiss: { .close },
      actions: { _ in Button("OK") {} }, message: { _ in Text("Message") })
    _ = Color.clear.innoFlowConfirmationDialog(
      key, store: store, state: \.child, onDismiss: { .close }, actions: { _ in EmptyView() },
      message: { _ in Text("Message") })
    _ = Color.clear.innoFlowConfirmationDialog(
      title, store: store, state: \.child, onDismiss: { .close }, actions: { _ in EmptyView() },
      message: { _ in Text("Message") })
    _ = Color.clear.innoFlowConfirmationDialog(
      substring, store: store, state: \.child, onDismiss: { .close }, actions: { _ in EmptyView() },
      message: { _ in Text("Message") })
    _ = Color.clear.innoFlowConfirmationDialog(
      Text("Rich title").bold(), store: store, state: \.child, onDismiss: { .close },
      actions: { _ in EmptyView() }, message: { _ in Text("Message") })
  }

  private func compilePlatformPresentations() {
    #if !os(macOS)
      _ = Color.clear.innoFlowFullScreenCover(
        store: store, state: \.child, onDismiss: { .close }, content: { Text("Child \($0)") })
    #endif
    #if !os(tvOS) && !os(watchOS)
      _ = Color.clear.innoFlowPopover(
        store: store, state: \.child, onDismiss: { .close }, content: { Text("Child \($0)") })
    #endif
  }
}
