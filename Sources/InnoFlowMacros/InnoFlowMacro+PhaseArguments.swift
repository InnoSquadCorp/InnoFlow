// MARK: - InnoFlowMacro+PhaseArguments.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

extension InnoFlowMacro {
  /// Returns `true` when the `@InnoFlow` attribute carries
  /// `phaseManaged: true`. The argument turns the macro into the
  /// phase-managed form, where the synthesized `reduce(into:action:)`
  /// automatically wraps the declared `body` in `.phaseMap(Self.phaseMap)`.
  ///
  /// A non-literal expression silently evaluates to `false` here so the
  /// MemberMacro pass mirrors the silent fallthrough that the ExtensionMacro
  /// pass diagnoses canonically via `diagnoseInvalidPhaseManagedArgumentIfNeeded`.
  static func isPhaseManaged(node: AttributeSyntax) -> Bool {
    booleanLiteralArgument(named: "phaseManaged", in: node) == true
  }

  static func isStrictPhaseTotality(node: AttributeSyntax) -> Bool {
    booleanLiteralArgument(named: "strictPhaseTotality", in: node) == true
  }

  private static func booleanLiteralArgument(
    named name: String,
    in node: AttributeSyntax
  ) -> Bool? {
    guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else {
      return nil
    }
    for argument in arguments where argument.label?.text == name {
      if let boolLiteral = argument.expression.as(BooleanLiteralExprSyntax.self) {
        return boolLiteral.literal.text == "true"
      }
    }
    return nil
  }

  /// Emits an error diagnostic when `phaseManaged:` is present but not a
  /// boolean literal. Returns `true` if a diagnostic was emitted so callers
  /// can stop further expansion. Without this, an expression like
  /// `phaseManaged: someFlag` silently disables phase management at
  /// compile time and the resulting reducer never wraps `.phaseMap(...)`
  /// even though the author plainly intended it to.
  static func diagnoseInvalidPhaseManagedArgumentIfNeeded(
    node: AttributeSyntax,
    context: some MacroExpansionContext
  ) -> Bool {
    guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else {
      return false
    }
    for argument in arguments where argument.label?.text == "phaseManaged" {
      if argument.expression.as(BooleanLiteralExprSyntax.self) == nil {
        context.diagnose(
          Diagnostic(
            node: Syntax(argument.expression),
            message: InvalidPhaseManagedArgumentDiagnosticMessage.nonLiteral
          )
        )
        return true
      }
    }
    return false
  }

  static func diagnoseInvalidStrictPhaseTotalityArgumentIfNeeded(
    node: AttributeSyntax,
    context: some MacroExpansionContext
  ) -> Bool {
    guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else {
      return false
    }
    for argument in arguments where argument.label?.text == "strictPhaseTotality" {
      if argument.expression.as(BooleanLiteralExprSyntax.self) == nil {
        context.diagnose(
          Diagnostic(
            node: Syntax(argument.expression),
            message: StrictPhaseTotalityArgumentDiagnosticMessage.nonLiteral
          )
        )
        return true
      }
    }
    return false
  }
}

enum InvalidPhaseManagedArgumentDiagnosticMessage: DiagnosticMessage {
  case nonLiteral

  var message: String {
    switch self {
    case .nonLiteral:
      return
        "@InnoFlow(phaseManaged:) requires a boolean literal (`true` or `false`); non-literal expressions are rejected because they cannot be evaluated at macro-expansion time and would silently disable phase management"
    }
  }

  var diagnosticID: MessageID {
    .init(domain: "InnoFlowMacro", id: "PhaseManagedArgumentMustBeLiteral")
  }

  var severity: DiagnosticSeverity {
    .error
  }
}

enum StrictPhaseTotalityArgumentDiagnosticMessage: DiagnosticMessage {
  case nonLiteral
  case requiresPhaseManagement

  var message: String {
    switch self {
    case .nonLiteral:
      return
        "@InnoFlow(strictPhaseTotality:) requires a boolean literal (`true` or `false`) so declaration completeness can be decided at macro-expansion time"
    case .requiresPhaseManagement:
      return
        "@InnoFlow(strictPhaseTotality: true) requires `phaseManaged: true` because strict totality validates the static PhaseMap owned by the macro"
    }
  }

  var diagnosticID: MessageID {
    switch self {
    case .nonLiteral:
      return .init(domain: "InnoFlowMacro", id: "StrictPhaseTotalityMustBeLiteral")
    case .requiresPhaseManagement:
      return .init(domain: "InnoFlowMacro", id: "StrictPhaseTotalityRequiresPhaseManagement")
    }
  }

  var severity: DiagnosticSeverity {
    .error
  }
}
