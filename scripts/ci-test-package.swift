// Rewrite only the root Package initializer's arrays, preserving reviewed declarations.
import Foundation
import SwiftParser
import SwiftSyntax

final class Selection: SyntaxRewriter {
  let names: Set<String>
  init(names: Set<String>) { self.names = names }

  func declaredName(_ expression: ExprSyntax) -> String? {
    guard let call = expression.as(FunctionCallExprSyntax.self),
      let argument = call.arguments.first(where: { $0.label?.text == "name" }),
      let literal = argument.expression.as(StringLiteralExprSyntax.self),
      literal.segments.count == 1,
      let segment = literal.segments.first?.as(StringSegmentSyntax.self)
    else { return nil }
    return segment.content.text
  }

  override func visit(_ node: FunctionCallExprSyntax) -> ExprSyntax {
    guard node.calledExpression.trimmedDescription == "Package" else {
      return super.visit(node)
    }
    var result = node
    result.arguments = LabeledExprListSyntax(
      node.arguments.map { argument in
        guard ["targets", "products"].contains(argument.label?.text ?? ""),
          var array = argument.expression.as(ArrayExprSyntax.self)
        else { return argument }
        let kept = array.elements.filter { element in
          guard let name = declaredName(element.expression) else {
            fatalError("Unsupported manifest declaration")
          }
          return names.contains(name)
        }
        array.elements = kept
        var result = argument
        result.expression = ExprSyntax(array)
        return result
      })
    return ExprSyntax(result)
  }
}

guard CommandLine.arguments.count >= 3 else { fatalError("manifest and target names required") }
let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let tree = Parser.parse(source: source)
guard !tree.hasError else { fatalError("Invalid manifest syntax") }
let selection = Selection(names: Set(CommandLine.arguments.dropFirst(2)))
print(selection.rewrite(tree).description, terminator: "")
