// MARK: - EffectTaskRunSequenceErrorTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import Testing
import os

@testable import InnoFlowCore
@testable import InnoFlowTesting

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
    case emitThrowingStart
    case startThrowing(SequenceErrorMode)
    case startThrowingTransformed(SequenceErrorMode)
    case startDebouncedThrowing(SequenceErrorMode)
    case received(Int)
  }

  struct State: Equatable, Sendable, DefaultInitializable {
    var values: [Int] = []
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .emitThrowingStart:
      return .send(.startThrowing(.custom))

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

    case .startDebouncedThrowing(let mode):
      return EffectTask.run { _ in
        EmitOnceThenThrowSequence<Action>(
          element: .received(1),
          mode: mode,
          customError: SequenceTestError(message: "debounced-boom")
        )
      }
      .debounce("sequence-error", for: .seconds(1))

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
  func cancellationDoesNotSurfaceAsFailure() async throws {
    let probe = InstrumentationProbe()
    let finished = AsyncTestSignal()
    let store = Store(
      reducer: SequenceErrorFeature(),
      initialState: .init(),
      instrumentation: .init(
        didFinishRun: { _ in
          probe.record("finish")
          finished.signal()
        },
        didFailRun: { event in
          probe.record("fail:\(event.errorTypeName):\(event.errorDescription)")
        }
      )
    )

    store.send(.startThrowing(.cancellation))
    try #require(await finished.wait())
    #expect(probe.events == ["finish"])
    #expect(store.values == [1])
  }

  @Test("Custom error thrown from sequence is forwarded to didFailRun and stops the effect")
  func customErrorSurfacesAsFailure() async throws {
    let probe = InstrumentationProbe()
    let failed = AsyncTestSignal()
    let store = Store(
      reducer: SequenceErrorFeature(),
      initialState: .init(),
      instrumentation: .init(
        didFinishRun: { _ in
          probe.record("finish")
        },
        didFailRun: { event in
          probe.record("fail:\(event.errorTypeName):\(event.errorDescription)")
          failed.signal()
        }
      )
    )

    store.send(.startThrowing(.custom))
    try #require(await failed.wait())

    let failureEvents = probe.events.filter { $0.hasPrefix("fail:") }
    #expect(failureEvents.count == 1)
    let event = try #require(failureEvents.first)
    #expect(event.contains("SequenceTestError"))
    #expect(event.contains("boom"))
    #expect(store.values == [1])
  }

  @Test("transform overload narrows cancellation the same way")
  func transformCancellationDoesNotSurfaceAsFailure() async throws {
    let probe = InstrumentationProbe()
    let finished = AsyncTestSignal()
    let store = Store(
      reducer: SequenceErrorFeature(),
      initialState: .init(),
      instrumentation: .init(
        didFinishRun: { _ in
          probe.record("finish")
          finished.signal()
        },
        didFailRun: { event in
          probe.record("fail:\(event.errorTypeName):\(event.errorDescription)")
        }
      )
    )

    store.send(.startThrowingTransformed(.cancellation))
    try #require(await finished.wait())

    #expect(probe.events == ["finish"])
    #expect(store.values == [2])
  }

  @Test("transform overload forwards custom errors to didFailRun")
  func transformCustomErrorSurfacesAsFailure() async throws {
    let probe = InstrumentationProbe()
    let failed = AsyncTestSignal()
    let store = Store(
      reducer: SequenceErrorFeature(),
      initialState: .init(),
      instrumentation: .init(
        didFailRun: { event in
          probe.record("fail:\(event.errorTypeName):\(event.errorDescription)")
          failed.signal()
        }
      )
    )

    store.send(.startThrowingTransformed(.custom))
    try #require(await failed.wait())

    let failureEvents = probe.events.filter { $0.hasPrefix("fail:") }
    #expect(failureEvents.count == 1)
    let event = try #require(failureEvents.first)
    #expect(event.contains("SequenceTestError"))
    #expect(event.contains("transform-boom"))
    #expect(store.values == [2])
  }
}

