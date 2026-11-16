// MARK: - TestWaitScaleTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Testing

@testable import InnoFlowCoreTestSupport

// `INNOFLOW_TEST_WAIT_SCALE` multiplies the backstop deadlines of the shared
// wait helpers. It is read from a CI environment, so a stray space must not
// silently disable it and a huge value must not trap inside `Duration * Double`.

/// Resolves one raw scale and returns it together with every diagnostic the
/// resolver wanted to print.
private func resolve(_ rawValue: String?) -> (scale: Double, diagnostics: [String]) {
  var diagnostics: [String] = []
  let scale = resolveTestWaitScale(rawValue: rawValue) { diagnostics.append($0) }
  return (scale, diagnostics)
}

@Suite("Shared test wait scale", .timeLimit(.minutes(5)))
struct TestWaitScaleTests {
  @Test(
    "An unset or empty scale leaves deadlines unchanged",
    arguments: [nil, "", " ", "\n"] as [String?]
  )
  func unsetScaleIsOne(rawValue: String?) {
    let resolved = resolve(rawValue)

    #expect(resolved.scale == 1)
    #expect(resolved.diagnostics.isEmpty)
    #expect(scaledTestDeadline(.seconds(2), scale: resolved.scale) == .seconds(2))
  }

  @Test(
    "A scale of at least one is used, ignoring surrounding whitespace",
    arguments: [("1", 1.0), ("5", 5.0), ("2.5", 2.5), (" 5", 5.0), ("5 ", 5.0), ("\t5\n", 5.0)]
  )
  func usableScale(rawValue: String, expected: Double) {
    let resolved = resolve(rawValue)

    #expect(resolved.scale == expected)
    #expect(resolved.diagnostics.isEmpty)
    #expect(scaledTestDeadline(.seconds(2), scale: resolved.scale) == .seconds(2) * expected)
  }

  @Test(
    "An unusable scale leaves deadlines unchanged and says so once",
    arguments: ["abc", "0", "0.5", "-2", "nan", "-inf", "5x"]
  )
  func unusableScaleFallsBackAndSaysSo(rawValue: String) {
    let resolved = resolve(rawValue)

    #expect(resolved.scale == 1)
    #expect(resolved.diagnostics.count == 1)
    #expect(resolved.diagnostics.first?.contains(testWaitScaleEnvironmentKey) == true)
    #expect(resolved.diagnostics.first?.contains("\"\(rawValue)\"") == true)
  }

  @Test(
    "A huge scale is clamped, so scaling a deadline cannot trap",
    arguments: ["1001", "1e300", "1e400", "inf"]
  )
  func hugeScaleIsClamped(rawValue: String) {
    let resolved = resolve(rawValue)

    #expect(resolved.scale == maximumTestWaitScale)
    #expect(resolved.diagnostics.count == 1)
    #expect(resolved.diagnostics.first?.contains(testWaitScaleEnvironmentKey) == true)
    #expect(
      scaledTestDeadline(.seconds(2), scale: resolved.scale)
        == .seconds(2) * maximumTestWaitScale)
  }
}
