// MARK: - InnoFlowMacro.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// MARK: - InnoFlow Macro Implementation

public struct InnoFlowMacro: ExtensionMacro {

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

    guard let reduceFunction = findReduceFunction(in: structDecl) else {
      throw MacroError.missingReduceMethod
    }

    let signatureIssues = reducerSignatureIssues(reduceFunction)
    guard signatureIssues.isEmpty else {
      throw MacroError.invalidReduceSignature(details: signatureIssues)
    }

    let typeName = structDecl.name.text
    let extensionDecl = try ExtensionDeclSyntax("extension \(raw: typeName): Reducer {}")
    return [extensionDecl]
  }

  private static func hasNestedType(named typeName: String, in declaration: StructDeclSyntax)
    -> Bool
  {
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

  private static func findReduceFunction(in declaration: StructDeclSyntax) -> FunctionDeclSyntax? {
    declaration.memberBlock.members
      .compactMap { $0.decl.as(FunctionDeclSyntax.self) }
      .first { $0.name.text == "reduce" }
  }

  private static func reducerSignatureIssues(_ function: FunctionDeclSyntax) -> [String] {
    var issues: [String] = []
    let parameters = function.signature.parameterClause.parameters
    if parameters.count != 2 {
      issues.append(
        "parameter count is \(parameters.count), expected 2 parameters (`into`, `action`)")
    }

    if !parameters.isEmpty {
      let first = parameters[parameters.startIndex]
      if first.firstName.text != "into" {
        issues.append("first parameter label is `\(first.firstName.text)`, expected `into`")
      }
      if !hasInoutSpecifier(in: first.type) {
        issues.append("`into` parameter must be declared as `inout`")
      }
    } else {
      issues.append("missing first parameter `into state: inout State`")
    }

    if parameters.count >= 2 {
      let second = parameters[parameters.index(after: parameters.startIndex)]
      if second.firstName.text != "action" {
        issues.append("second parameter label is `\(second.firstName.text)`, expected `action`")
      }
    } else {
      issues.append("missing second parameter `action: Action`")
    }

    return issues
  }

  private static func hasInoutSpecifier(in parameterType: TypeSyntax) -> Bool {
    guard let attributedType = parameterType.as(AttributedTypeSyntax.self) else {
      return false
    }

    if attributedType.specifiers.contains(where: isInoutSpecifier) {
      return true
    }

    return attributedType.lateSpecifiers.contains(where: isInoutSpecifier)
  }

  private static func isInoutSpecifier(_ element: TypeSpecifierListSyntax.Element) -> Bool {
    guard let simpleSpecifier = element.as(SimpleTypeSpecifierSyntax.self) else {
      return false
    }
    return simpleSpecifier.specifier.tokenKind == .keyword(.inout)
  }
}

// MARK: - Errors

enum MacroError: Error, CustomStringConvertible {
  case notAStruct
  case missingState
  case missingAction
  case missingReduceMethod
  case invalidReduceSignature(details: [String])

  var description: String {
    switch self {
    case .notAStruct:
      return "@InnoFlow can only be applied to structs"
    case .missingState:
      return "@InnoFlow requires a nested 'State' type"
    case .missingAction:
      return "@InnoFlow requires a nested 'Action' type"
    case .missingReduceMethod:
      return "@InnoFlow requires reduce(into:action:)"
    case .invalidReduceSignature(let details):
      let joinedDetails = details.joined(separator: "; ")
      return """
        Invalid reducer signature for @InnoFlow.
        Expected:
        func reduce(into state: inout State, action: Action) -> EffectTask<Action>
        Detected issues: \(joinedDetails).
        Remediation: use exactly two parameters labeled `into` and `action`, and mark the first parameter `inout`.
        """
    }
  }
}

// MARK: - Plugin Registration

@main
struct InnoFlowMacrosPlugin: CompilerPlugin {
  let providingMacros: [Macro.Type] = [
    InnoFlowMacro.self,
    BindableFieldMacro.self,
  ]
}

// MARK: - BindableField Macro Implementation

/// A macro that wraps state properties in `BindableProperty`.
public struct BindableFieldMacro: PeerMacro, AccessorMacro {

  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    guard let varDecl = declaration.as(VariableDeclSyntax.self) else {
      return []
    }

    guard let binding = varDecl.bindings.first,
      let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
    else {
      return []
    }

    let typeAnnotation = binding.typeAnnotation?.type
    let initializer = binding.initializer?.value

    let valueType: String
    let initializerValue: String

    if let typeAnnotation {
      valueType = typeAnnotation.trimmedDescription
      if let initializer {
        initializerValue = "BindableProperty(\(initializer.trimmedDescription))"
      } else {
        initializerValue = "BindableProperty<\(valueType)>(wrappedValue: \(valueType)())"
      }
    } else if let initializer {
      initializerValue = "BindableProperty(\(initializer.trimmedDescription))"
      valueType = ""
    } else {
      return []
    }

    let storageName = "_\(identifier)_storage"

    let finalDecl: DeclSyntax
    if !valueType.isEmpty {
      finalDecl = DeclSyntax(
        """
        private var \(raw: storageName): BindableProperty<\(raw: valueType)> = \(raw: initializerValue)
        """
      )
    } else {
      finalDecl = DeclSyntax(
        """
        private var \(raw: storageName) = \(raw: initializerValue)
        """
      )
    }

    return [finalDecl]
  }

  public static func expansion(
    of node: AttributeSyntax,
    providingAccessorsOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [AccessorDeclSyntax] {
    guard let varDecl = declaration.as(VariableDeclSyntax.self) else {
      return []
    }

    guard let binding = varDecl.bindings.first,
      let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
    else {
      return []
    }

    let storageName = "_\(identifier)_storage"

    let getter = AccessorDeclSyntax(
      """
      get {
          \(raw: storageName).value
      }
      """
    )

    let setter = AccessorDeclSyntax(
      """
      set {
          \(raw: storageName) = BindableProperty(newValue)
      }
      """
    )

    return [getter, setter]
  }
}
