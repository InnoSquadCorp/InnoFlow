import InnoFlow
import InnoFlowSwiftUI
import SwiftUI

@InnoFlow
struct BasicsFeature {
  struct State: Equatable, Sendable, DefaultInitializable {
    var count = 0
    @BindableField var step = 1
    var eventLog: [String] = []
  }

  enum Action: Equatable, Sendable {
    case increment
    case decrement
    case reset
    case setStep(Int)
    case queueIncrement
    case _applyQueuedIncrement
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .increment:
        state.count += state.step
        state.eventLog.append("increment -> count \(state.count)")
        return .none

      case .decrement:
        state.count -= state.step
        state.eventLog.append("decrement -> count \(state.count)")
        return .none

      case .reset:
        state.count = 0
        state.eventLog.append("reset -> count 0")
        return .none

      case .setStep(let step):
        state.step = max(1, step)
        state.eventLog.append("set step -> \(state.step)")
        return .none

      case .queueIncrement:
        state.eventLog.append("queue increment requested")
        return .send(._applyQueuedIncrement)

      case ._applyQueuedIncrement:
        state.count += state.step
        state.eventLog.append("queued follow-up applied -> count \(state.count)")
        return .none
      }
    }
  }
}

struct BasicsDemoView: View {
  @State private var store = Store(reducer: BasicsFeature())

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        DemoCard(
          title: "What this demonstrates",
          summary:
            "`@InnoFlow`, `Store`, `@BindableField`, and immediate follow-up actions flowing through the queue rather than reducer re-entry."
        )

        VStack(spacing: 12) {
          Text("\(store.count)")
            .font(.system(size: 64, weight: .bold, design: .rounded))
            .accessibilityLabel("Current count \(store.count)")
          Text("Step: \(store.step)")
            .font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

        HStack(spacing: 12) {
          Button("Decrement") { store.send(.decrement) }
            .accessibilityHint("Subtracts the current step from the count")
          Button("Reset") { store.send(.reset) }
            .accessibilityHint("Returns the counter to zero")
          Button("Increment") { store.send(.increment) }
            .accessibilityHint("Adds the current step to the count")
        }
        .buttonStyle(.borderedProminent)

        Button("Queue Follow-Up Increment") {
          store.send(.queueIncrement)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Queue a follow-up increment")
        .accessibilityHint("Dispatches an additional increment through the store queue")

        Stepper(
          "Step",
          value: store.binding(\.$step, to: BasicsFeature.Action.setStep),
          in: 1...10
        )
        .accessibilityHint("Adjusts how much each increment or decrement changes the count")
        .padding()
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

        LogSection(title: "Action Log", entries: store.eventLog)
      }
      .padding()
    }
    .navigationTitle("Basics")
  }
}

#Preview("Basics") {
  NavigationStack {
    BasicsDemoView()
  }
}
