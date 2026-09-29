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
      hasBodyProperty: findBodyProperty(in: declaration) != nil
    )
    context.diagnose(diagnostic)
    return true
  }

  private static func explicitReduceDiagnostic(
    anchoredAt anchor: some SyntaxProtocol,
    reduceFunction: FunctionDeclSyntax,
    hasBodyProperty: Bool
  ) -> Diagnostic {
    let message = InnoFlowMacroMessage.explicitReduceUnsupported

    guard !hasBodyProperty,
      isCanonicalReduceFunction(reduceFunction),
      let replacement = bodyReplacement(for: reduceFunction)?
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
    guard function.name.text == "reduce",
      function.signature.effectSpecifiers == nil,
      let body = function.body,
      !body.statements.isEmpty
    else {
      return false
    }

    let parameters = Array(function.signature.parameterClause.parameters)
    guard parameters.count == 2 else { return false }
    guard isCanonicalIntoParameter(parameters[0]),
      isCanonicalActionParameter(parameters[1]),
      isCanonicalEffectTaskReturn(function.signature.returnClause?.type)
    else {
      return false
    }

    return true
  }

  private static func isCanonicalIntoParameter(_ parameter: FunctionParameterSyntax) -> Bool {
    guard parameter.firstName.text == "into",
      parameter.secondName?.text == "state"
    else {
      return false
    }

    return parameter.type.trimmedDescription == "inout State"
  }

  private static func isCanonicalActionParameter(_ parameter: FunctionParameterSyntax) -> Bool {
    guard parameter.firstName.text == "action",
      parameter.secondName == nil,
      let identifier = parameter.type.as(IdentifierTypeSyntax.self)
    else {
      return false
    }

    return identifier.name.text == "Action"
  }

  private static func isCanonicalEffectTaskReturn(_ type: TypeSyntax?) -> Bool {
    guard let identifier = type?.as(IdentifierTypeSyntax.self),
      identifier.name.text == "EffectTask",
      let genericArguments = identifier.genericArgumentClause
    else {
      return false
    }

    let arguments = Array(genericArguments.arguments)
    guard arguments.count == 1,
      let actionType = arguments[0].argument.as(IdentifierTypeSyntax.self)
    else {
      return false
    }

    return actionType.name.text == "Action"
  }

  private static func bodyReplacement(for function: FunctionDeclSyntax) -> VariableDeclSyntax? {
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
    return try? VariableDeclSyntax(
      """
      var body: some Reducer<State, Action, Never> {
      \(raw: reducerIndent)Reduce { state, action in
      \(raw: renderedStatements)
      \(raw: reducerIndent)}
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
  case explicitReduceUnsupported

  var message: String {
    switch self {
    case .explicitReduceUnsupported:
      return
        "@InnoFlow no longer supports explicit `reduce(into:action:)` authoring; declare `var body: some Reducer<State, Action, Output>` instead (`Never` when no output is emitted)"
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
