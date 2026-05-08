// MARK: - EffectTaskRunSequenceErrorTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import Testing
import os

@testable import InnoFlow

private enum SequenceErrorMode: Sendable {
  case cancellation
  case custom
}

private struct SequenceTestError: Error, Equatable {
  let message: String
}

/// A hand-rolled async sequence whose iterator is unconditionally `Sendable`.
///
/// `AsyncThrowingStream.Iterator` only conforms to `Sendable` when its `Failure`
/// is itself `Sendable`, which excludes the common `any Error` spelling. Mixing
/// `CancellationError()` with a domain error in the same stream therefore
/// requires a hand-rolled sequence regardless of the deployment-target floor.
private struct EmitOnceThenThrowSequence<Element: Sendable>: AsyncSequence, Sendable {
  let element: Element
  let mode: SequenceErrorMode
  let customError: SequenceTestError

  struct AsyncIterator: AsyncIteratorProtocol, Sendable {
    let element: Element
    let mode: SequenceErrorMode
    let customError: SequenceTestError
    var emitted = false

    mutating func next() async throws -> Element? {
      if !emitted {
        emitted = true
        return element
      }
      switch mode {
      case .cancellation:
        throw CancellationError()
      case .custom:
        throw customError
      }
    }
  }

  func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(element: element, mode: mode, customError: customError)
  }
}

private struct SequenceErrorFeature: Reducer {
  enum Action: Equatable, Sendable {
    case startThrowing(SequenceErrorMode)
    case startThrowingTransformed(SequenceErrorMode)
    case received(Int)
  }

  struct State: Equatable, Sendable, DefaultInitializable {
    var values: [Int] = []
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .startThrowing(let mode):
      return .run { _ in
        EmitOnceThenThrowSequence<Action>(
          element: .received(1),
          mode: mode,
          customError: SequenceTestError(message: "boom")
        )
      }

    case .startThrowingTransformed(let mode):
      return .run(
        sequence: { _ in
          EmitOnceThenThrowSequence<Int>(
            element: 2,
            mode: mode,
            customError: SequenceTestError(message: "transform-boom")
          )
        },
        transform: { value in .received(value) }
      )

    case .received(let value):
      state.values.append(value)
      return .none
    }
  }
}

@Suite("EffectTask.run(sequence:) error handling", .serialized)
@MainActor
struct EffectTaskRunSequenceErrorTests {

  @Test("Cancellation thrown from sequence does not surface as didFailRun")
  func cancellationDoesNotSurfaceAsFailure() async {
    let probe = InstrumentationProbe()
    let store = Store(
      reducer: SequenceErrorFeature(),
      initialState: .init(),
      instrumentation: .init(
        didFailRun: { event in
          probe.record("fail:\(event.errorTypeName):\(event.errorDescription)")
        }
      )
    )

    store.send(.startThrowing(.cancellation))
    await waitUntil(timeout: .seconds(60), pollInterval: .milliseconds(10)) {
      store.values == [1]
    }

    // Allow the spawned Task to fully unwind so any erroneous didFailRun
    // emission would have landed by now.
    try? await Task.sleep(for: .milliseconds(50))
    #expect(probe.events.isEmpty)
    #expect(store.values == [1])
  }

  @Test("Custom error thrown from sequence is forwarded to didFailRun and stops the effect")
  func customErrorSurfacesAsFailure() async {
    let probe = InstrumentationProbe()
    let store = Store(
      reducer: SequenceErrorFeature(),
      initialState: .init(),
      instrumentation: .init(
        didFailRun: { event in
          probe.record("fail:\(event.errorTypeName):\(event.errorDescription)")
        }
      )
    )

    store.send(.startThrowing(.custom))
    await waitUntil(timeout: .seconds(60), pollInterval: .milliseconds(10)) {
      probe.events.contains(where: { $0.hasPrefix("fail:") })
    }

    let failureEvents = probe.events.filter { $0.hasPrefix("fail:") }
    #expect(failureEvents.count == 1)
    let event = try! #require(failureEvents.first)
    #expect(event.contains("SequenceTestError"))
    #expect(event.contains("boom"))
    #expect(store.values == [1])
  }

  @Test("transform overload narrows cancellation the same way")
  func transformCancellationDoesNotSurfaceAsFailure() async {
    let probe = InstrumentationProbe()
    let store = Store(
      reducer: SequenceErrorFeature(),
      initialState: .init(),
      instrumentation: .init(
        didFailRun: { event in
          probe.record("fail:\(event.errorTypeName):\(event.errorDescription)")
        }
      )
    )

    store.send(.startThrowingTransformed(.cancellation))
    await waitUntil(timeout: .seconds(60), pollInterval: .milliseconds(10)) {
      store.values == [2]
    }
    try? await Task.sleep(for: .milliseconds(50))

    #expect(probe.events.isEmpty)
    #expect(store.values == [2])
  }

  @Test("transform overload forwards custom errors to didFailRun")
  func transformCustomErrorSurfacesAsFailure() async {
    let probe = InstrumentationProbe()
    let store = Store(
      reducer: SequenceErrorFeature(),
      initialState: .init(),
      instrumentation: .init(
        didFailRun: { event in
          probe.record("fail:\(event.errorTypeName):\(event.errorDescription)")
        }
      )
    )

    store.send(.startThrowingTransformed(.custom))
    await waitUntil(timeout: .seconds(60), pollInterval: .milliseconds(10)) {
      probe.events.contains(where: { $0.hasPrefix("fail:") })
    }

    let failureEvents = probe.events.filter { $0.hasPrefix("fail:") }
    #expect(failureEvents.count == 1)
    let event = try! #require(failureEvents.first)
    #expect(event.contains("SequenceTestError"))
    #expect(event.contains("transform-boom"))
    #expect(store.values == [2])
  }
}
