import Foundation
package import InnoFlowCore

#if canImport(Testing)
  import Testing
#endif
#if canImport(XCTest)
  import XCTest
#endif

/// The complete user call site, passed as one value through assertion stepping
/// and asynchronous effect origins. This never records a framework call site.
package struct TestStoreSourceLocation: Sendable {
  package let fileID: StaticString
  package let filePath: StaticString
  package let line: UInt
  package let column: UInt

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

  #if canImport(Testing)
    var testingLocation: SourceLocation {
      SourceLocation(
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

func testStoreAssertionFailure(_ message: String, location: TestStoreSourceLocation) {
  #if DEBUG
    print(
      "❌ TestStore Assertion Failed:\n\(message)\nFile: \(location.filePath), Line: \(location.line), Column: \(location.column)"
    )
  #endif
  #if canImport(Testing)
    if Test.current != nil {
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
    if Test.current != nil {
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