@Suite("TestStore EffectTask.run(sequence:) error handling", .serialized)
@MainActor
struct TestStoreRunSequenceErrorTests {

  @Test("Custom sequence errors fail at the action that started the effect")
  func customErrorFailsAtOriginatingAction() async throws {
    let store = TestStore(reducer: SequenceErrorFeature())
    var failures: [(message: String, file: String, line: UInt)] = []
    store.assertionFailureReporter = { message, file, line in
      failures.append((message, String(describing: file), line))
    }

    await store.send(
      .startThrowing(.custom),
      file: "SequenceStart.swift",
      line: 123
    )
    await store.receive(
      .received(1),
      assert: { $0.values = [1] },
      file: "LaterReceive.swift",
      line: 456
    )
    await store.finish()

    #expect(failures.count == 1)
    let failure = try #require(failures.first)
    #expect(failure.message.contains("SequenceTestError"))
    #expect(failure.message.contains("boom"))
    #expect(failure.file == "SequenceStart.swift")
    #expect(failure.line == 123)
  }

  @Test("Transformed sequence errors use the same hard-failure contract")
  func transformedCustomErrorFailsOnce() async throws {
    let store = TestStore(reducer: SequenceErrorFeature())
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in
      failures.append(message)
    }

    await store.send(.startThrowingTransformed(.custom))
    await store.receive(.received(2)) {
      $0.values = [2]
    }
    await store.finish()

    #expect(failures.count == 1)
    #expect(failures.first?.contains("SequenceTestError") == true)
    #expect(failures.first?.contains("transform-boom") == true)
  }

  @Test("Sequence cancellation remains a successful TestStore completion")
  func cancellationDoesNotFail() async {
    let store = TestStore(reducer: SequenceErrorFeature())
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in
      failures.append(message)
    }

    await store.send(.startThrowing(.cancellation))
    await store.receive(.received(1)) {
      $0.values = [1]
    }
    await store.finish()

    #expect(failures.isEmpty)
  }

  @Test("TestStore reports only the first error from one run")
  func firstReportedErrorWins() async throws {
    let store = TestStore(reducer: DoubleReportFeature())
    var failures: [(message: String, file: String, line: UInt)] = []
    store.assertionFailureReporter = { message, file, line in
      failures.append((message, String(describing: file), line))
    }

    await store.send(
      .fireTwice,
      file: "FirstError.swift",
      line: 321
    )
    await store.receive(.done) {
      $0.done = true
    }
    await store.finish()

    #expect(failures.count == 1)
    let failure = try #require(failures.first)
    #expect(failure.message.contains("first"))
    #expect(failure.message.contains("second") == false)
    #expect(failure.file == "FirstError.swift")
    #expect(failure.line == 321)
  }

  @Test("Runtime sequence errors fail even when exhaustivity is off")
  func runtimeErrorIgnoresExhaustivityPolicy() async {
    let store = TestStore(reducer: SequenceErrorFeature())
    store.exhaustivity = .off
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in
      failures.append(message)
    }

    await store.send(.startThrowing(.custom))
    await store.receive(.received(1)) {
      $0.values = [1]
    }
    await store.finish()

    #expect(failures.count == 1)
    #expect(failures.first?.contains("boom") == true)
  }

  @Test("Delayed sequence errors preserve the action origin across later interactions")
  func delayedErrorPreservesOrigin() async throws {
    let clock = ManualTestClock()
    let store = TestStore(
      reducer: SequenceErrorFeature(),
      clock: clock
    )
    var failures: [(message: String, file: String, line: UInt)] = []
    store.assertionFailureReporter = { message, file, line in
      failures.append((message, String(describing: file), line))
    }

    await store.send(
      .startDebouncedThrowing(.custom),
      file: "DebouncedStart.swift",
      line: 654
    )
    try #require(
      await waitUntilAsync {
        await clock.sleeperCount == 1
      }
    )
    await store.send(
      .received(9),
      assert: { $0.values = [9] },
      file: "LaterInteraction.swift",
      line: 987
    )

    await clock.advance(by: .seconds(1))
    await store.receive(.received(1)) {
      $0.values = [9, 1]
    }
    await store.finish()

    #expect(failures.count == 1)
    let failure = try #require(failures.first)
    #expect(failure.message.contains("debounced-boom"))
    #expect(failure.file == "DebouncedStart.swift")
    #expect(failure.line == 654)
  }

  @Test("Effects created by receive report at the receive assertion")
  func receivedActionEffectUsesReceiveOrigin() async throws {
    let store = TestStore(reducer: SequenceErrorFeature())
    var failures: [(message: String, file: String, line: UInt)] = []
    store.assertionFailureReporter = { message, file, line in
      failures.append((message, String(describing: file), line))
    }

    await store.send(
      .emitThrowingStart,
      file: "InitialSend.swift",
      line: 111
    )
    await store.receive(
      .startThrowing(.custom),
      file: "EffectStartingReceive.swift",
      line: 222
    )
    await store.receive(.received(1)) {
      $0.values = [1]
    }
    await store.finish()

    #expect(failures.count == 1)
    let failure = try #require(failures.first)
    #expect(failure.message.contains("boom"))
    #expect(failure.file == "EffectStartingReceive.swift")
    #expect(failure.line == 222)
  }

  @Test("A cancelled run drops a domain error reported after cancellation")
  func cancelledRunDropsLateError() async throws {
    let started = AsyncTestSignal()
    let release = RunStartGate()
    let completed = AsyncTestSignal()
    let store = TestStore(
      reducer: LateReportAfterCancellationFeature(
        started: started,
        release: release,
        completed: completed
      )
    )
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in
      failures.append(message)
    }

    await store.send(.start)
    try #require(await started.wait())
    await store.cancelAllEffects()
    await release.open()
    try #require(await completed.wait())
    await store.finish()

    #expect(failures.isEmpty)
  }
}

