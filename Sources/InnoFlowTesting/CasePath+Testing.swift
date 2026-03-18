import Foundation
import InnoFlow

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

@discardableResult
public func assertCasePathExtracts<Root, Value>(
  _ root: Root,
  via path: CasePath<Root, Value>,
  caseName: String? = nil,
  fileID: StaticString = #fileID,
  line: UInt = #line
) -> Value {
  if let value = path.extract(root) {
    return value
  }

  testStoreAssertionFailure(
    casePathExtractionFailureMessage(root: root, caseName: caseName),
    file: fileID,
    line: line
  )

  fatalError("assertCasePathExtracts must not continue after recording a failure")
}
