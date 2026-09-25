// Realtime stream subscription driven by a clock dependency.
//
// The reducer wires `.run { send, context in ... }` to a looping
// `context.sleep(for:)` effect and emits a tick action every `tickInterval`.
// Because the clock is a
// construction-time dependency (`StoreClock`), tests swap in a
// `ManualTestClock` to advance time deterministically — no wall-clock sleep.
//
// Subscription lifetime is controlled with `.cancellable("realtime-stream", ...)`
// plus `.cancel("realtime-stream")`. Repeated "Start" calls coalesce because
// `cancelInFlight: true` restarts the loop.

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
    static let retainedTickLimit = 12

    var ticks: [Int] = []
    var totalTicksReceived = 0
    var isSubscribed: Bool = false

    mutating func appendTick(_ value: Int) {
      totalTicksReceived += 1
      ticks.append(value)
      let overflow = ticks.count - Self.retainedTickLimit
      if overflow > 0 {
        ticks.removeFirst(overflow)
      }
    }
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

  var body: some Reducer<State, Action, Never> {
    Reduce { state, action in
      switch action {
      case .subscribe:
        state.isSubscribed = true
        let interval = dependencies.tickInterval
        return .run { send, context in
          var counter = 0
          while true {
            do {
              try await context.checkCancellation()
              try await context.sleep(for: interval)
              try await context.checkCancellation()
              counter += 1
              await send(._tick(counter))
            } catch is CancellationError {
              return
            } catch {
              print("RealtimeStreamFeature stream loop failed: \(error)")
              return
            }
          }
        }
        .cancellable("realtime-stream", cancelInFlight: true)

      case .unsubscribe:
        state.isSubscribed = false
        return .cancel("realtime-stream")

      case .clearTicks:
        state.ticks = []
        state.totalTicksReceived = 0
        return .none

      case ._tick(let value):
        state.appendTick(value)
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
            .accessibilityLabel(Text(store.isSubscribed ? "Restart" : "Subscribe"))
            .accessibilityHint(Text("Start or restart realtime stream subscription"))
            .accessibilityIdentifier("realtime.subscribe")

            Button("Unsubscribe") {
              store.send(.unsubscribe)
            }
            .buttonStyle(.bordered)
            .disabled(!store.isSubscribed)
            .accessibilityLabel(Text("Unsubscribe"))
            .accessibilityHint(Text("Stop realtime stream subscription"))
            .accessibilityIdentifier("realtime.unsubscribe")

            Button("Clear") {
              store.send(.clearTicks)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(Text("Clear"))
            .accessibilityHint(Text("Clear received realtime stream ticks"))
            .accessibilityIdentifier("realtime.clear")
          }

          Text("Ticks received: \(store.totalTicksReceived)")
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

#if !INNOFLOW_DISABLE_PREVIEWS
  #Preview("Realtime Stream") {
    NavigationStack {
      RealtimeStreamDemoView()
    }
  }
// PreviewsMacros is unavailable in the Swift 6.3 command-line SDK.
#endif
