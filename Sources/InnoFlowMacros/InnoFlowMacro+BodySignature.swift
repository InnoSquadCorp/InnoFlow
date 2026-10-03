// MARK: - InnoFlowMacro+BodySignature.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

extension InnoFlowMacro {
  static func bodySignatureIssues(
    _ variable: VariableDeclSyntax,
    hasOutput: Bool
  ) -> [String] {
    var issues: [String] = []
    let expectedOutput = hasOutput ? "Output" : "Never"
    let expectedSignature = "some Reducer<State, Action, \(expectedOutput)>"
    guard let binding = variable.bindings.first else {
      issues.append("missing `body` binding")
      return issues
    }

    guard let typeAnnotation = binding.typeAnnotation else {
      issues.append(
        "`body` must declare an explicit `\(expectedSignature)` type"
      )
      return issues
    }

    let type = typeAnnotation.type

    guard let someOrAny = type.as(SomeOrAnyTypeSyntax.self) else {
      issues.append(
        "`body` type `\(type.trimmedDescription)` must be an opaque `\(expectedSignature)` type"
      )
      return issues
    }

    guard someOrAny.someOrAnySpecifier.tokenKind == .keyword(.some) else {
      issues.append("`body` must use `some` (not `\(someOrAny.someOrAnySpecifier.text)`)")
      return issues
    }

    // `Reducer` may be spelled bare or module-qualified — it lives in
    // InnoFlowCore and is reexported by InnoFlow, so both qualifications are
    // legitimate authoring.
    let constraintName: String
    let genericArgumentClause: GenericArgumentClauseSyntax?
    if let identifierType = someOrAny.constraint.as(IdentifierTypeSyntax.self) {
      constraintName = logicalIdentifier(identifierType.name)
      genericArgumentClause = identifierType.genericArgumentClause
    } else if let memberType = someOrAny.constraint.as(MemberTypeSyntax.self),
      let base = memberType.baseType.as(IdentifierTypeSyntax.self),
      logicalIdentifier(base.name) == "InnoFlow" || logicalIdentifier(base.name) == "InnoFlowCore",
      base.genericArgumentClause == nil
    {
      constraintName = logicalIdentifier(memberType.name)
      genericArgumentClause = memberType.genericArgumentClause
    } else {
      issues.append(
        "`body` constraint `\(someOrAny.constraint.trimmedDescription)` is not a recognized type")
      return issues
    }

    guard constraintName == "Reducer" else {
      issues.append("`body` type must constrain to `Reducer`, found `\(constraintName)`")
      return issues
    }

    guard let genericArgs = genericArgumentClause else {
      issues.append("`body` type must specify `Reducer<State, Action, \(expectedOutput)>`")
      return issues
    }

    let args = Array(genericArgs.arguments)
    guard args.count == 3 else {
      issues.append(
        "`body` must have exactly 3 generic parameters (State, Action, Output), found \(args.count)"
      )
      return issues
    }

    if !isNestedTypeReference(args[0].argument, named: "State") {
      issues.append(
        "first generic parameter must be `State` (or `Self.State`), found `\(args[0].argument.trimmedDescription)`"
      )
    }

    if !isNestedTypeReference(args[1].argument, named: "Action") {
      issues.append(
        "second generic parameter must be `Action` (or `Self.Action`), found `\(args[1].argument.trimmedDescription)`"
      )
    }

    let outputArgument = args[2].argument
    if hasOutput {
      if !isNestedTypeReference(outputArgument, named: "Output") {
        issues.append(
          "third generic parameter must be `Output` (or `Self.Output`) because the nested `Output` declares this feature’s output type, found `\(outputArgument.trimmedDescription)`"
        )
      }
    } else if !isNeverTypeReference(outputArgument) {
      issues.append(
        "third generic parameter must be `Never` when the feature declares no nested `Output`, found `\(outputArgument.trimmedDescription)`"
      )
    }

    guard let accessorBlock = binding.accessorBlock else {
      issues.append("`body` must be a computed property returning reducer composition")
      return issues
    }

    switch accessorBlock.accessors {
    case .getter:
      return issues

    case .accessors(let accessors):
      let hasGetter = accessors.contains { accessor in
        accessor.accessorSpecifier.tokenKind == .keyword(.get)
      }
      if !hasGetter {
        issues.append("`body` must provide a getter returning reducer composition")
      }
      return issues
    }
  }

  /// Keep diagnostics and safe source repairs together. A Fix-It is offered
  /// only when the State/Action arguments already satisfy the contract; it
  /// never guesses how to repair an unrelated reducer or foreign state type.
  static func diagnoseBodySignatureIssues(
    _ issues: [String],
    in variable: VariableDeclSyntax,
    hasOutput: Bool,
    anchoredAt anchor: some SyntaxProtocol,
    context: some MacroExpansionContext
  ) {
    let expectedOutput = hasOutput ? "Output" : "Never"
    let message = InnoFlowBodySignatureMessage(issues: issues, outputName: expectedOutput)
    var fixIts: [FixIt] = []
    if issues.count == 1,
      let oldType = variable.bindings.first?.typeAnnotation?.type,
      let newType = repairedOutputArgument(in: oldType, outputName: expectedOutput)
    {
      fixIts.append(
        .replace(
          message: InnoFlowBodySignatureFixIt(outputName: expectedOutput),
          oldNode: oldType,
          newNode: newType
        ))
    }
    context.diagnose(Diagnostic(node: anchor, message: message, fixIts: fixIts))
  }

