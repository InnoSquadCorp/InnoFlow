// MARK: - InnoFlowMacro+ASTHelpers.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

extension InnoFlowMacro {
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
        return enumDecl.name.text == typeName
      }
      if let structDecl = member.decl.as(StructDeclSyntax.self) {
        return structDecl.name.text == typeName
      }
      if let classDecl = member.decl.as(ClassDeclSyntax.self) {
        return classDecl.name.text == typeName
      }
      if let typealiasDecl = member.decl.as(TypeAliasDeclSyntax.self) {
        return typealiasDecl.name.text == typeName
      }
      return false
    }
  }

  static func findNestedEnum(named typeName: String, in declaration: StructDeclSyntax)
    -> EnumDeclSyntax?
  {
    declaration.memberBlock.members
      .compactMap { $0.decl.as(EnumDeclSyntax.self) }
      .first(where: { $0.name.text == typeName })
  }

  static func findNestedStruct(named typeName: String, in declaration: StructDeclSyntax)
    -> StructDeclSyntax?
  {
    declaration.memberBlock.members
      .compactMap { $0.decl.as(StructDeclSyntax.self) }
      .first(where: { $0.name.text == typeName })
  }

  static func findReduceFunction(in declaration: StructDeclSyntax) -> FunctionDeclSyntax? {
    declaration.memberBlock.members
      .compactMap { $0.decl.as(FunctionDeclSyntax.self) }
      .first { function in
        guard function.name.text == "reduce" else { return false }
        let parameters = Array(function.signature.parameterClause.parameters)
        guard parameters.count == 2 else { return false }
        guard parameters[0].firstName.text == "into",
          parameters[1].firstName.text == "action"
        else {
          return false
        }
        return function.signature.returnClause?.type.trimmedDescription == "EffectTask<Action>"
      }
  }

  static func findBodyProperty(in declaration: StructDeclSyntax) -> VariableDeclSyntax? {
    declaration.memberBlock.members
      .compactMap { $0.decl.as(VariableDeclSyntax.self) }
      .first { variable in
        variable.bindings.contains { binding in
          binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "body"
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
      return "@InnoFlow requires `var body: some Reducer<State, Action>`"
    case .explicitReduceUnsupported:
      return
        "@InnoFlow no longer supports explicit `reduce(into:action:)` authoring; declare `var body: some Reducer<State, Action>` instead"
    case .invalidBodySignature(let details):
      let joinedDetails = details.joined(separator: "; ")
      return """
        Invalid body signature for @InnoFlow.
        Expected:
        var body: some Reducer<State, Action>
        Detected issues: \(joinedDetails).
        Remediation: expose reducer composition from `body` using `Reduce`, `CombineReducers`, and `Scope`.
        """
    }
  }
}
