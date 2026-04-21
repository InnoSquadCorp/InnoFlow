// MARK: - EffectTimingComparisonScriptTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.
//
// Direct contract tests for `scripts/compare-effect-timings.sh`. These use
// synthetic JSONL fixtures so incomplete captures and timing regressions are
// asserted without depending on recorder scheduling.

import Foundation
import Testing

@Suite("EffectTiming comparison script")
struct EffectTimingComparisonScriptTests {

  @Test("Comparison script passes when current timings stay within tolerance")
  func comparisonScriptPassesWithinTolerance() throws {
    let result = try runComparisonScript(
      baselineEntries: matchedRunEntries(durations: [100, 110, 120]),
      currentEntries: matchedRunEntries(durations: [105, 115, 120]),
      tolerance: "0.20"
    )

    #expect(result.terminationStatus == 0)
    #expect(result.stdout.contains("PASS"))
    #expect(result.stdout.contains("baselineRuns=3"))
    #expect(result.stdout.contains("currentRuns=3"))
  }

  @Test("Comparison script fails when current timings regress past tolerance")
  func comparisonScriptFailsForRegression() throws {
    let result = try runComparisonScript(
      baselineEntries: matchedRunEntries(durations: [100, 110, 120]),
      currentEntries: matchedRunEntries(durations: [200, 210, 220]),
      tolerance: "0.20"
    )

    #expect(result.terminationStatus == 1)
    #expect(result.stderr.contains("FAIL"))
    #expect(result.stderr.contains("\"baselineRuns\": \"3\""))
    #expect(result.stderr.contains("\"currentRuns\": \"3\""))
  }

  @Test("Comparison script fails for an empty current capture")
  func comparisonScriptFailsForEmptyCurrentCapture() throws {
    let result = try runComparisonScript(
      baselineEntries: matchedRunEntries(durations: [100, 110, 120]),
      currentEntries: []
    )

    #expect(result.terminationStatus == 1)
    #expect(
      result.stderr.contains(
        "current capture has no matched runs — incomplete capture or missing runFinished events")
    )
  }

  @Test("Comparison script fails for a start-only current capture")
  func comparisonScriptFailsForStartOnlyCurrentCapture() throws {
    let result = try runComparisonScript(
      baselineEntries: matchedRunEntries(durations: [100, 110, 120]),
      currentEntries: startOnlyRunEntry(sequence: 1, timestampNanos: 1_000_000)
    )

    #expect(result.terminationStatus == 1)
    #expect(
      result.stderr.contains(
        "current capture has no matched runs — incomplete capture or missing runFinished events")
    )
  }

  @Test("Comparison script rejects tolerance values outside 0...1")
  func comparisonScriptRejectsOutOfRangeTolerance() throws {
    let result = try runComparisonScript(
      baselineEntries: matchedRunEntries(durations: [100, 110, 120]),
      currentEntries: matchedRunEntries(durations: [105, 115, 120]),
      tolerance: "1.5"
    )

    #expect(result.terminationStatus == 1)
    #expect(result.stderr.contains("--tolerance must be within 0..1"))
  }

  @Test("Comparison script p95 uses the ceiling index for 10-sample fixtures")
  func comparisonScriptP95UsesCeilingIndex() throws {
    let result = try runComparisonScript(
      baselineEntries: matchedRunEntries(
        durations: [100, 100, 100, 100, 100, 100, 100, 100, 100, 100]
      ),
      currentEntries: matchedRunEntries(
        durations: [100, 100, 100, 100, 100, 100, 100, 100, 100, 1_000]
      ),
      tolerance: "1.0"
    )

    #expect(result.terminationStatus == 1)
    #expect(result.stderr.contains("FAIL"))
    #expect(result.stderr.contains("\"baselineRuns\": \"10\""))
    #expect(result.stderr.contains("\"currentRuns\": \"10\""))
  }

  @Test("Comparison script supports mean metric comparisons")
  func comparisonScriptSupportsMeanMetric() throws {
    let result = try runComparisonScript(
      baselineEntries: matchedRunEntries(durations: [100, 100, 100]),
      currentEntries: matchedRunEntries(durations: [150, 150, 150]),
      metric: "mean",
      tolerance: "0.60"
    )

    #expect(result.terminationStatus == 0)
    #expect(result.stdout.contains("metric=mean"))
    #expect(result.stdout.contains("PASS"))
  }

  // MARK: - Helpers

  private func runComparisonScript(
    baselineEntries: [[String: Any]],
    currentEntries: [[String: Any]],
    metric: String = "p95",
    tolerance: String = "0.10"
  ) throws -> ScriptResult {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("effect-timing-script-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let baselineURL = temporaryDirectory.appendingPathComponent("baseline.jsonl")
    let currentURL = temporaryDirectory.appendingPathComponent("current.jsonl")
    try writeJSONL(entries: baselineEntries, to: baselineURL)
    try writeJSONL(entries: currentEntries, to: currentURL)

    let process = Process()
    process.executableURL = try repositoryFileURL(
      relativePath: "scripts/compare-effect-timings.sh"
    )
    process.arguments = [
      "--baseline", baselineURL.path,
      "--current", currentURL.path,
      "--metric", metric,
      "--tolerance", tolerance,
    ]

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    return ScriptResult(
      terminationStatus: process.terminationStatus,
      stdout: String(
        data: stdout.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
      ) ?? "",
      stderr: String(
        data: stderr.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
      ) ?? ""
    )
  }

  private func writeJSONL(entries: [[String: Any]], to url: URL) throws {
    var payload = Data()
    for entry in entries {
      payload.append(try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]))
      payload.append(0x0A)
    }
    try payload.write(to: url, options: .atomic)
  }

  private func matchedRunEntries(durations: [UInt64]) -> [[String: Any]] {
    durations.enumerated().flatMap { index, duration in
      let sequence = UInt64(index + 1)
      let start = sequence * 1_000_000
      let finish = start + duration
      return [
        entry(
          phase: "runStarted",
          sequence: sequence,
          timestampNanos: start
        ),
        entry(
          phase: "runFinished",
          sequence: sequence,
          timestampNanos: finish
        ),
      ]
    }
  }

  private func startOnlyRunEntry(sequence: UInt64, timestampNanos: UInt64) -> [[String: Any]] {
    [entry(phase: "runStarted", sequence: sequence, timestampNanos: timestampNanos)]
  }

  private func entry(
    phase: String,
    sequence: UInt64,
    timestampNanos: UInt64
  ) -> [String: Any] {
    [
      "actionLabel": NSNull(),
      "effectID": NSNull(),
      "phase": phase,
      "sequence": sequence,
      "timestampNanos": timestampNanos,
    ]
  }

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

private struct ScriptResult {
  let terminationStatus: Int32
  let stdout: String
  let stderr: String
}
