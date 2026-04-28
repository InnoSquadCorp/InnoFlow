// MARK: - ReducerCompositionPerfComparisonScriptTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.
//
// Contract tests for `scripts/compare-reducer-composition-perf.sh`.

import Foundation
import InnoFlow
import InnoFlowTesting
import Testing

@Suite("Reducer composition perf comparison script")
struct ReducerCompositionPerfComparisonScriptTests {

  @Test("Reducer perf comparison passes when all benchmarks stay within tolerance")
  func reducerPerfComparisonPassesWithinTolerance() throws {
    let result = try runComparisonScript(
      baselineEntries: [
        entry(label: "construct-only N=2", perIterationNanos: 100),
        entry(label: "construct-only N=8", perIterationNanos: 200),
      ],
      currentEntries: [
        entry(label: "construct-only N=2", perIterationNanos: 110),
        entry(label: "construct-only N=8", perIterationNanos: 220),
      ],
      tolerance: "0.20"
    )

    #expect(result.terminationStatus == 0)
    #expect(result.stdout.contains("overall=PASS"))
  }

  @Test("Reducer perf comparison fails when a benchmark regresses past tolerance")
  func reducerPerfComparisonFailsForRegression() throws {
    let result = try runComparisonScript(
      baselineEntries: [entry(label: "dispatch N=8 × 10k", perIterationNanos: 100)],
      currentEntries: [entry(label: "dispatch N=8 × 10k", perIterationNanos: 200)],
      tolerance: "0.25"
    )

    #expect(result.terminationStatus == 1)
    #expect(result.stderr.contains("dispatch N=8 × 10k"))
    #expect(result.stderr.contains("overall=FAIL"))
  }

  @Test("Reducer perf comparison fails when current results miss a benchmark")
  func reducerPerfComparisonFailsForMissingBenchmark() throws {
    let result = try runComparisonScript(
      baselineEntries: [
        entry(label: "construct-only N=2", perIterationNanos: 100),
        entry(label: "dispatch N=8 × 10k", perIterationNanos: 200),
      ],
      currentEntries: [
        entry(label: "construct-only N=2", perIterationNanos: 105)
      ]
    )

    #expect(result.terminationStatus == 1)
    #expect(result.stderr.contains("missing benchmark"))
  }

  @Test("Reducer perf comparison fails clearly when an option value is missing")
  func reducerPerfComparisonFailsForMissingOptionValue() throws {
    let result = try runRawComparisonScript(arguments: ["--baseline"])

    #expect(result.terminationStatus == 1)
    #expect(result.stderr.contains("missing value for --baseline"))
  }

  @Test("Reducer perf comparison fails when per-iteration metric is malformed")
  func reducerPerfComparisonFailsForMalformedPerIterationMetric() throws {
    let result = try runComparisonScript(
      baselineEntries: [
        [
          "iterations": 1_000,
          "label": "construct-only N=2",
          "totalNanos": 100_000,
        ]
      ],
      currentEntries: [entry(label: "construct-only N=2", perIterationNanos: 100)]
    )

    #expect(result.terminationStatus == 1)
    #expect(result.stderr.contains("baseline perIterationNanos must be numeric"))
  }

  @Test("Reducer perf comparison help documents local benchmark export")
  func reducerPerfComparisonHelpDocumentsLocalExport() throws {
    let process = Process()
    process.executableURL = try repositoryFileURL(
      relativePath: "scripts/compare-reducer-composition-perf.sh"
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
    #expect(stdoutText.contains("INNOFLOW_REDUCER_PERF_OUTPUT=/tmp/reducer-composition-perf.jsonl"))
    #expect(stdoutText.contains("PerfReducerComposition"))
  }

  // MARK: - Helpers

  private func runComparisonScript(
    baselineEntries: [[String: Any]],
    currentEntries: [[String: Any]],
    tolerance: String = "0.25"
  ) throws -> ScriptResult {
    try requireJQ()

    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("reducer-perf-script-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true,
      attributes: nil
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let baselineURL = temporaryDirectory.appendingPathComponent("baseline.jsonl")
    let currentURL = temporaryDirectory.appendingPathComponent("current.jsonl")
    try writeJSONL(entries: baselineEntries, to: baselineURL)
    try writeJSONL(entries: currentEntries, to: currentURL)

    let process = Process()
    process.executableURL = try repositoryFileURL(
      relativePath: "scripts/compare-reducer-composition-perf.sh"
    )
    process.arguments = [
      "--baseline", baselineURL.path,
      "--current", currentURL.path,
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

  private func runRawComparisonScript(arguments: [String]) throws -> ScriptResult {
    let process = Process()
    process.executableURL = try repositoryFileURL(
      relativePath: "scripts/compare-reducer-composition-perf.sh"
    )
    process.arguments = arguments

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

  private func requireJQ() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["jq", "--version"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output

    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
      throw ScriptDependencyError.missingJQ
    }
  }

  private func writeJSONL(entries: [[String: Any]], to url: URL) throws {
    var payload = Data()
    for entry in entries {
      payload.append(try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]))
      payload.append(0x0A)
    }
    try payload.write(to: url, options: .atomic)
  }

  private func entry(label: String, perIterationNanos: UInt64) -> [String: Any] {
    [
      "iterations": 1_000,
      "label": label,
      "perIterationNanos": perIterationNanos,
      "totalNanos": perIterationNanos * 1_000,
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

private enum ScriptDependencyError: Error, CustomStringConvertible {
  case missingJQ

  var description: String {
    "'jq' is required to run reducer perf comparison script tests. Install with: brew install jq"
  }
}

private struct ScriptResult {
  let terminationStatus: Int32
  let stdout: String
  let stderr: String
}
