// MARK: - EffectTimingBaselineSupportTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import InnoFlowTesting
import Testing

@Suite("EffectTiming baseline support")
struct EffectTimingBaselineSupportTests {

  @Test("Matched run pair counting ignores incomplete sequences")
  func matchedRunPairCountingIgnoresIncompleteSequences() {
    let entries: [EffectTimingRecorder.Entry] = [
      .init(
        phase: .runStarted,
        sequence: 1,
        effectID: nil,
        actionLabel: nil,
        timestampNanos: 100
      ),
      .init(
        phase: .runFinished,
        sequence: 1,
        effectID: nil,
        actionLabel: nil,
        timestampNanos: 200
      ),
      .init(
        phase: .runStarted,
        sequence: 2,
        effectID: nil,
        actionLabel: nil,
        timestampNanos: 300
      ),
      .init(
        phase: .actionEmitted,
        sequence: 2,
        effectID: nil,
        actionLabel: "tick",
        timestampNanos: 350
      ),
    ]

    #expect(matchedRunPairCount(in: entries) == 1)
  }

  @Test("Repository helper resolves the committed baseline fixture")
  func repositoryHelperResolvesBaselineFixture() throws {
    let baselineURL = try effectTimingRepositoryFileURL(
      relativePath: EffectTimingBaselineContract.baselineFixtureRelativePath
    )

    #expect(FileManager.default.fileExists(atPath: baselineURL.path))
    #expect(baselineURL.path.hasSuffix("EffectTimings.baseline.jsonl"))
  }

  @Test("Effect timing wait helper polls until the condition becomes true")
  func waitHelperPollsUntilConditionSucceeds() async {
    let flag = TestFlag()

    let succeeded = await waitForEffectTimingCondition(
      timeout: .seconds(1),
      pollInterval: .milliseconds(10),
      description: "test flag to become ready",
      condition: {
        await flag.pollUntilReady()
      },
      status: {
        await flag.status
      }
    )

    #expect(succeeded)
  }

  @Test("Effect timing wait helper returns promptly when cancelled")
  func waitHelperReturnsFalseWhenCancelled() async {
    let task = Task {
      await waitForEffectTimingCondition(
        timeout: .seconds(5),
        pollInterval: .seconds(1),
        description: "cancelled wait",
        condition: { false },
        status: { "still waiting" }
      )
    }

    task.cancel()
    let succeeded = await task.value

    #expect(!succeeded)
  }
}

private actor TestFlag {
  private var pollCount = 0

  var status: String {
    "pollCount=\(pollCount)"
  }

  func pollUntilReady() -> Bool {
    pollCount += 1
    return pollCount >= 2
  }
}
