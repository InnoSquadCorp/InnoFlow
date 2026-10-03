// Source-declaration inventory only: this does not execute or certify any tests.
// SwiftSyntax avoids counting @Test examples embedded in strings/comments.
import Foundation
import SwiftParser
import SwiftSyntax

final class Inventory: SyntaxVisitor {
  let file: String
  let target: String
  let converter: SourceLocationConverter
  var items: [[String: Any]] = []
  init(file: String, target: String, tree: SourceFileSyntax) {
    self.file = file
    self.target = target
    self.converter = SourceLocationConverter(fileName: file, tree: tree)
    super.init(viewMode: .sourceAccurate)
  }
  override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
    let tests = node.attributes.compactMap { $0.as(AttributeSyntax.self) }.filter {
      ["Test", "Testing.Test"].contains($0.attributeName.trimmedDescription)
    }
    guard let test = tests.first else { return .skipChildren }
    var scopes: [String] = []
    var conditions: [String] = []
    var current = node.parent
    while let parent = current {
      if let item = parent.as(StructDeclSyntax.self) { scopes.append(item.name.text) }
      if let item = parent.as(ClassDeclSyntax.self) { scopes.append(item.name.text) }
      if let item = parent.as(EnumDeclSyntax.self) { scopes.append(item.name.text) }
      if let item = parent.as(ExtensionDeclSyntax.self) {
        scopes.append(item.extendedType.trimmedDescription)
      }
      if let item = parent.as(IfConfigClauseSyntax.self) {
        conditions.append(item.poundKeyword.text + " " + (item.condition?.trimmedDescription ?? ""))
      }
      current = parent.parent
    }
    let parameters = node.signature.parameterClause.parameters.map { $0.firstName.text + ":" }
      .joined()
    let signature = node.name.text + "(" + parameters + ")"
    var displayName: String = signature
    if case .argumentList(let arguments) = test.arguments, let first = arguments.first,
      first.label == nil, let value = first.expression.as(StringLiteralExprSyntax.self)
    {
      displayName = value.segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }
        .joined()
    }
    items.append([
      "target": target, "file": file,
      "line": converter.location(for: node.positionAfterSkippingLeadingTrivia).line,
      "identifier": (scopes.reversed() + [signature]).joined(separator: "/"),
      "displayName": displayName,
      "conditionalContexts": Array(conditions.reversed()),
      "attribute": test.trimmedDescription,
    ])
    return .skipChildren
  }
}
let root = CommandLine.arguments[1]
var all: [[String: Any]] = []
let targets = CommandLine.arguments.count > 2
  ? Array(CommandLine.arguments.dropFirst(2)) : ["InnoFlowTests", "InnoFlowMacrosTests"]
for target in targets {
  let path = root + "/Tests/" + target
  guard let enumerator = FileManager.default.enumerator(atPath: path) else {
    throw CocoaError(.fileNoSuchFile)
  }
  let files = enumerator.compactMap { $0 as? String }.filter {
    $0.hasSuffix(".swift") && !$0.hasPrefix("Fixtures/")
  }.sorted()
  for name in files {
    let relative = "Tests/" + target + "/" + name
    let tree = Parser.parse(
      source: try String(contentsOfFile: root + "/" + relative, encoding: .utf8))
    guard !tree.hasError else {
      FileHandle.standardError.write(Data("Invalid Swift test source: \(relative)\n".utf8))
      exit(65)
    }
    let visitor = Inventory(file: relative, target: target, tree: tree)
    visitor.walk(tree)
    all += visitor.items
  }
}
let data = try JSONSerialization.data(
  withJSONObject: all, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
