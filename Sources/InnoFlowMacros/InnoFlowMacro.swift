// MARK: - InnoFlowMacro.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct InnoFlowMacro: ExtensionMacro, MemberAttributeMacro, MemberMacro {

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
    guard let structDecl = declaration.as(StructDeclSyntax.self) else {
      return []
    }

    guard hasNestedType(named: "State", in: structDecl),
      hasNestedType(named: "Action", in: structDecl)
    else {
      return []
    }

    guard findReduceFunction(in: structDecl) == nil,
      let bodyProperty = findBodyProperty(in: structDecl),
      bodySignatureIssues(bodyProperty).isEmpty
    else {
      return []
    }

    if isPhaseManaged(node: node) {
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

@main
struct InnoFlowMacrosPlugin: CompilerPlugin {
  let providingMacros: [Macro.Type] = [
    InnoFlowMacro.self,
    InnoFlowActionPathsMacro.self,
  ]
}
