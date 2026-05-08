// MARK: - StoreInstrumentationMetricsTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import Testing
import os

@testable import InnoFlow

private struct MetricsTestError: Error, Equatable {}

/// `AsyncThrowingStream.Iterator: Sendable` requires `Failure: Sendable`, which
/// rules out the common `any Error` spelling we want to mix with
/// `CancellationError`. A hand-rolled sequence keeps the iterator
/// unconditionally `Sendable` regardless of deployment target.
private struct EmitOnceThenFailSequence: AsyncSequence, Sendable {
  typealias Element = Int

  struct AsyncIterator: AsyncIteratorProtocol, Sendable {
    var emitted = false
    mutating func next() async throws -> Int? {
      if !emitted {
        emitted = true
        return 7
      }
      throw MetricsTestError()
    }
  }

  func makeAsyncIterator() -> AsyncIterator { AsyncIterator() }
}

private struct MetricsFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var values: [Int] = []
  }

  enum Action: Equatable, Sendable {
    case start
    case startFailing
    case received(Int)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start:
      return .run { send, _ in
        await send(.received(1))
      }
    case .startFailing:
      return .run(
        sequence: { _ in EmitOnceThenFailSequence() },
        transform: { value in .received(value) }
      )
    case .received(let value):
      state.values.append(value)
      return .none
    }
  }
}

@Suite("StoreInstrumentation metrics collector", .serialized)
@MainActor
struct StoreInstrumentationMetricsTests {

  @Test("Collector counts run lifecycle and emitted actions for successful effects")
  func collectsRunLifecycleAndEmissions() async {
    let metrics = StoreInstrumentationMetricsCollector<MetricsFeature.Action>()
    let store = Store(
      reducer: MetricsFeature(),
      initialState: .init(),
      instrumentation: metrics.instrumentation()
    )

    store.send(.start)
    await waitUntil(timeout: .seconds(5)) {
      store.values == [1] && metrics.snapshot().runFinished >= 1
    }

    let snap = metrics.snapshot()
    #expect(snap.runStarted >= 1)
    #expect(snap.runFinished >= 1)
    #expect(snap.runFailed == 0)
    #expect(snap.actionEmitted >= 1)
  }

  @Test("Collector counts runFailed when an effect surfaces a non-cancellation error")
  func collectsRunFailed() async {
    let metrics = StoreInstrumentationMetricsCollector<MetricsFeature.Action>()
    let store = Store(
      reducer: MetricsFeature(),
      initialState: .init(),
      instrumentation: metrics.instrumentation()
    )

    store.send(.startFailing)
    await waitUntil(timeout: .seconds(5)) {
      metrics.snapshot().runFailed >= 1
    }

    let snap = metrics.snapshot()
    #expect(snap.runFailed == 1)
    #expect(snap.runStarted >= 1)
    #expect(store.values == [7])
  }

  @Test("reset() clears every counter back to zero")
  func resetClearsCounters() async {
    let metrics = StoreInstrumentationMetricsCollector<MetricsFeature.Action>()
    let store = Store(
      reducer: MetricsFeature(),
      initialState: .init(),
      instrumentation: metrics.instrumentation()
    )

    store.send(.start)
    await waitUntil(timeout: .seconds(5)) {
      metrics.snapshot().runFinished >= 1
    }
    #expect(metrics.snapshot().runFinished >= 1)

    metrics.reset()
    let snap = metrics.snapshot()
    #expect(snap == .init())
  }

  @Test("Collector composes via .combined(...) with other adapters")
  func composesWithOtherAdapters() async {
    let metrics = StoreInstrumentationMetricsCollector<MetricsFeature.Action>()
    let probe = InstrumentationProbe()

    let store = Store(
      reducer: MetricsFeature(),
      initialState: .init(),
      instrumentation: .combined(
        metrics.instrumentation(),
        .init(
          didFinishRun: { _ in
            probe.record("finished")
          }
        )
      )
    )

    store.send(.start)
    await waitUntil(timeout: .seconds(5)) {
      metrics.snapshot().runFinished >= 1 && probe.events.contains("finished")
    }

    #expect(metrics.snapshot().runFinished >= 1)
    #expect(probe.events.contains("finished"))
  }
}
