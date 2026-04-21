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
// scheduling failures) but local runs stay quiet.

import Foundation
import InnoFlow
import InnoFlowTesting
import Testing

@Suite("EffectTimingBaselineGate")
struct EffectTimingBaselineGate {

  @Test("Effect timing p95 stays within tolerance of the committed baseline")
  @MainActor
  func currentTimingsStayWithinBaselineTolerance() async throws {
    guard ProcessInfo.processInfo.environment["INNOFLOW_CHECK_EFFECT_BASELINE"] == "1" else {
      return
    }

    let recorder = EffectTimingRecorder()
    let store = Store(
      reducer: EffectTimingBaselineProbeFeature(),
      instrumentation: recorder.instrumentation()
    )

    // Workload: 10 `.start` cycles with a short per-cycle drain. Each cycle
    // generates a runStarted/runFinished pair so the baseline distribution
    // has the same shape as the committed fixture.
    for cycle in 1...10 {
      store.send(.start)
      guard await waitForRecordedProbeCycle(cycle, in: store, recorder: recorder) else { return }
      #expect(store.didTick)
      store.send(.reset)
      #expect(!store.didTick)
    }

    let currentEntries = await recorder.entries()
    #expect(matchedRunPairCount(in: currentEntries) == 10)

    let currentURL = FileManager.default
      .temporaryDirectory
      .appendingPathComponent("innoflow-effect-timings-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: currentURL) }

    try await recorder.dumpJSONL(to: currentURL)

    let baselineURL = try repositoryFileURL(
      relativePath: "Tests/InnoFlowTests/Fixtures/EffectTimings.baseline.jsonl"
    )
    let scriptURL = try repositoryFileURL(
      relativePath: "scripts/compare-effect-timings.sh"
    )

    // Tolerance is intentionally loose: even in the isolated release-only
    // invocation from `principle-gates.sh`, machine-local drift can still
    // move these timings materially. The gate exists to catch catastrophic
    // regressions (the 2026-04 class of release yield-count failures), not to
    // enforce a specific absolute performance target. The script contract
    // expresses tolerance as a 0...1 relative increase, so `1.0` keeps the
    // gate loose while still failing on multi-x baseline inflation.
    let process = Process()
    process.executableURL = scriptURL
    process.arguments = [
      "--baseline", baselineURL.path,
      "--current", currentURL.path,
      "--metric", "p95",
      "--tolerance", "1.0",
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

  // MARK: - Helpers

  /// Resolves `relativePath` against the repository root, inferred from
  /// `#filePath`. Climbs the directory tree looking for `Package.swift` so
  /// the helper works under both `swift test` and `xcodebuild test`.
  private func repositoryFileURL(
    relativePath: String,
    file: StaticString = #filePath
  ) throws -> URL {
    var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
    for _ in 0..<10 {
      let candidate = directory.appendingPathComponent("Package.swift")
      if FileManager.default.fileExists(atPath: candidate.path) {
        return directory.appendingPathComponent(relativePath)
      }
      directory.deleteLastPathComponent()
    }
    struct RepositoryRootNotFound: Error {}
    throw RepositoryRootNotFound()
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
  private func waitForRecordedProbeCycle(
    _ cycle: Int,
    in store: Store<EffectTimingBaselineProbeFeature>,
    recorder: EffectTimingRecorder,
    timeout: Duration = .seconds(15)
  ) async -> Bool {
    let expectedRuns = UInt64(cycle)
    return await waitUntil(
      timeout: timeout,
      description: "timing probe cycle \(cycle) to finish and record",
      condition: {
        let metrics = await store.effectRuntimeMetrics
        let entries = await recorder.entries()
        return metrics.preparedRuns >= expectedRuns
          && metrics.finishedRuns >= expectedRuns
          && matchedRunPairCount(in: entries) >= cycle
          && store.didTick
      },
      status: {
        let entries = await recorder.entries()
        return await baselineProbeStatus(
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
  private func baselineProbeStatus(
    for store: Store<EffectTimingBaselineProbeFeature>,
    matchedRunPairs: Int
  ) async -> String {
    let metrics = await store.effectRuntimeMetrics
    return
      "prepared=\(metrics.preparedRuns) attached=\(metrics.attachedRuns) finished=\(metrics.finishedRuns) emissions=\(metrics.emissionDecisions) cancellations=\(metrics.cancellations) matchedRunPairs=\(matchedRunPairs) didTick=\(store.didTick)"
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
