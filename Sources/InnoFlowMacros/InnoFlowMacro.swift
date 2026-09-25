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
      bodySignatureIssues(
        bodyProperty,
        hasOutput: hasNestedType(named: "Output", in: structDecl)
      ).isEmpty
    else {
      return []
    }

    let accessPrefix = synthesizedMemberAccessPrefix(
      from: structDecl.modifiers,
      declaration: structDecl,
      in: context
    )
    let effectReturnType =
      hasNestedType(named: "Output", in: structDecl)
      ? "ReducerEffect<Action, Output>"
      : "EffectTask<Action>"

    if isPhaseManaged(node: node) {
      // Mirrored by `diagnosePhaseManagedContractIssueIfNeeded` in the
      // ExtensionMacro pass.
      guard !hasPhaseManagedContractIssue(in: structDecl, bodyProperty: bodyProperty) else {
        return []
      }

      return [
        DeclSyntax(
          stringLiteral:
            """
            \(accessPrefix)func reduce(into state: inout State, action: Action) -> \(effectReturnType) {
              body.phaseMap(Self.phaseMap).reduce(into: &state, action: action)
            }
            """
        )
      ]
    }

    return [
      DeclSyntax(
        stringLiteral:
          """
          \(accessPrefix)func reduce(into state: inout State, action: Action) -> \(effectReturnType) {
            body.reduce(into: &state, action: action)
          }
          """
      )
    ]
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

    let signatureIssues = bodySignatureIssues(
      bodyProperty,
      hasOutput: hasNestedType(named: "Output", in: structDecl)
    )
    guard signatureIssues.isEmpty else {
      throw MacroError.invalidBodySignature(details: signatureIssues)
    }

    emitMacroEntryDiagnostics(for: structDecl, context: context)

    if diagnoseInvalidPhaseManagedArgumentIfNeeded(node: node, context: context) {
      return []
    }

    if diagnoseInvalidStrictPhaseTotalityArgumentIfNeeded(node: node, context: context) {
      return []
    }

    if isStrictPhaseTotality(node: node), !isPhaseManaged(node: node) {
      context.diagnose(
        Diagnostic(
          node: Syntax(node),
          message: StrictPhaseTotalityArgumentDiagnosticMessage.requiresPhaseManagement
        )
      )
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
      diagnosePhaseTotalityIfNeeded(
        in: structDecl,
        strict: isStrictPhaseTotality(node: node),
        context: context
      )
    }

    let extendedType = type.trimmedDescription
    let extensionDecl = try ExtensionDeclSyntax("extension \(raw: extendedType): Reducer {}")
    return [extensionDecl]
  }

  public static func expansion(
    of node: AttributeSyntax,
    attachedTo declaration: some DeclGroupSyntax,
    providingAttributesFor member: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [AttributeSyntax] {
    guard declaration.as(StructDeclSyntax.self) != nil,
      let nestedEnum = member.as(EnumDeclSyntax.self)
    else {
      return []
    }

    switch nestedEnum.name.text {
    case "Action":
      return ["@_InnoFlowActionPaths"]
    case "Output":
      return ["@_InnoFlowOutputPaths"]
    default:
      return []
    }
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

public struct InnoFlowOutputPathsMacro: MemberMacro {
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
    guard let outputEnum = declaration.as(EnumDeclSyntax.self) else {
      return []
    }

    return InnoFlowMacro.synthesizedOutputPathDeclarations(in: outputEnum, context: context)
  }
}

@main
struct InnoFlowMacrosPlugin: CompilerPlugin {
  let providingMacros: [any Macro.Type] = [
    InnoFlowMacro.self,
    InnoFlowActionPathsMacro.self,
    InnoFlowOutputPathsMacro.self,
    InnoFlowCasePathIgnoredMacro.self,
  ]
}
