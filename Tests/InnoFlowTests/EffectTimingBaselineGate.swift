// MARK: - EffectTimingBaselineGate.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.
//
// Regression gate that compares a fresh `EffectTimingRecorder` run against
// the committed baseline at
// `Tests/InnoFlowTests/Fixtures/EffectTimings.baseline.jsonl` via the
// `scripts/compare-effect-timings.sh` companion script.
//
// The gate is off by default because Swift Testing runs debug and release
// suites on a variety of developer machines, where absolute run durations
// can drift by an order of magnitude. It is opted in from
// `scripts/principle-gates.sh`, which runs this suite in a dedicated release
// invocation with `INNOFLOW_CHECK_EFFECT_BASELINE=1` set so CI fails on
// genuine regressions (for example the 2026-04 class of release-mode
// scheduling failures) but local runs stay quiet. Setting
// `INNOFLOW_WRITE_EFFECT_BASELINE=<path>` switches the suite into export mode
// so maintainers can regenerate the committed JSONL fixture deliberately.

import Foundation
import InnoFlow
import InnoFlowTesting
import Testing

@Suite("EffectTimingBaselineGate")
struct EffectTimingBaselineGate {
  private struct BaselineSnapshot: Sendable {
    let preparedRuns: UInt64
    let attachedRuns: UInt64
    let finishedRuns: UInt64
    let emissionDecisions: UInt64
    let cancellations: UInt64
    let didTick: Bool
  }

