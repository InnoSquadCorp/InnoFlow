// MARK: - InnoFlowMacro+ExplicitReduceDiagnostics.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

extension InnoFlowMacro {
  static func diagnoseExplicitReduceIfNeeded(
    in declaration: StructDeclSyntax,
    anchoredAt anchor: some SyntaxProtocol,
    context: some MacroExpansionContext
  ) -> Bool {
    guard let reduceFunction = findReduceFunction(in: declaration) else {
      return false
    }

    let diagnostic = explicitReduceDiagnostic(
      anchoredAt: anchor,
      reduceFunction: reduceFunction,
      hasBodyProperty: findBodyProperty(in: declaration) != nil,
      hasOutput: hasNestedType(named: "Output", in: declaration)
    )
    context.diagnose(diagnostic)
    return true
  }

  private static func explicitReduceDiagnostic(
    anchoredAt anchor: some SyntaxProtocol,
    reduceFunction: FunctionDeclSyntax,
    hasBodyProperty: Bool,
    hasOutput: Bool
  ) -> Diagnostic {
    let message = InnoFlowMacroMessage.explicitReduceUnsupported(
      outputName: hasOutput ? "Output" : "Never")

    guard !hasBodyProperty,
      isCanonicalReduceFunction(reduceFunction),
      let effectOutput = canonicalReduceOutput(
        reduceFunction.signature.returnClause?.type, hasOutput: hasOutput),
      let replacement = bodyReplacement(
        for: reduceFunction, hasOutput: hasOutput, effectOutput: effectOutput)?
        .with(\.leadingTrivia, reduceFunction.leadingTrivia)
        .with(\.trailingTrivia, reduceFunction.trailingTrivia)
    else {
      return Diagnostic(node: anchor, message: message)
    }

    return Diagnostic(
      node: anchor,
      message: message,
      fixIt: .replace(
        message: InnoFlowMacroFixIt.replaceExplicitReduce,
        oldNode: reduceFunction,
        newNode: replacement
      )
    )
  }

  private static func isCanonicalReduceFunction(_ function: FunctionDeclSyntax) -> Bool {
    guard logicalIdentifier(function.name) == "reduce",
      function.signature.effectSpecifiers == nil,
      let body = function.body,
      !body.statements.isEmpty
    else {
      return false
    }

    let parameters = Array(function.signature.parameterClause.parameters)
    guard parameters.count == 2 else { return false }
    guard isCanonicalIntoParameter(parameters[0]),
      isCanonicalActionParameter(parameters[1])
    else {
      return false
    }

    return true
  }

  private static func isCanonicalIntoParameter(_ parameter: FunctionParameterSyntax) -> Bool {
    guard logicalIdentifier(parameter.firstName) == "into",
      parameter.secondName.map(logicalIdentifier) == "state"
    else {
      return false
    }

    return parameter.type.trimmedDescription == "inout State"
  }

  private static func isCanonicalActionParameter(_ parameter: FunctionParameterSyntax) -> Bool {
    guard logicalIdentifier(parameter.firstName) == "action",
      parameter.secondName == nil,
      let identifier = parameter.type.as(IdentifierTypeSyntax.self)
    else {
      return false
    }

    return logicalIdentifier(identifier.name) == "Action"
  }

  private static func canonicalReduceOutput(_ type: TypeSyntax?, hasOutput: Bool) -> String? {
    guard let identifier = type?.as(IdentifierTypeSyntax.self),
      let genericArguments = identifier.genericArgumentClause
    else { return nil }
    let arguments = Array(genericArguments.arguments)
    guard let first = arguments.first?.argument.as(IdentifierTypeSyntax.self),
      logicalIdentifier(first.name) == "Action", first.genericArgumentClause == nil
    else { return nil }
    if logicalIdentifier(identifier.name) == "EffectTask", arguments.count == 1 {
      return "Never"
    }
    guard logicalIdentifier(identifier.name) == "ReducerEffect", arguments.count == 2,
      let output = arguments[1].argument.as(IdentifierTypeSyntax.self),
      output.genericArgumentClause == nil
    else { return nil }
    let name = logicalIdentifier(output.name)
    return name == "Never" || (hasOutput && name == "Output") ? name : nil
  }

  private static func bodyReplacement(
    for function: FunctionDeclSyntax,
    hasOutput: Bool,
    effectOutput: String
  ) -> VariableDeclSyntax? {
    guard let body = function.body else { return nil }
    guard !containsMultilineStringLiteral(body.statements) else {
      return nil
    }

    let declarationIndent = trailingIndent(in: function.leadingTrivia.description)
    let reducerIndent = declarationIndent + "    "
    let statementIndent = reducerIndent + "    "
    let renderedStatements = indentCodeBlockItems(
      body.statements,
      prefix: statementIndent
    )
    let outputName = hasOutput ? "Output" : "Never"
    // A legacy EffectTask explicitly cannot emit Output. Keep that closure's
    // inferred type intact and lift it instead of rewriting its return values.
    let promotesOutput = hasOutput && effectOutput == "Never"
    let reducerName = promotesOutput ? "Reduce<State, Action, Never>" : "Reduce"
    let promotion = promotesOutput ? "\n\(reducerIndent).promoteOutput(to: Output.self)" : ""
    return try? VariableDeclSyntax(
      """
      var body: some Reducer<State, Action, \(raw: outputName)> {
      \(raw: reducerIndent)\(raw: reducerName) { state, action in
      \(raw: renderedStatements)
      \(raw: reducerIndent)}\(raw: promotion)
      \(raw: declarationIndent)}
      """
    )
  }

  private static func containsMultilineStringLiteral(_ items: CodeBlockItemListSyntax) -> Bool {
    items.description.contains("\"\"\"")
  }

  private static func indentCodeBlockItems(
    _ items: CodeBlockItemListSyntax,
    prefix: String
  ) -> String {
    let lines = items.flatMap { item in
      item.description
        .trimmingCharacters(in: .newlines)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    }

    let commonIndent =
      lines
      .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      .map { $0.prefix { $0.isWhitespace }.count }
      .min() ?? 0

    return lines.map { line in
      guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
        return prefix
      }
      return prefix + line.dropFirst(commonIndent)
    }
    .joined(separator: "\n")
  }

  private static func trailingIndent(in trivia: String) -> String {
    let suffix = trivia.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
    return String(suffix).replacingOccurrences(of: "\t", with: "    ")
  }
}

enum InnoFlowMacroMessage: DiagnosticMessage {
  case explicitReduceUnsupported(outputName: String)

  var message: String {
    switch self {
    case .explicitReduceUnsupported(let outputName):
      return
        "@InnoFlow no longer supports explicit `reduce(into:action:)` authoring; declare `var body: some Reducer<State, Action, \(outputName)>` instead"
    }
  }

  var diagnosticID: MessageID {
    switch self {
    case .explicitReduceUnsupported:
      return .init(domain: "InnoFlowMacro", id: "ExplicitReduceUnsupported")
    }
  }

  var severity: DiagnosticSeverity {
    .error
  }
}

enum InnoFlowMacroFixIt: FixItMessage {
  case replaceExplicitReduce

  var message: String {
    switch self {
    case .replaceExplicitReduce:
      return "replace explicit reduce with body-based reducer composition"
    }
  }

  var fixItID: MessageID {
    switch self {
    case .replaceExplicitReduce:
      return .init(domain: "InnoFlowMacro", id: "ReplaceExplicitReduce")
    }
  }
}