  private static func repairedOutputArgument(in type: TypeSyntax, outputName: String) -> TypeSyntax?
  {
    guard let opaque = type.as(SomeOrAnyTypeSyntax.self),
      opaque.someOrAnySpecifier.tokenKind == .keyword(.some)
    else { return nil }

    let clause: GenericArgumentClauseSyntax?
    if let identifier = opaque.constraint.as(IdentifierTypeSyntax.self),
      logicalIdentifier(identifier.name) == "Reducer"
    {
      clause = identifier.genericArgumentClause
    } else if let member = opaque.constraint.as(MemberTypeSyntax.self),
      logicalIdentifier(member.name) == "Reducer",
      let base = member.baseType.as(IdentifierTypeSyntax.self),
      ["InnoFlow", "InnoFlowCore"].contains(logicalIdentifier(base.name)),
      base.genericArgumentClause == nil
    {
      clause = member.genericArgumentClause
    } else {
      return nil
    }
    guard let clause else { return nil }
    let arguments = Array(clause.arguments)
    guard arguments.count == 2 || arguments.count == 3,
      isNestedTypeReference(arguments[0].argument, named: "State"),
      isNestedTypeReference(arguments[1].argument, named: "Action")
    else { return nil }

    if arguments.count == 3 {
      let existingOutput = arguments[2].argument
      let isAlreadyCorrect =
        outputName == "Output"
        ? isNestedTypeReference(existingOutput, named: "Output")
        : isNeverTypeReference(existingOutput)
      guard !isAlreadyCorrect else { return nil }
    }
    // Operate on the already-validated argument's exact source range. This
    // preserves comments/trivia and works with both SwiftSyntax 603's type
    // arguments and 604's type-or-value argument representation.
    let offset = type.position.utf8Offset
    var bytes = Array(type.description.utf8)
    if arguments.count == 2 {
      let insertion = clause.rightAngle.position.utf8Offset - offset
      let separator = arguments[1].trailingComma == nil ? ", " : " "
      bytes.insert(contentsOf: (separator + outputName).utf8, at: insertion)
    } else {
      let argument = arguments[2].argument
      let start = argument.positionAfterSkippingLeadingTrivia.utf8Offset - offset
      let end = argument.endPositionBeforeTrailingTrivia.utf8Offset - offset
      bytes.replaceSubrange(start..<end, with: outputName.utf8)
    }
    let repaired = TypeSyntax(stringLiteral: String(decoding: bytes, as: UTF8.self))
    return repaired.hasError ? nil : repaired
  }

  private static func isNeverTypeReference(_ type: some SyntaxProtocol) -> Bool {
    if let identifier = type.as(IdentifierTypeSyntax.self) {
      return logicalIdentifier(identifier.name) == "Never"
        && identifier.genericArgumentClause == nil
    }
    if let member = type.as(MemberTypeSyntax.self),
      logicalIdentifier(member.name) == "Never", member.genericArgumentClause == nil,
      let base = member.baseType.as(IdentifierTypeSyntax.self)
    {
      return logicalIdentifier(base.name) == "Swift" && base.genericArgumentClause == nil
    }
    return false
  }

  /// Returns `true` when `argument` spells a reference to the nested type
  /// `named` — either the bare identifier (`State`) or the explicitly
  /// qualified `Self.State`. Both resolve to the same nested declaration, so
  /// rejecting the qualified spelling would refuse legitimate authoring.
  private static func isNestedTypeReference(
    _ argument: some SyntaxProtocol,
    named expected: String
  ) -> Bool {
    if let identifier = argument.as(IdentifierTypeSyntax.self) {
      return logicalIdentifier(identifier.name) == expected
        && identifier.genericArgumentClause == nil
    }
    if let member = argument.as(MemberTypeSyntax.self),
      logicalIdentifier(member.name) == expected,
      member.genericArgumentClause == nil,
      let base = member.baseType.as(IdentifierTypeSyntax.self),
      logicalIdentifier(base.name) == "Self",
      base.genericArgumentClause == nil
    {
      return true
    }
    return false
  }
}

private struct InnoFlowBodySignatureMessage: DiagnosticMessage {
  let issues: [String]
  let outputName: String

  var message: String {
    """
    Invalid body signature for @InnoFlow.
    Expected:
    var body: some Reducer<State, Action, \(outputName)>
    Detected issues: \(issues.joined(separator: "; ")).
    """
  }

  var diagnosticID: MessageID { .init(domain: "InnoFlowMacro", id: "InvalidBodySignature") }
  var severity: DiagnosticSeverity { .error }
}

private struct InnoFlowBodySignatureFixIt: FixItMessage {
  let outputName: String
  var message: String { "use explicit `\(outputName)` as the third reducer generic parameter" }
  var fixItID: MessageID { .init(domain: "InnoFlowMacro", id: "ExplicitReducerOutputParameter") }
}
