// MARK: - InnoFlowMacro.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import SwiftCompilerPlugin
import SwiftDiagnostics
public import SwiftSyntax
import SwiftSyntaxBuilder
public import SwiftSyntaxMacros

public struct InnoFlowMacro: ExtensionMacro, MemberAttributeMacro, MemberMacro {

  public static func expansion(
    of node: AttributeSyntax,
    providingMembersOf declaration: some DeclGroupSyntax,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    try expansion(of: node, providingMembersOf: declaration, in: context)
  }

  /// Synthesizes the `reduce(into:action:)` member.
  ///
  /// Silent `return []` branches here are intentional: the ExtensionMacro
  /// pass that runs against the same declaration owns the canonical
  /// diagnostics (`missingState`, `missingAction`, `missingBodyProperty`,
  /// `invalidBodySignature`, explicit `reduce` rejection, phase-managed
  /// contract issues). Re-emitting them here would produce duplicate
  /// diagnostics on the same source range and obscure the root cause.
  /// If you add a new failure shape, mirror it in the ExtensionMacro
  /// expansion below so the user still receives an actionable diagnostic.
  public static func expansion(
    of node: AttributeSyntax,
    providingMembersOf declaration: some DeclGroupSyntax,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    // Mirrored by ExtensionMacro's `.notAStruct` throw.
    guard let structDecl = declaration.as(StructDeclSyntax.self) else {
      return []
    }

    // Mirrored by ExtensionMacro's `.missingState` / `.missingAction` throws.
    guard hasNestedType(named: "State", in: structDecl),
      hasNestedType(named: "Action", in: structDecl)
    else {
      return []
    }

    // Mirrored by ExtensionMacro's explicit-reduce diagnostic and
    // `.missingBodyProperty` / `.invalidBodySignature` throws.
    guard findReduceFunction(in: structDecl) == nil,
      let bodyProperty = findBodyProperty(in: structDecl),
      bodySignatureIssues(bodyProperty).isEmpty
    else {
      return []
    }

    if isPhaseManaged(node: node) {
      // Mirrored by `diagnosePhaseManagedContractIssueIfNeeded` in the
      // ExtensionMacro pass.
      guard !hasPhaseManagedContractIssue(in: structDecl, bodyProperty: bodyProperty) else {
        return []
      }

      return [
        DeclSyntax(
          """
          func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
            body.phaseMap(Self.phaseMap).reduce(into: &state, action: action)
          }
          """
        )
      ]
    }

    return [
      DeclSyntax(
        """
        func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
          body.reduce(into: &state, action: action)
        }
        """
      )
    ]
  }

  /// Returns `true` when the `@InnoFlow` attribute carries
  /// `phaseManaged: true`. The argument turns the macro into the
  /// phase-managed form, where the synthesized `reduce(into:action:)`
  /// automatically wraps the declared `body` in `.phaseMap(Self.phaseMap)`.
  ///
  /// A non-literal expression silently evaluates to `false` here so the
  /// MemberMacro pass mirrors the silent fallthrough that the ExtensionMacro
  /// pass diagnoses canonically via `diagnoseInvalidPhaseManagedArgumentIfNeeded`.
  fileprivate static func isPhaseManaged(node: AttributeSyntax) -> Bool {
    guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else {
      return false
    }
    for argument in arguments where argument.label?.text == "phaseManaged" {
      if let boolLiteral = argument.expression.as(BooleanLiteralExprSyntax.self) {
        return boolLiteral.literal.text == "true"
      }
    }
    return false
  }

  /// Emits an error diagnostic when `phaseManaged:` is present but not a
  /// boolean literal. Returns `true` if a diagnostic was emitted so callers
  /// can stop further expansion. Without this, an expression like
  /// `phaseManaged: someFlag` silently disables phase management at
  /// compile time and the resulting reducer never wraps `.phaseMap(...)`
  /// even though the author plainly intended it to.
  fileprivate static func diagnoseInvalidPhaseManagedArgumentIfNeeded(
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

  public static func expansion(
    of node: AttributeSyntax,
    attachedTo declaration: some DeclGroupSyntax,
    providingExtensionsOf type: some TypeSyntaxProtocol,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [ExtensionDeclSyntax] {
    guard let structDecl = declaration.as(StructDeclSyntax.self) else {
      throw MacroError.notAStruct
    }

    guard hasNestedType(named: "State", in: structDecl) else {
      throw MacroError.missingState
    }

    guard hasNestedType(named: "Action", in: structDecl) else {
      throw MacroError.missingAction
    }

    if diagnoseExplicitReduceIfNeeded(
      in: structDecl,
      anchoredAt: node,
      context: context
    ) {
      return []
    }

    guard let bodyProperty = findBodyProperty(in: structDecl) else {
      throw MacroError.missingBodyProperty
    }

    let signatureIssues = bodySignatureIssues(bodyProperty)
    guard signatureIssues.isEmpty else {
      throw MacroError.invalidBodySignature(details: signatureIssues)
    }

    emitMacroEntryDiagnostics(for: structDecl, context: context)

    if diagnoseInvalidPhaseManagedArgumentIfNeeded(node: node, context: context) {
      return []
    }

    if isPhaseManaged(node: node) {
      guard
        !diagnosePhaseManagedContractIssueIfNeeded(
          in: structDecl,
          bodyProperty: bodyProperty,
          anchoredAt: node,
          context: context
        )
      else {
        return []
      }
      diagnosePhaseTotalityIfNeeded(in: structDecl, context: context)
    }

    let typeName = structDecl.name.text
    let extensionDecl = try ExtensionDeclSyntax("extension \(raw: typeName): Reducer {}")
    return [extensionDecl]
  }

  public static func expansion(
    of node: AttributeSyntax,
    attachedTo declaration: some DeclGroupSyntax,
    providingAttributesFor member: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [AttributeSyntax] {
    guard declaration.as(StructDeclSyntax.self) != nil,
      let actionEnum = member.as(EnumDeclSyntax.self),
      actionEnum.name.text == "Action"
    else {
      return []
    }

    return ["@_InnoFlowActionPaths"]
  }
}

public struct InnoFlowActionPathsMacro: MemberMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingMembersOf declaration: some DeclGroupSyntax,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    try expansion(of: node, providingMembersOf: declaration, in: context)
  }

  public static func expansion(
    of node: AttributeSyntax,
    providingMembersOf declaration: some DeclGroupSyntax,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    guard let actionEnum = declaration.as(EnumDeclSyntax.self) else {
      return []
    }

    return InnoFlowMacro.synthesizedActionPathDeclarations(in: actionEnum, context: context)
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

@main
struct InnoFlowMacrosPlugin: CompilerPlugin {
  let providingMacros: [any Macro.Type] = [
    InnoFlowMacro.self,
    InnoFlowActionPathsMacro.self,
  ]
}
