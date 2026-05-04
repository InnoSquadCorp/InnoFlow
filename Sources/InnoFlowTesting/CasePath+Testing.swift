import Foundation
public import InnoFlow

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
/// - Returns: The extracted value when the case path matches, otherwise `nil`
///   after recording a test failure.
@discardableResult
public func assertCasePathExtracts<Root, Value>(
  _ root: Root,
  via path: CasePath<Root, Value>,
  caseName: String? = nil,
  fileID: StaticString = #fileID,
  line: UInt = #line
) -> Value? {
  if let value = path.extract(root) {
    return value
  }

  testStoreAssertionFailure(
    casePathExtractionFailureMessage(root: root, caseName: caseName),
    file: fileID,
    line: line
  )
  return nil
}
