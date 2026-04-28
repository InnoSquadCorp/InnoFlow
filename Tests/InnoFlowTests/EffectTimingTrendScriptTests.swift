// MARK: - EffectTimingTrendScriptTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import InnoFlow
import InnoFlowTesting
import Testing

@Suite("EffectTiming trend script")
struct EffectTimingTrendScriptTests {

  @Test("Trend script reports mean and p95 for an existing capture")
  func trendScriptReportsBothMetrics() throws {
    let result = try runTrendScript(
      baselineEntries: matchedRunEntries(durations: [100, 110, 120]),
      currentEntries: matchedRunEntries(durations: [105, 115, 125])
    )

    #expect(result.terminationStatus == 0)
    #expect(result.stdout.contains("metric=mean"))
    #expect(result.stdout.contains("metric=p95"))
    #expect(result.stdout.contains("baselineRuns=3"))
    #expect(result.stdout.contains("currentRuns=3"))
  }

  @Test("Trend script reports regressions without failing the command")
  func trendScriptKeepsRegressionsNonBlocking() throws {
    let result = try runTrendScript(
      baselineEntries: matchedRunEntries(durations: [100, 100, 100]),
      currentEntries: matchedRunEntries(durations: [400, 400, 400])
    )

    #expect(result.terminationStatus == 0)
    #expect(result.stdout.contains("NON-BLOCKING_REGRESSION"))
    #expect(result.stdout.contains("FAIL"))
  }

  @Test("Trend script fails loudly for incomplete captures")
  func trendScriptFailsForIncompleteCapture() throws {
    let result = try runTrendScript(
      baselineEntries: matchedRunEntries(durations: [100, 110, 120]),
      currentEntries: []
    )

    #expect(result.terminationStatus == 2)
    #expect(
      result.stderr.contains(
        "current capture has no matched runs — incomplete capture or missing runFinished events")
    )
  }

  @Test("Trend script help documents non-blocking mean and p95 reporting")
  func trendScriptHelpDocumentsDualMetricReporting() throws {
    let process = Process()
    process.executableURL = try effectTimingRepositoryFileURL(
      relativePath: "scripts/report-effect-timing-trend.sh"
    )
    process.arguments = ["--help"]

    let stdout = Pipe()
    process.standardOutput = stdout

    try process.run()
    process.waitUntilExit()

    let stdoutText =
      String(
        data: stdout.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
      ) ?? ""

    #expect(process.terminationStatus == 0)
    #expect(stdoutText.contains("mean"))
    #expect(stdoutText.contains("p95"))
    #expect(stdoutText.contains("non-blocking"))
    #expect(stdoutText.contains("2  usage error, capture failure, or malformed/incomplete data"))
  }

  // MARK: - Helpers

  private func runTrendScript(
    baselineEntries: [[String: Any]],
    currentEntries: [[String: Any]]
  ) throws -> ScriptResult {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("effect-timing-trend-script-\(UUID().uuidString)", isDirectory: true)
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
    process.executableURL = try effectTimingRepositoryFileURL(
      relativePath: "scripts/report-effect-timing-trend.sh"
    )
    process.arguments = [
      "--baseline", baselineURL.path,
      "--current", currentURL.path,
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
}

private struct ScriptResult {
  let terminationStatus: Int32
  let stdout: String
  let stderr: String
}