  @Test("Effect timing mean stays within tolerance of the committed baseline")
  @MainActor
  func currentTimingsStayWithinBaselineTolerance() async throws {
    let environment = ProcessInfo.processInfo.environment
    let shouldCompare = environment["INNOFLOW_CHECK_EFFECT_BASELINE"] == "1"
    let exportPath = environment["INNOFLOW_WRITE_EFFECT_BASELINE"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard shouldCompare || !(exportPath ?? "").isEmpty else {
      return
    }

    let recorder = EffectTimingRecorder()
    let witness = EffectInstrumentationWitness()
    let store = Store(
      reducer: EffectTimingBaselineProbeFeature(),
      instrumentation: .combined(
        recorder.instrumentation() as StoreInstrumentation<EffectTimingBaselineProbeFeature.Action>,
        witness.instrumentation()
      )
    )

    // Workload: 10 `.start` cycles with a short per-cycle drain. Each cycle
    // generates a runStarted/runFinished pair so the baseline distribution
    // has the same shape as the committed fixture.
    for cycle in 1...EffectTimingBaselineContract.runCount {
      store.send(.start)
      guard await waitForRecordedProbeCycle(cycle, in: store, recorder: recorder, witness: witness)
      else { return }
      #expect(store.didTick)
      store.send(.reset)
      #expect(!store.didTick)
    }

    let currentEntries = await recorder.entries()
    #expect(matchedRunPairCount(in: currentEntries) == EffectTimingBaselineContract.runCount)

    if let exportPath, !exportPath.isEmpty {
      let exportURL = try effectTimingRepositoryRelativeOrAbsoluteFileURL(path: exportPath)
      try FileManager.default.createDirectory(
        at: exportURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: nil
      )
      try await recorder.dumpJSONL(to: exportURL)
      print("[EffectTimingBaselineGate] wrote baseline fixture to \(exportURL.path)")
      return
    }

    let currentURL = FileManager.default
      .temporaryDirectory
      .appendingPathComponent("innoflow-effect-timings-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: currentURL) }

    try await recorder.dumpJSONL(to: currentURL)

    let baselineURL = try effectTimingRepositoryFileURL(
      relativePath: EffectTimingBaselineContract.baselineFixtureRelativePath
    )
    let scriptURL = try effectTimingRepositoryFileURL(
      relativePath: "scripts/compare-effect-timings.sh"
    )

    // Tolerance is intentionally loose: even in the isolated release-only
    // invocation from `principle-gates.sh`, machine-local drift can still
    // move these timings materially. The gate exists to catch catastrophic
    // regressions (the 2026-04 class of release yield-count failures), not to
    // enforce a specific absolute performance target.
    //
    // The standalone script still supports `p95`, and its direct contract
    // tests cover the percentile ceiling behavior. This release-only gate uses
    // `mean` instead because the current 10-run workload makes `p95` collapse
    // to the single slowest run, which proved too sensitive to one-off GitHub
    // Actions runner jitter.
    let process = Process()
    process.executableURL = scriptURL
    process.arguments = [
      "--baseline", baselineURL.path,
      "--current", currentURL.path,
      "--metric", EffectTimingBaselineContract.gateMetric,
      "--tolerance", EffectTimingBaselineContract.gateTolerance,
    ]

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    let stdoutText =
      String(
        data: stdout.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
      ) ?? ""
    let stderrText =
      String(
        data: stderr.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
      ) ?? ""

    if process.terminationStatus != 0 {
      Issue.record(
        """
        Effect timing baseline regression detected.
        stdout: \(stdoutText)
        stderr: \(stderrText)
        """
      )
    }
  }

  private func waitForRecordedProbeCycle(
    _ cycle: Int,
    in store: Store<EffectTimingBaselineProbeFeature>,
    recorder: EffectTimingRecorder,
    witness: EffectInstrumentationWitness,
    timeout: Duration = .seconds(15)
  ) async -> Bool {
    let expectedRuns = UInt64(cycle)
    return await waitForEffectTimingCondition(
      timeout: timeout,
      description: "timing probe cycle \(cycle) to finish and record",
      condition: {
        let snapshot = await baselineSnapshot(for: store)
        let witnessSnapshot = witness.snapshot()
        return snapshot.preparedRuns >= expectedRuns
          && snapshot.finishedRuns >= expectedRuns
          && witnessSnapshot.matchedRunPairs >= cycle
          && snapshot.didTick
      },
      status: {
        let entries = await recorder.entries()
        let witnessSnapshot = witness.snapshot()
        return await baselineProbeStatus(
          for: store,
          witnessSnapshot: witnessSnapshot,
          recordedRunPairs: matchedRunPairCount(in: entries)
        )
      }
    )
  }

  @MainActor
  private func baselineSnapshot(for store: Store<EffectTimingBaselineProbeFeature>) async
    -> BaselineSnapshot
  {
    let metrics = await store.effectRuntimeMetrics
    return .init(
      preparedRuns: metrics.preparedRuns,
      attachedRuns: metrics.attachedRuns,
      finishedRuns: metrics.finishedRuns,
      emissionDecisions: metrics.emissionDecisions,
      cancellations: metrics.cancellations,
      didTick: store.didTick
    )
  }

  @MainActor
  private func baselineProbeStatus(
    for store: Store<EffectTimingBaselineProbeFeature>,
    witnessSnapshot: EffectInstrumentationWitnessSnapshot,
    recordedRunPairs: Int
  ) async -> String {
    let snapshot = await baselineSnapshot(for: store)
    return
      "prepared=\(snapshot.preparedRuns) attached=\(snapshot.attachedRuns) finished=\(snapshot.finishedRuns) emissions=\(snapshot.emissionDecisions) cancellations=\(snapshot.cancellations) witnessStarts=\(witnessSnapshot.runStartedCount) witnessFinishes=\(witnessSnapshot.runFinishedCount) witnessCancellations=\(witnessSnapshot.cancellationCount) witnessRunPairs=\(witnessSnapshot.matchedRunPairs) recorderRunPairs=\(recordedRunPairs) didTick=\(snapshot.didTick)"
  }
}

// MARK: - Probe reducer

@InnoFlow
struct EffectTimingBaselineProbeFeature {
  struct State: Equatable, Sendable, DefaultInitializable {
    var didTick = false
  }

  enum Action: Equatable, Sendable {
    case start
    case reset
    case _tick
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .start:
        state.didTick = false
        return .run { send, _ in
          await send(._tick)
        }
        .cancellable("timing-probe", cancelInFlight: true)
      case .reset:
        state.didTick = false
        return .none
      case ._tick:
        state.didTick = true
        return .none
      }
    }
  }
}
