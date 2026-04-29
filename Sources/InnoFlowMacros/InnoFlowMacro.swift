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
