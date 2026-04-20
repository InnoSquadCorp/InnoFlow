// MARK: - EffectTimingRecorderTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.
//
// Unit tests for `EffectTimingRecorder` — the test-only JSONL recorder that
// captures `StoreInstrumentation` events so release-mode scheduling
// regressions can be detected by a baseline comparison.

import Foundation
import InnoFlow
import InnoFlowTesting
import Testing

// MARK: - Fixture

@InnoFlow
struct EffectTimingRecorderProbeFeature {
  struct State: Equatable, Sendable, DefaultInitializable {
    var count = 0
  }

  enum Action: Equatable, Sendable {
    case start
    case _tick
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .start:
        return .run { send, _ in
          await send(._tick)
        }
        .cancellable("probe-start", cancelInFlight: true)
      case ._tick:
        state.count &+= 1
        return .none
      }
    }
  }
}

@Suite("EffectTimingRecorder")
struct EffectTimingRecorderTests {

  typealias ProbeFeature = EffectTimingRecorderProbeFeature

  // MARK: - Tests

  @Test("Recorder captures run lifecycle events in order")
  @MainActor
  func recorderCapturesRunLifecycle() async {
    let recorder = EffectTimingRecorder()
    let store = Store(
      reducer: ProbeFeature(),
      instrumentation: recorder.instrumentation()
    )

    store.send(.start)
    // Poll the recorder's observed phases instead of relying on a fixed
    // yield count; release-mode scheduling can delay when the probe run
    // fully drains.
    guard await waitForPhases(.runStarted, .runFinished, in: recorder) else {
      return
    }

    let entries = await recorder.entries()
    let phases = entries.map(\.phase)
    #expect(phases.contains(.runStarted))
    #expect(phases.contains(.runFinished))

    // Timestamps must be monotonically non-decreasing.
    let stamps = entries.map(\.timestampNanos)
    #expect(stamps == stamps.sorted())
  }

  @Test("Recorder dumps JSONL that round-trips through JSONDecoder")
  @MainActor
  func recorderDumpsJSONLRoundTrip() async throws {
    let recorder = EffectTimingRecorder()
    let store = Store(
      reducer: ProbeFeature(),
      instrumentation: recorder.instrumentation()
    )

    store.send(.start)
    guard await waitForPhases(.runStarted, .runFinished, in: recorder) else {
      return
    }

    let url = FileManager.default
      .temporaryDirectory
      .appendingPathComponent("effect-timing-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }

    try await recorder.dumpJSONL(to: url)

    let data = try Data(contentsOf: url)
    let lines = data.split(separator: 0x0A)
    #expect(!lines.isEmpty)

    let decoder = JSONDecoder()
    var decoded: [EffectTimingRecorder.Entry] = []
    for line in lines where !line.isEmpty {
      decoded.append(try decoder.decode(EffectTimingRecorder.Entry.self, from: Data(line)))
    }

    let original = await recorder.entries()
    #expect(decoded == original)
  }

  @Test("Recorder combines with a user-supplied instrumentation sink")
  @MainActor
  func recorderCombinesWithExistingSink() async {
    let recorder = EffectTimingRecorder()
    let userObservedActions = RunStartedCounter()
    let userSink = StoreInstrumentation<ProbeFeature.Action>.sink { event in
      if case .runStarted = event {
        Task { await userObservedActions.increment() }
      }
    }

    let combined = StoreInstrumentation.combined(
      userSink,
      recorder.instrumentation() as StoreInstrumentation<ProbeFeature.Action>
    )

    let store = Store(
      reducer: ProbeFeature(),
      instrumentation: combined
    )

    store.send(.start)
    guard await waitForPhases(.runStarted, in: recorder) else {
      return
    }
    guard await waitForRunStartedCount(atLeast: 1, in: userObservedActions) else {
      return
    }

    let observed = await userObservedActions.value
    #expect(observed >= 1)
    let entries = await recorder.entries()
    #expect(entries.contains(where: { $0.phase == .runStarted }))
  }

  @Test("Recorder captures effectsCancelled when cancelEffects is awaited")
  @MainActor
  func recorderCapturesCancellation() async {
    let recorder = EffectTimingRecorder()
    let store = Store(
      reducer: ProbeFeature(),
      instrumentation: recorder.instrumentation()
    )

    store.send(.start)
    await store.cancelEffects(identifiedBy: "probe-start")
    guard await waitForPhases(.effectsCancelled, in: recorder) else {
      return
    }

    let entries = await recorder.entries()
    let cancelEntry = entries.first(where: { $0.phase == .effectsCancelled })
    #expect(cancelEntry != nil)
    #expect(cancelEntry?.effectID == "probe-start")
  }

  // MARK: - Polling helper

  /// Yields until the recorder has observed every phase in `phases`, up to a
  /// generous wall-clock bound. Release-mode scheduling can delay the final
  /// `runFinished` Task hop more than a fixed yield count would allow.
  private func waitForPhases(
    _ phases: EffectTimingRecorder.Phase...,
    in recorder: EffectTimingRecorder,
    timeout: Duration = .seconds(5)
  ) async -> Bool {
    let expected = Set(phases)
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    var lastCaptured: Set<EffectTimingRecorder.Phase> = []
    while clock.now < deadline {
      let entries = await recorder.entries()
      let captured = Set(entries.map(\.phase))
      lastCaptured = captured
      if expected.isSubset(of: lastCaptured) {
        return true
      }
      await Task.yield()
    }
    let expectedPhases = expected.map(\.rawValue).sorted().joined(separator: ", ")
    let capturedPhases = lastCaptured.map(\.rawValue).sorted().joined(separator: ", ")
    Issue.record(
      "Timed out waiting for EffectTimingRecorder phases [\(expectedPhases)]; captured [\(capturedPhases)]"
    )
    return false
  }

  private func waitForRunStartedCount(
    atLeast expectedCount: Int,
    in counter: RunStartedCounter,
    timeout: Duration = .seconds(5)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    var observedCount = 0
    while clock.now < deadline {
      observedCount = await counter.value
      if observedCount >= expectedCount {
        return true
      }
      await Task.yield()
    }
    Issue.record(
      "Timed out waiting for run-start counter >= \(expectedCount); observed \(observedCount)"
    )
    return false
  }
}

// MARK: - Test helpers

private actor RunStartedCounter {
  private(set) var value: Int = 0

  func increment() {
    value &+= 1
  }
}
