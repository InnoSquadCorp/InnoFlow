// MARK: - CapturedProcessTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import Testing

@Suite("Captured process")
struct CapturedProcessTests {

  @Test("Captures stdout and stderr beyond pipe capacity")
  func capturesLargeOutputWithoutBlocking() throws {
    let line = String(repeating: "x", count: 128)
    let result = try runCapturedProcess(
      executableURL: URL(fileURLWithPath: "/usr/bin/awk"),
      arguments: [
        "BEGIN { for (i = 0; i < 10000; i++) { print \"stdout-\(line)\"; print \"stderr-\(line)\" > \"/dev/stderr\" } }"
      ]
    )

    #expect(result.terminationStatus == 0)
    #expect(result.stdout.utf8.count > 1_000_000)
    #expect(result.stderr.utf8.count > 1_000_000)
    #expect(result.stdout.contains("stdout-\(line)"))
    #expect(result.stderr.contains("stderr-\(line)"))
  }

  @Test("Preserves nonzero status and separate output streams")
  func preservesStatusAndSeparateStreams() throws {
    let result = try runCapturedProcess(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "printf 'stdout-value'; printf 'stderr-value' >&2; exit 7"]
    )

    #expect(result.terminationStatus == 7)
    #expect(result.stdout == "stdout-value")
    #expect(result.stderr == "stderr-value")
  }
}
