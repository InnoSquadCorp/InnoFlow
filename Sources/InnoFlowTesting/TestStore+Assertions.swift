import Foundation
package import InnoFlowCore

#if canImport(Testing)
  import Testing
#endif
#if canImport(XCTest)
  import XCTest
#endif

/// The complete user call site, passed as one value through assertion stepping
/// and asynchronous effect origins. This never records a framework call site;
/// where no user call site exists, ``unattributed()`` names the running test.
package struct TestStoreSourceLocation: Sendable {
  package let fileID: StaticString
  package let filePath: StaticString
  package let line: UInt
  package let column: UInt
  #if canImport(Testing)
    /// The running test's declaration, used instead of the static fields when
    /// a failure has no user call site of its own.
    private var runningTestLocation: SourceLocation?
  #endif

  package init(
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) {
    self.fileID = fileID
    self.filePath = filePath
    self.line = line
    self.column = column
  }

  package init(_ origin: EffectOrigin) {
    self.init(
      fileID: origin.fileID, filePath: origin.file, line: origin.line, column: origin.column)
  }

  /// A location for a failure that no user call site led to, such as a
  /// scenario step that has no call-site parameters and runs before any
  /// assertion on its store. Swift Testing attributes it to the running test;
  /// XCTest, which exposes no running test location, keeps the static fields.
  package static func unattributed(
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) -> Self {
    var location = Self(fileID: fileID, filePath: filePath, line: line, column: column)
    #if canImport(Testing)
      location.runningTestLocation = Test.current?.sourceLocation
    #endif
    return location
  }

  #if canImport(Testing)
    /// Where Swift Testing records an issue reported at this location.
    package var testingFileIDAndLine: (fileID: String, line: Int) {
      let location = testingLocation
      return (location.fileID, location.line)
    }

    var testingLocation: SourceLocation {
      if let runningTestLocation { return runningTestLocation }
      return SourceLocation(
        fileID: fileID.description,
        filePath: filePath.description,
        line: Int(clamping: line),
        column: Int(clamping: column)
      )
    }
  #endif
}

extension EffectOrigin {
  init(location: TestStoreSourceLocation) {
    self.init(
      file: location.filePath, line: location.line, fileID: location.fileID, column: location.column
    )
  }
}

/// Carries the owning test framework into contexts that cannot see task-local
/// values.
///
/// An isolated deinitializer runs with task-locals cleared, so `Test.current`
/// is `nil` there even when the store belongs to a Swift Testing test. The
/// store records which framework created it and re-establishes that fact
/// around diagnostics it reports while deinitializing.
package enum TestStoreReportingContext {
  @TaskLocal package static var ownerUsesSwiftTesting = false

  /// Whether a Swift Testing test is running in the current task.
  package static var isSwiftTestingCurrent: Bool {
    #if canImport(Testing)
      return Test.current != nil
    #else
      return false
    #endif
  }

  /// Whether a diagnostic must be recorded as a Swift Testing issue.
  package static var reportsThroughSwiftTesting: Bool {
    isSwiftTestingCurrent || ownerUsesSwiftTesting
  }
}

func testStoreAssertionFailure(_ message: String, location: TestStoreSourceLocation) {
  #if DEBUG
    print(
      "❌ TestStore Assertion Failed:\n\(message)\nFile: \(location.filePath), Line: \(location.line), Column: \(location.column)"
    )
  #endif
  #if canImport(Testing)
    if TestStoreReportingContext.reportsThroughSwiftTesting {
      Issue.record(
        TestStoreAssertionIssue(message: message), sourceLocation: location.testingLocation)
      return
    }
  #endif
  #if canImport(XCTest)
    XCTFail(message, file: location.filePath, line: location.line)
  #else
    Swift.assertionFailure(message, file: location.filePath, line: location.line)
  #endif
}

func testStoreAssertionWarning(_ message: String, location: TestStoreSourceLocation) {
  #if canImport(Testing)
    if TestStoreReportingContext.reportsThroughSwiftTesting {
      Issue.record(
        Comment(rawValue: message), severity: .warning, sourceLocation: location.testingLocation)
      return
    }
  #endif
  print("⚠️ \(location.filePath):\(location.line):\(location.column): \(message)")
}

// Legacy package hooks intentionally lack column information. Public canonical
// assertions always enter the complete-location path above.
func testStoreAssertionFailure(_ message: String, file: StaticString, line: UInt) {
  testStoreAssertionFailure(
    message, location: .init(fileID: file, filePath: file, line: line, column: 1))
}

func testStoreAssertionWarning(_ message: String, file: StaticString, line: UInt) {
  testStoreAssertionWarning(
    message, location: .init(fileID: file, filePath: file, line: line, column: 1))
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
