// MARK: - InnoFlowMacro+ASTHelpers.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

extension InnoFlowMacro {
  /// Returns the explicit access required by a synthesized protocol witness or
  /// API member. Swift does not infer `public` or `package` for members emitted
  /// by an attached macro, even when the enclosing declaration has that access.
  static func synthesizedMemberAccessPrefix(
    from modifiers: DeclModifierListSyntax,
    declaration: some DeclGroupSyntax,
    in context: some MacroExpansionContext
  ) -> String {
    if let explicitPrefix = declaredAccessPrefix(from: modifiers) {
      return explicitPrefix
    }

    var lexicalContexts = context.lexicalContext[...]
    if let first = lexicalContexts.first,
      representsSameNominalDeclaration(first, as: declaration)
    {
      lexicalContexts = lexicalContexts.dropFirst()
    }

    guard let extensionDecl = lexicalContexts.first?.as(ExtensionDeclSyntax.self) else {
      return ""
    }
    return declaredAccessPrefix(from: extensionDecl.modifiers) ?? ""
  }

  private static func declaredAccessPrefix(
    from modifiers: DeclModifierListSyntax
  ) -> String? {
    for modifier in modifiers {
      switch modifier.name.tokenKind {
      case .keyword(.open), .keyword(.public):
        return "public "
      case .keyword(.package):
        return "package "
      case .keyword(.internal), .keyword(.fileprivate), .keyword(.private):
        return ""
      default:
        continue
      }
    }
    return nil
  }

  private static func representsSameNominalDeclaration(
    _ lexicalContext: Syntax,
    as declaration: some DeclGroupSyntax
  ) -> Bool {
    if let contextStruct = lexicalContext.as(StructDeclSyntax.self),
      let declarationStruct = declaration.as(StructDeclSyntax.self)
    {
      return logicalIdentifier(contextStruct.name) == logicalIdentifier(declarationStruct.name)
    }
    if let contextEnum = lexicalContext.as(EnumDeclSyntax.self),
      let declarationEnum = declaration.as(EnumDeclSyntax.self)
    {
      return logicalIdentifier(contextEnum.name) == logicalIdentifier(declarationEnum.name)
    }
    return false
  }

  static func emitMacroEntryDiagnostics(
    for declaration: StructDeclSyntax,
    context: some MacroExpansionContext
  ) {
    emitTypealiasInfoDiagnostics(in: declaration, context: context)
    diagnoseMissingBindableFieldSetters(in: declaration, context: context)
    diagnoseDirectBindablePropertyUses(in: declaration, context: context)
  }

  static func hasNestedType(named typeName: String, in declaration: StructDeclSyntax) -> Bool {
    declaration.memberBlock.members.contains { member in
      if let enumDecl = member.decl.as(EnumDeclSyntax.self) {
        return logicalIdentifier(enumDecl.name) == typeName
      }
      if let structDecl = member.decl.as(StructDeclSyntax.self) {
        return logicalIdentifier(structDecl.name) == typeName
      }
      if let classDecl = member.decl.as(ClassDeclSyntax.self) {
        return logicalIdentifier(classDecl.name) == typeName
      }
      if let typealiasDecl = member.decl.as(TypeAliasDeclSyntax.self) {
        return logicalIdentifier(typealiasDecl.name) == typeName
      }
      return false
    }
  }

  static func findNestedEnum(named typeName: String, in declaration: StructDeclSyntax)
    -> EnumDeclSyntax?
  {
    declaration.memberBlock.members
      .compactMap { $0.decl.as(EnumDeclSyntax.self) }
      .first(where: { logicalIdentifier($0.name) == typeName })
  }

  static func findNestedStruct(named typeName: String, in declaration: StructDeclSyntax)
    -> StructDeclSyntax?
  {
    declaration.memberBlock.members
      .compactMap { $0.decl.as(StructDeclSyntax.self) }
      .first(where: { logicalIdentifier($0.name) == typeName })
  }

  static func findReduceFunction(in declaration: StructDeclSyntax) -> FunctionDeclSyntax? {
    declaration.memberBlock.members
      .compactMap { $0.decl.as(FunctionDeclSyntax.self) }
      .first { function in
        guard logicalIdentifier(function.name) == "reduce" else { return false }
        let parameters = Array(function.signature.parameterClause.parameters)
        guard parameters.count == 2 else { return false }
        guard logicalIdentifier(parameters[0].firstName) == "into",
          logicalIdentifier(parameters[1].firstName) == "action"
        else {
          return false
        }
        return true
      }
  }

  static func findBodyProperty(in declaration: StructDeclSyntax) -> VariableDeclSyntax? {
    declaration.memberBlock.members
      .compactMap { $0.decl.as(VariableDeclSyntax.self) }
      .first { variable in
        variable.bindings.contains { binding in
          binding.pattern.as(IdentifierPatternSyntax.self).map { logicalIdentifier($0.identifier) }
            == "body"
        }
      }
  }
}

enum MacroError: Error, CustomStringConvertible {
  case notAStruct
  case missingState
  case missingAction
  case missingBodyProperty
  case explicitReduceUnsupported
  case invalidBodySignature(details: [String])

  var description: String {
    switch self {
    case .notAStruct:
      return "@InnoFlow can only be applied to structs"
    case .missingState:
      return "@InnoFlow requires a nested 'State' type"
    case .missingAction:
      return "@InnoFlow requires a nested 'Action' type"
    case .missingBodyProperty:
      return
        "@InnoFlow requires `var body: some Reducer<State, Action, Output>`; use `Never` when no output is emitted"
    case .explicitReduceUnsupported:
      return
        "@InnoFlow no longer supports explicit `reduce(into:action:)` authoring; declare `var body: some Reducer<State, Action, Output>` instead (`Never` when no output is emitted)"
    case .invalidBodySignature(let details):
      let joinedDetails = details.joined(separator: "; ")
      return """
        Invalid body signature for @InnoFlow.
        Expected:
        var body: some Reducer<State, Action, Output>
        Detected issues: \(joinedDetails).
        Remediation: expose reducer composition from `body` using `Reduce`, `CombineReducers`, and `Scope`.
        """
    }
  }
}
