import InnoFlow
import InnoFlowSwiftUI
import SwiftUI

@InnoFlow
struct ViewOwnedTaskFeature {
  struct State: Equatable, Sendable, DefaultInitializable {
    var started = 0
    var completed = 0
  }
  enum Action: Equatable, Sendable { case start, completed }
  var body: some Reducer<State, Action, Never> {
    Reduce { state, action in
      switch action {
      case .start:
        state.started += 1
        return .run { send, context in
          do {
            try await context.sleep(for: .milliseconds(300))
            try await context.checkCancellation()
            await send(.completed)
          } catch is CancellationError {
            return
          } catch {
            return
          }
        }
      case .completed:
        state.completed += 1
        return .none
      }
    }
  }
}

@MainActor
struct ViewOwnedTaskExample: View {
  @State private var store = Store(reducer: ViewOwnedTaskFeature())
  @State private var requestID = 0
  @State private var isRequestVisible = true

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("View-owned requests").font(.headline)
      Toggle("Show the view-owned request", isOn: $isRequestVisible)
        .accessibilityIdentifier("view-task.visible")
      if isRequestVisible {
        Text("This view owns one dispatch")
          .innoFlowTask(store, id: requestID, action: .start)
          .accessibilityIdentifier("view-task.owner")
      }
      Button("Restart view-owned request") { requestID += 1 }
        .disabled(!isRequestVisible)
      Button("Start independent request") { store.send(.start) }
        .accessibilityIdentifier("view-task.independent")
      Text("Started: \(store.started), completed: \(store.completed)")
        .accessibilityIdentifier("view-task.counts")
      Text(
        "Hiding the owned view cancels only its request. Independent work keeps running while this store stays alive."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding()
    .background(Color.primary.opacity(0.04))
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}
