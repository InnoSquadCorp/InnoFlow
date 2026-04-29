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
      let replacement = bodyReplacement(for: reduceFunction)
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

    let renderedStatements = indentCodeBlockItems(body.statements, spaces: 8)
    return try? VariableDeclSyntax(
      """
      var body: some Reducer<State, Action> {
          Reduce { state, action in
      \(raw: renderedStatements)
          }
      }
      """
    )
  }

  private static func indentCodeBlockItems(
    _ items: CodeBlockItemListSyntax,
    spaces: Int
  ) -> String {
    let prefix = String(repeating: " ", count: spaces)

    return items.map { item in
      item.description
        .trimmingCharacters(in: .newlines)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { line in
          let lineText = String(line)
          if lineText.trimmingCharacters(in: .whitespaces).isEmpty {
            return prefix
          }

          let leadingWhitespace = String(lineText.prefix { $0.isWhitespace })
          let normalizedLeadingWhitespace = leadingWhitespace.replacingOccurrences(
            of: "\t",
            with: String(repeating: " ", count: 4)
          )
          let content = String(lineText.dropFirst(leadingWhitespace.count))
          return prefix + normalizedLeadingWhitespace + content
        }
        .joined(separator: "\n")
    }
    .joined(separator: "\n")
  }
}

enum InnoFlowMacroMessage: DiagnosticMessage {
  case explicitReduceUnsupported

  var message: String {
    switch self {
    case .explicitReduceUnsupported:
      return
        "@InnoFlow no longer supports explicit `reduce(into:action:)` authoring; declare `var body: some Reducer<State, Action>` instead"
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
