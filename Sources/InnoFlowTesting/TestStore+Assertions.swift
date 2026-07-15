// MARK: - TestStore+Assertions.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

#if canImport(Testing)
  import Testing
#elseif canImport(XCTest)
  import XCTest
#endif

// MARK: - Assertion Helper

func testStoreAssertionFailure(
  _ message: String,
  file: StaticString,
  line: UInt
) {
  #if DEBUG
    print("❌ TestStore Assertion Failed:")
    print(message)
    print("File: \(file), Line: \(line)")
  #endif

  #if canImport(Testing)
    Issue.record(
      TestStoreAssertionIssue(
        message: "\(file):\(line): \(message)"
      )
    )
  #elseif canImport(XCTest)
    XCTFail(message, file: file, line: line)
  #else
    Swift.assertionFailure(message, file: file, line: line)
  #endif
}

func testStoreAssertionWarning(
  _ message: String,
  file: StaticString,
  line: UInt
) {
  #if DEBUG
    print("⚠️ TestStore Assertion Skipped:")
    print(message)
    print("File: \(file), Line: \(line)")
  #endif

  #if canImport(Testing)
    Issue.record(
      Comment(rawValue: "\(file):\(line): \(message)"),
      severity: .warning,
      sourceLocation: SourceLocation(
        fileID: String(describing: file),
        filePath: String(describing: file),
        line: Int(line),
        column: 1
      )
    )
  #elseif canImport(XCTest)
    print("⚠️ \(file):\(line): \(message)")
  #else
    print("⚠️ \(file):\(line): \(message)")
  #endif
}

func scopedTestStoreFailureContext(stableID: AnyHashable?) -> String? {
  guard let stableID else { return nil }
  return "Scoped collection element (id: \(String(describing: stableID)))"
}

func scopedTestStoreStateMismatchLabel(stableID: AnyHashable?) -> String {
  guard let failureContext = scopedTestStoreFailureContext(stableID: stableID) else {
    return "Scoped state"
  }
  return "\(failureContext) state"
}

#if canImport(Testing)
  private struct TestStoreAssertionIssue: Error, Sendable, CustomStringConvertible {
    let message: String
    var description: String { message }
  }
#endif