private struct DoubleReportFeature: Reducer {
  enum Action: Equatable, Sendable {
    case fireTwice
    case done
  }

  struct State: Equatable, Sendable, DefaultInitializable {
    var done = false
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .fireTwice:
      return .run { send, context in
        await context.reportError(SequenceTestError(message: "first"))
        await context.reportError(SequenceTestError(message: "second"))
        await send(.done)
      }
    case .done:
      state.done = true
      return .none
    }
  }
}

private struct LateReportAfterCancellationFeature: Reducer {
  enum Action: Equatable, Sendable {
    case start
  }

  struct State: Equatable, Sendable, DefaultInitializable {}

  let started: AsyncTestSignal
  let release: RunStartGate
  let completed: AsyncTestSignal

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    .run { _, context in
      started.signal()
      await release.wait()
      await context.reportError(SequenceTestError(message: "cancelled-boom"))
      completed.signal()
    }
  }
}

@Suite("EffectContext.reportError first-error-wins contract", .serialized)
@MainActor
struct ReportErrorFirstWinsTests {

  @Test("Multiple reportError calls within a single run emit a single didFailRun event")
  func firstErrorWinsAcrossMultipleReports() async throws {
    let probe = InstrumentationProbe()
    let emittedDone = AsyncTestSignal()
    let store = Store(
      reducer: DoubleReportFeature(),
      initialState: .init(),
      instrumentation: .init(
        didStartRun: { _ in probe.record("start") },
        didFinishRun: { _ in probe.record("finish") },
        didFailRun: { event in probe.record("fail:\(event.errorDescription)") },
        didEmitAction: { event in
          if event.action == .done {
            emittedDone.signal()
          }
        }
      )
    )

    store.send(.fireTwice)
    try #require(await emittedDone.wait())

    let starts = probe.events.filter { $0 == "start" }
    let finishes = probe.events.filter { $0 == "finish" }
    let failures = probe.events.filter { $0.hasPrefix("fail:") }
    #expect(starts.count == 1)
    #expect(failures.count == 1)
    #expect(finishes.isEmpty)
    #expect(failures.first?.contains("first") == true)
    #expect(failures.first?.contains("second") == false)
  }
}
