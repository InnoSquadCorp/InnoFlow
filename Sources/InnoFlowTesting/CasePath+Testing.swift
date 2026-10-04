import Foundation
@_exported public import InnoFlowCore

/// Returns a human-readable failure message when a case-path extraction does
/// not match the expected enum case.
func casePathExtractionFailureMessage<Root>(
  root: Root,
  caseName: String?
) -> String {
  let renderedCaseName = caseName.map { "\nExpected case: \($0)" } ?? ""
  return """
      expected case path did not match

      Root type:
      \(String(reflecting: Root.self))
      \(renderedCaseName)

      Root value:
    \(String(reflecting: root))
    """
}

/// Asserts that a case path extracts a value from the provided root enum.
///
/// - Parameters:
///   - root: The enum value to inspect.
///   - path: The case path expected to match.
///   - caseName: Optional case label used to make failures easier to read.
///   - fileID: The source file identifier reported when extraction fails.
///   - filePath: The source file path reported when extraction fails.
///   - line: The source line reported when extraction fails.
///   - column: The source column reported when extraction fails.
/// - Returns: The extracted value when the case path matches, otherwise `nil`
///   after recording a test failure.
@discardableResult
public func assertCasePathExtracts<Root, Value>(
  _ root: Root,
  via path: CasePath<Root, Value>,
  caseName: String? = nil,
  fileID: StaticString = #fileID,
  filePath: StaticString = #filePath,
  line: UInt = #line,
  column: UInt = #column
) -> Value? {
  assertCasePathExtracts(
    root, via: path, caseName: caseName,
    location: .init(fileID: fileID, filePath: filePath, line: line, column: column))
}

@discardableResult
package func assertCasePathExtracts<Root, Value>(
  _ root: Root,
  via path: CasePath<Root, Value>,
  caseName: String? = nil,
  location: TestStoreSourceLocation
) -> Value? {
  if let value = path.extract(root) {
    return value
  }

  testStoreAssertionFailure(
    casePathExtractionFailureMessage(root: root, caseName: caseName),
    location: location
  )
  return nil
}
