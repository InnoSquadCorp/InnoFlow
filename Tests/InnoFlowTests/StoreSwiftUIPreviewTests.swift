// MARK: - StoreSwiftUIPreviewTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import SwiftUI
import Testing

@testable import InnoFlow
@testable import InnoFlowSwiftUI
@testable import InnoFlowTesting

private struct PreviewFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var count: Int = 0
    var sleptOnce: Bool = false
  }

  enum Action: Equatable, Sendable {
    case increment
    case startDelayed
    case _delayedFinished
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .increment:
      state.count += 1
      return .none
    case .startDelayed:
      return .run { send, context in
        try? await context.sleep(for: .seconds(1))
        await send(._delayedFinished)
      }
    case ._delayedFinished:
      state.sleptOnce = true
      return .none
    }
  }
}

@Suite("Store.preview SwiftUI integration", .serialized)
@MainActor
struct StoreSwiftUIPreviewTests {

  @Test("preview(reducer:initialState:) creates a usable Store with the supplied state")
  func previewCreatesStoreWithExplicitState() {
    let store: Store<PreviewFeature> = .preview(
      reducer: PreviewFeature(),
      initialState: .init(count: 5)
    )

    #expect(store.state.count == 5)
    store.send(.increment)
    #expect(store.state.count == 6)
  }

  @Test("preview(reducer:) uses DefaultInitializable's init for state")
  func previewDefaultInitState() {
    let store: Store<PreviewFeature> = .preview(reducer: PreviewFeature())

    #expect(store.state.count == 0)
    #expect(store.state.sleptOnce == false)
    store.send(.increment)
    #expect(store.state.count == 1)
  }

  @Test("preview(... clock: .manual(testClock)) makes time-sensitive effects deterministic")
  func previewWithManualClockIsDeterministic() async {
    let manual = ManualTestClock()
    let store: Store<PreviewFeature> = .preview(
      reducer: PreviewFeature(),
      initialState: .init(),
      clock: .manual(manual)
    )

    store.send(.startDelayed)

    // The delayed effect is suspended on the manual clock — without advancing
    // it the follow-up action must not have landed yet.
    let suspended = await waitUntilAsync(timeout: .seconds(5)) {
      await manual.sleeperCount > 0
    }
    #expect(suspended)
    #expect(store.state.sleptOnce == false)

    await manual.advance(by: .seconds(1))
    await waitUntil(timeout: .seconds(5)) { store.state.sleptOnce }
    #expect(store.state.sleptOnce == true)
  }

  @Test("preview wires the supplied instrumentation through to effect lifecycle events")
  func previewForwardsInstrumentation() async {
    let probe = InstrumentationProbe()
    let manual = ManualTestClock()
    let store: Store<PreviewFeature> = .preview(
      reducer: PreviewFeature(),
      initialState: .init(),
      clock: .manual(manual),
      instrumentation: .sink { event in
        switch event {
        case .runStarted:
          probe.record("run-started")
        case .runFinished:
          probe.record("run-finished")
        case .actionEmitted(let actionEvent):
          probe.record("emit:\(actionEvent.action)")
        default:
          break
        }
      }
    )

    // The `.startDelayed` reducer branch returns a `.run` effect, which is the
    // only path that surfaces `runStarted` and `actionEmitted` (effect-driven
    // dispatches) — external `store.send(...)` does not.
    store.send(.startDelayed)
    await waitUntil(timeout: .seconds(5)) { probe.events.contains("run-started") }
    await manual.advance(by: .seconds(1))
    await waitUntil(timeout: .seconds(5)) {
      probe.events.contains("emit:_delayedFinished")
        && probe.events.contains("run-finished")
    }

    #expect(probe.events.contains("run-started"))
    #expect(probe.events.contains("emit:_delayedFinished"))
    #expect(probe.events.contains("run-finished"))
  }
}
