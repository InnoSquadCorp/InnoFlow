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
// `scripts/principle-gates.sh`, which runs the test suite with
// `INNOFLOW_CHECK_EFFECT_BASELINE=1` set so CI fails on genuine regressions
// (for example the 2026-04 class of release-mode scheduling failures) but
// local runs stay quiet.

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
    for _ in 0..<10 {
      store.send(.start)
      for _ in 0..<50 {
        await Task.yield()
        if store.didTick { break }
      }
      store.send(.reset)
      for _ in 0..<20 { await Task.yield() }
    }
    for _ in 0..<50 { await Task.yield() }

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

    // Tolerance is intentionally loose: parallel test-suite scheduling under
    // `swift test -c release` introduces scheduler contention that can
    // multiply per-run latency by a large factor versus a solo run. The gate
    // exists to catch catastrophic regressions (the 2026-04 class of release
    // yield-count failures), not to enforce a specific absolute performance
    // target — a 10x baseline inflation still trips the gate while normal
    // CI variance passes cleanly.
    let process = Process()
    process.executableURL = scriptURL
    process.arguments = [
      "--baseline", baselineURL.path,
      "--current", currentURL.path,
      "--metric", "p95",
      "--tolerance", "9.0",
    ]

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    let stdoutText = String(
      data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderrText = String(
      data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

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
