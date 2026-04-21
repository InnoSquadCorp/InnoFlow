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

// These tests share a fixed cancellation ID (`"probe-start"`) so the
// cancellation-specific probe would otherwise be able to interfere with the
// lifecycle/round-trip probes when Swift Testing runs the suite concurrently.
@Suite("EffectTimingRecorder", .serialized)
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
    guard
      await waitForCompletedProbeRun(
        in: store,
        recorder: recorder,
        expectedRunCount: 1,
        expectedCount: 1
      )
    else {
      return
    }

    #expect(store.count == 1)
    let entries = await recorder.entries()
    let phases = entries.map(\.phase)
    let startedIndex = phases.firstIndex(of: .runStarted)
    let finishedIndex = phases.firstIndex(of: .runFinished)
    #expect(startedIndex != nil)
    #expect(finishedIndex != nil)
    if let startedIndex, let finishedIndex {
      #expect(startedIndex < finishedIndex)
    }

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
    guard
      await waitForCompletedProbeRun(
        in: store,
        recorder: recorder,
        expectedRunCount: 1,
        expectedCount: 1
      )
    else {
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
    guard
      await waitForCompletedProbeRun(
        in: store,
        recorder: recorder,
        expectedRunCount: 1,
        expectedCount: 1
      )
    else {
      return
    }
    guard await waitForRunStartedCount(atLeast: 1, in: userObservedActions) else {
      return
    }

    #expect(store.count == 1)
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
    guard await waitForRecordedCancellation(in: store, recorder: recorder) else {
      return
    }

    let entries = await recorder.entries()
    let cancelEntry = entries.first(where: { $0.phase == .effectsCancelled })
    #expect(cancelEntry != nil)
    #expect(cancelEntry?.effectID == "probe-start")
  }

  // MARK: - Polling helper

  /// Runtime metrics are the primary synchronization surface; recorder state is
  /// only used as a secondary confirmation that the timeline snapshot is ready
  /// to assert against.
  @MainActor
  private func waitForCompletedProbeRun(
    in store: Store<ProbeFeature>,
    recorder: EffectTimingRecorder,
    expectedRunCount: Int,
    expectedCount: Int,
    timeout: Duration = .seconds(15)
  ) async -> Bool {
    let expectedRuns = UInt64(expectedRunCount)
    return await waitUntil(
      timeout: timeout,
      description: "probe run \(expectedRunCount) to finish and record",
      condition: {
        let metrics = await store.effectRuntimeMetrics
        let entries = await recorder.entries()
        return metrics.preparedRuns >= expectedRuns
          && metrics.finishedRuns >= expectedRuns
          && matchedRunPairCount(in: entries) >= expectedRunCount
          && store.count >= expectedCount
      },
      status: {
        let entries = await recorder.entries()
        return await recorderProbeStatus(
          for: store,
          matchedRunPairs: matchedRunPairCount(in: entries)
        )
      }
    )
  }

  @MainActor
  private func waitForRecordedCancellation(
    in store: Store<ProbeFeature>,
    recorder: EffectTimingRecorder,
    expectedCancellations: UInt64 = 1,
    timeout: Duration = .seconds(15)
  ) async -> Bool {
    await waitUntil(
      timeout: timeout,
      description: "probe cancellation \(expectedCancellations) to record",
      condition: {
        let metrics = await store.effectRuntimeMetrics
        let entries = await recorder.entries()
        return metrics.cancellations >= expectedCancellations
          && entries.contains(where: { $0.phase == .effectsCancelled })
      },
      status: {
        let entries = await recorder.entries()
        return await recorderProbeStatus(
          for: store,
          matchedRunPairs: matchedRunPairCount(in: entries)
        )
      }
    )
  }

  @MainActor
  private func waitUntil(
    timeout: Duration = .seconds(15),
    pollInterval: Duration = .milliseconds(20),
    description: String,
    condition: @escaping @MainActor () async -> Bool,
    status: @escaping @MainActor () async -> String
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
      if await condition() {
        return true
      }
      try? await Task.sleep(for: pollInterval)
    }
    let latestStatus = await status()
    Issue.record("Timed out waiting for \(description); \(latestStatus)")
    return false
  }

  @MainActor
  private func recorderProbeStatus(
    for store: Store<ProbeFeature>,
    matchedRunPairs: Int
  ) async -> String {
    let metrics = await store.effectRuntimeMetrics
    return
      "prepared=\(metrics.preparedRuns) attached=\(metrics.attachedRuns) finished=\(metrics.finishedRuns) emissions=\(metrics.emissionDecisions) cancellations=\(metrics.cancellations) matchedRunPairs=\(matchedRunPairs) count=\(store.count)"
  }

  private func matchedRunPairCount(in entries: [EffectTimingRecorder.Entry]) -> Int {
    var phasesBySequence: [UInt64: Set<EffectTimingRecorder.Phase>] = [:]
    for entry in entries where entry.phase == .runStarted || entry.phase == .runFinished {
      phasesBySequence[entry.sequence, default: []].insert(entry.phase)
    }
    return phasesBySequence.values.reduce(into: 0) { count, phases in
      if phases.contains(.runStarted) && phases.contains(.runFinished) {
        count += 1
      }
    }
  }

  @MainActor
  private func waitForRunStartedCount(
    atLeast expectedCount: Int,
    in counter: RunStartedCounter,
    timeout: Duration = .seconds(15)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    var observedCount = 0
    while clock.now < deadline {
      observedCount = await counter.value
      if observedCount >= expectedCount {
        return true
      }
      try? await Task.sleep(for: .milliseconds(20))
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
