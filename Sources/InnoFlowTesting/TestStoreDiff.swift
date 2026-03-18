import Foundation

let defaultStateDiffLineLimit = 12
let testStoreDiffLineLimitEnvironmentKey = "INNOFLOW_TESTSTORE_DIFF_LINE_LIMIT"

func resolveDiffLineLimit(explicit: Int?, environment: [String: String]) -> Int {
  if let explicit {
    if explicit == 0 {
      return 0
    }
    if explicit > 0 {
      return explicit
    }
  }

  if let rawValue = environment[testStoreDiffLineLimitEnvironmentKey],
    let parsed = Int(rawValue)
  {
    if parsed == 0 {
      return 0
    }
    if parsed > 0 {
      return parsed
    }
  }

  return defaultStateDiffLineLimit
}

func renderStateDiff(
  expected: Any,
  actual: Any,
  lineLimit: Int = defaultStateDiffLineLimit
) -> String? {
  guard lineLimit > 0 else { return nil }
  let lines = diffLines(expected: expected, actual: actual, path: "")
  guard !lines.isEmpty else { return nil }
  return lines.prefix(lineLimit).joined(separator: "\n")
}

private func diffLines(expected: Any, actual: Any, path: String) -> [String] {
  let expectedDescription = String(reflecting: expected)
  let actualDescription = String(reflecting: actual)

  guard expectedDescription != actualDescription else {
    return []
  }

  let expectedMirror = Mirror(reflecting: expected)
  let actualMirror = Mirror(reflecting: actual)

  guard type(of: expected) == type(of: actual),
    expectedMirror.displayStyle == actualMirror.displayStyle
  else {
    return [formatDiff(path: path, expected: expectedDescription, actual: actualDescription)]
  }

  switch expectedMirror.displayStyle {
  case .struct, .tuple:
    let expectedChildren = Array(expectedMirror.children)
    let actualChildren = Array(actualMirror.children)
    guard expectedChildren.count == actualChildren.count else {
      return [formatDiff(path: path, expected: expectedDescription, actual: actualDescription)]
    }

    var lines: [String] = []
    for index in expectedChildren.indices {
      let label = expectedChildren[index].label ?? actualChildren[index].label ?? "\(index)"
      let childPath = path.isEmpty ? label : "\(path).\(label)"
      lines += diffLines(
        expected: expectedChildren[index].value,
        actual: actualChildren[index].value,
        path: childPath
      )
    }
    return lines.isEmpty
      ? [formatDiff(path: path, expected: expectedDescription, actual: actualDescription)] : lines

  case .set:
    let expectedSetDescription = stableSetDescription(expectedMirror)
    let actualSetDescription = stableSetDescription(actualMirror)
    guard expectedSetDescription != actualSetDescription else {
      return []
    }
    return [formatDiff(path: path, expected: expectedSetDescription, actual: actualSetDescription)]

  case .collection:
    let expectedChildren = Array(expectedMirror.children)
    let actualChildren = Array(actualMirror.children)
    guard expectedChildren.count == actualChildren.count else {
      return [formatDiff(path: path, expected: expectedDescription, actual: actualDescription)]
    }

    var lines: [String] = []
    for index in expectedChildren.indices {
      let childPath = path.isEmpty ? "[\(index)]" : "\(path)[\(index)]"
      lines += diffLines(
        expected: expectedChildren[index].value,
        actual: actualChildren[index].value,
        path: childPath
      )
    }
    return lines.isEmpty
      ? [formatDiff(path: path, expected: expectedDescription, actual: actualDescription)] : lines

  case .optional:
    let expectedChildren = Array(expectedMirror.children)
    let actualChildren = Array(actualMirror.children)
    switch (expectedChildren.first, actualChildren.first) {
    case (nil, nil):
      return []
    case (let lhs?, let rhs?):
      return diffLines(expected: lhs.value, actual: rhs.value, path: path)
    default:
      return [formatDiff(path: path, expected: expectedDescription, actual: actualDescription)]
    }

  case .enum:
    let expectedChildren = Array(expectedMirror.children)
    let actualChildren = Array(actualMirror.children)
    guard expectedChildren.count == actualChildren.count,
      !expectedChildren.isEmpty
    else {
      return [formatDiff(path: path, expected: expectedDescription, actual: actualDescription)]
    }

    var lines: [String] = []
    for index in expectedChildren.indices {
      let label =
        expectedChildren[index].label ?? actualChildren[index].label ?? "associatedValue\(index)"
      let childPath = path.isEmpty ? label : "\(path).\(label)"
      lines += diffLines(
        expected: expectedChildren[index].value,
        actual: actualChildren[index].value,
        path: childPath
      )
    }
    return lines.isEmpty
      ? [formatDiff(path: path, expected: expectedDescription, actual: actualDescription)] : lines

  case .dictionary:
    let expectedDictionaryDescription = stableDictionaryDescription(expectedMirror)
    let actualDictionaryDescription = stableDictionaryDescription(actualMirror)
    guard expectedDictionaryDescription != actualDictionaryDescription else {
      return []
    }
    return [
      formatDiff(
        path: path,
        expected: expectedDictionaryDescription,
        actual: actualDictionaryDescription
      )
    ]

  default:
    return [formatDiff(path: path, expected: expectedDescription, actual: actualDescription)]
  }
}

private func formatDiff(path: String, expected: String, actual: String) -> String {
  let renderedPath = path.isEmpty ? "state" : path
  return "\(renderedPath): expected \(expected), actual \(actual)"
}

private func stableSetDescription(_ mirror: Mirror) -> String {
  let elements = mirror.children
    .map { String(reflecting: $0.value) }
    .sorted()
  return "Set([\(elements.joined(separator: ", "))])"
}

private func stableDictionaryDescription(_ mirror: Mirror) -> String {
  let entries = mirror.children.compactMap { child -> (String, String)? in
    let tupleChildren = Array(Mirror(reflecting: child.value).children)
    guard tupleChildren.count == 2 else { return nil }
    let key = String(reflecting: tupleChildren[0].value)
    let value = String(reflecting: tupleChildren[1].value)
    return (key, value)
  }
  .sorted { lhs, rhs in
    if lhs.0 == rhs.0 {
      return lhs.1 < rhs.1
    }
    return lhs.0 < rhs.0
  }
  .map { key, value in
    "\(key): \(value)"
  }

  return "[\(entries.joined(separator: ", "))]"
}
