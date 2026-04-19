// Realtime stream subscription driven by a clock dependency.
//
// The reducer wires `.run { send, context in ... }` to an `AsyncStream` and
// emits a tick action every `tickInterval`. Because the clock is a
// construction-time dependency (`StoreClock`), tests swap in a
// `ManualTestClock` to advance time deterministically — no wall-clock sleep.
//
// Subscription lifetime is controlled with `.cancellable("stream", ...)`
// plus `.cancel("stream")`. Repeated "Start" calls coalesce because
// `cancelInFlight: true` is set.

import Foundation
import InnoFlow
import SwiftUI

// MARK: - Feature

@InnoFlow
struct RealtimeStreamFeature {
  struct Dependencies: Sendable {
    let tickInterval: Duration
  }

  struct State: Equatable, Sendable, DefaultInitializable {
    var ticks: [Int] = []
    var isSubscribed: Bool = false
  }

  enum Action: Equatable, Sendable {
    case subscribe
    case unsubscribe
    case clearTicks
    case _tick(Int)
  }

  let dependencies: Dependencies

  init(dependencies: Dependencies = .init(tickInterval: .milliseconds(100))) {
    self.dependencies = dependencies
  }

  init(tickInterval: Duration) {
    self.init(dependencies: .init(tickInterval: tickInterval))
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .subscribe:
        guard !state.isSubscribed else { return .none }
        state.isSubscribed = true
        let interval = dependencies.tickInterval
        return .run { send, context in
          var counter = 0
          while true {
            do {
              try await context.sleep(for: interval)
              try await context.checkCancellation()
            } catch is CancellationError {
              return
            } catch {
              return
            }
            counter += 1
            await send(._tick(counter))
          }
        }
        .cancellable("realtime-stream", cancelInFlight: true)

      case .unsubscribe:
        state.isSubscribed = false
        return .cancel("realtime-stream")

      case .clearTicks:
        state.ticks = []
        return .none

      case ._tick(let value):
        state.ticks.append(value)
        return .none
      }
    }
  }
}

// MARK: - View

struct RealtimeStreamDemoView: View {
  @State private var store = Store(reducer: RealtimeStreamFeature())

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        DemoCard(
          title: "What this demonstrates",
          summary:
            "`.run` with a looping `context.sleep` emits ticks through the store's action queue. Tests swap the clock for `ManualTestClock` to advance deterministically."
        )

        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Text("Subscription")
              .font(.headline)
            Spacer()
            Text(store.isSubscribed ? "LIVE" : "OFF")
              .font(.subheadline.monospaced())
              .foregroundStyle(store.isSubscribed ? .green : .secondary)
              .accessibilityIdentifier("realtime.subscription-status")
          }

          HStack {
            Button(store.isSubscribed ? "Restart" : "Subscribe") {
              store.send(.subscribe)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("realtime.subscribe")

            Button("Unsubscribe") {
              store.send(.unsubscribe)
            }
            .buttonStyle(.bordered)
            .disabled(!store.isSubscribed)
            .accessibilityIdentifier("realtime.unsubscribe")

            Button("Clear") {
              store.send(.clearTicks)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("realtime.clear")
          }

          Text("Ticks received: \(store.ticks.count)")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("realtime.tick-count")

          if store.ticks.isEmpty {
            Text("No ticks yet")
              .font(.footnote)
              .foregroundStyle(.secondary)
          } else {
            Text(store.ticks.suffix(12).map(String.init).joined(separator: ", "))
              .font(.footnote.monospacedDigit())
              .accessibilityIdentifier("realtime.last-ticks")
          }
        }
        .padding()
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      }
      .padding()
    }
    .navigationTitle("Realtime Stream")
  }
}

#Preview("Realtime Stream") {
  NavigationStack {
    RealtimeStreamDemoView()
  }
}
