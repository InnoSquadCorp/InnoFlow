// MARK: - EffectTimingBaselineSupport.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import InnoFlowTesting
import Testing

enum EffectTimingBaselineContract {
  static let runCount = 10
  static let gateMetric = "mean"
  static let gateTolerance = "1.0"
  static let baselineFixtureRelativePath = "Tests/InnoFlowTests/Fixtures/EffectTimings.baseline.jsonl"
  static let baselineMetadataRelativePath =
    "Tests/InnoFlowTests/Fixtures/EffectTimings.baseline.meta.json"
  static let refreshBuildPath = ".build-effect-baseline-refresh"
}

func effectTimingRepositoryFileURL(
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

func effectTimingRepositoryRelativeOrAbsoluteFileURL(
  path: String,
  file: StaticString = #filePath
) throws -> URL {
  if path.hasPrefix("/") {
    return URL(fileURLWithPath: path)
  }
  return try effectTimingRepositoryFileURL(relativePath: path, file: file)
}

func matchedRunPairCount(in entries: [EffectTimingRecorder.Entry]) -> Int {
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

func waitForEffectTimingCondition(
  timeout: Duration = .seconds(15),
  pollInterval: Duration = .milliseconds(20),
  description: String,
  condition: @escaping () async -> Bool,
  status: @escaping () async -> String
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout
  while clock.now < deadline {
    if await condition() {
      return true
    }
    try? await Task.sleep(for: pollInterval)
  }

  if await condition() {
    return true
  }

  let latestStatus = await status()
  Issue.record("Timed out waiting for \(description); \(latestStatus)")
  return false
}
