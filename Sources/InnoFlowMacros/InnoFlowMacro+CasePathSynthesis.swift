// MARK: - InnoFlowMacro+CasePathSynthesis.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

extension InnoFlowMacro {
  static func synthesizedActionPathDeclarations(
    in actionEnum: EnumDeclSyntax,
    context: some MacroExpansionContext
  ) -> [DeclSyntax] {
    let existingNames = Set(
      actionEnum.memberBlock.members.flatMap { member -> [String] in
        if let variableDecl = member.decl.as(VariableDeclSyntax.self) {
          guard variableDecl.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) })
          else {
            return []
          }
          return variableDecl.bindings.compactMap { binding in
            binding.pattern
              .as(IdentifierPatternSyntax.self)?
              .identifier
              .text
          }
        }

        if let functionDecl = member.decl.as(FunctionDeclSyntax.self) {
          guard functionDecl.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) })
          else {
            return []
          }
          return [functionDecl.name.text]
        }

        return []
      }
    )

    var seenGeneratedNames: Set<String> = []
    var declarations: [DeclSyntax] = []

    for enumCaseDecl in actionEnum.memberBlock.members.compactMap({
      $0.decl.as(EnumCaseDeclSyntax.self)
    }) {
      for element in enumCaseDecl.elements {
        guard
          let member = synthesizedActionPathMember(
            for: element,
            existingNames: existingNames,
            seenGeneratedNames: &seenGeneratedNames,
            context: context
          )
        else {
          continue
        }
        declarations.append(DeclSyntax(stringLiteral: member.declaration))
      }
    }

    return declarations
  }

  private static func synthesizedActionPathMember(
    for element: EnumCaseElementSyntax,
    existingNames: Set<String>,
    seenGeneratedNames: inout Set<String>,
    context: some MacroExpansionContext
  ) -> SynthesizedActionPathMember? {
    guard let parameters = element.parameterClause?.parameters else {
      return nil
    }

    let caseName = element.name.text

    if parameters.count == 1,
      let parameter = parameters.first,
      parameter.secondName == nil,
      parameter.firstName == nil || parameter.firstName?.text == "_"
    {
      // Optional payloads still synthesize a CasePath for backward
      // compatibility, but emit a note because the resulting `extract` returns
      // the outer extraction optional around the optional payload. `.case(nil)`
      // therefore extracts as `.some(nil)`, which is rarely what feature
      // authors intend.
      if isOptionalPayloadType(parameter.type) {
        context.diagnose(
          Diagnostic(
            node: Syntax(element.name),
            message: InnoFlowActionPathsMessage.optionalPayloadNote(caseName: caseName)
          )
        )
      }

      let memberName = "\(generatedActionPathBaseName(from: caseName))CasePath"
      guard
        diagnoseGeneratedActionPathCollisionIfNeeded(
          memberName: memberName,
          element: element,
          existingNames: existingNames,
          seenGeneratedNames: &seenGeneratedNames,
          context: context
        ) == false
      else {
        return nil
      }

      let childActionType = parameter.type.trimmedDescription
      return .init(
        declaration: """
          static let \(memberName) = CasePath<Self, \(childActionType)>(
            embed: { childAction in
              .\(caseName)(childAction)
            },
            extract: { action in
              guard case .\(caseName)(let childAction) = action else { return nil }
              return childAction
            }
          )
          """
      )
    }

    if parameters.count == 1,
      let parameter = parameters.first,
      let labelToken = parameter.firstName,
      labelToken.text != "_"
    {
      let actionPathBaseName = generatedActionPathBaseName(from: caseName)
      context.diagnose(
        Diagnostic(
          node: Syntax(element.name),
          message: InnoFlowActionPathsMessage.labeledPayloadNote(
            caseName: caseName,
            label: labelToken.text,
            actionPathBaseName: actionPathBaseName
          )
        )
      )
      return nil
    }

    if parameters.count == 2,
      let idParameter = parameters.first,
      let actionParameter = parameters.last,
      idParameter.firstName?.text == "id",
      actionParameter.firstName?.text == "action"
    {
      let memberName = "\(generatedActionPathBaseName(from: caseName))ActionPath"
      guard
        diagnoseGeneratedActionPathCollisionIfNeeded(
          memberName: memberName,
          element: element,
          existingNames: existingNames,
          seenGeneratedNames: &seenGeneratedNames,
          context: context
        ) == false
      else {
        return nil
      }

      let idType = idParameter.type.trimmedDescription
      let childActionType = actionParameter.type.trimmedDescription
      return .init(
        declaration: """
          static let \(memberName) = CollectionActionPath<Self, \(idType), \(childActionType)>(
            embed: { id, action in
              .\(caseName)(id: id, action: action)
            },
            extract: { action in
              guard case let .\(caseName)(id, childAction) = action else { return nil }
              return (id, childAction)
            }
          )
          """
      )
    }

    if parameters.count >= 2 {
      context.diagnose(
        Diagnostic(
          node: Syntax(element.name),
          message: InnoFlowActionPathsMessage.multiPayloadNote(caseName: caseName)
        )
      )
    }

    return nil
  }

  private static func isOptionalPayloadType(_ type: TypeSyntax) -> Bool {
    let trimmed = type.trimmed
    if trimmed.is(OptionalTypeSyntax.self)
      || trimmed.is(ImplicitlyUnwrappedOptionalTypeSyntax.self)
    {
      return true
    }

    let description = trimmed.description.trimmingCharacters(in: .whitespacesAndNewlines)
    return description.hasSuffix("?")
      || description.hasSuffix("!")
      || description.hasPrefix("Optional<")
      || description.contains(".Optional<")
  }

  private static func generatedActionPathBaseName(from caseName: String) -> String {
    if caseName.hasPrefix("_"), caseName.count > 1 {
      return String(caseName.dropFirst())
    }
    return caseName
  }

  private static func diagnoseGeneratedActionPathCollisionIfNeeded(
    memberName: String,
    element: EnumCaseElementSyntax,
    existingNames: Set<String>,
    seenGeneratedNames: inout Set<String>,
    context: some MacroExpansionContext
  ) -> Bool {
    let collides = existingNames.contains(memberName) || seenGeneratedNames.contains(memberName)
    if collides {
      context.diagnose(
        Diagnostic(
          node: Syntax(element.name),
          message: InnoFlowActionPathsMessage.leadingUnderscoreCollision
        )
      )
      return true
    }

    seenGeneratedNames.insert(memberName)
    return false
  }
}

private struct SynthesizedActionPathMember {
  let declaration: String
}

enum InnoFlowActionPathsMessage: DiagnosticMessage {
  case leadingUnderscoreCollision
  case optionalPayloadNote(caseName: String)
  case labeledPayloadNote(caseName: String, label: String, actionPathBaseName: String)
  case multiPayloadNote(caseName: String)

  var message: String {
    switch self {
    case .leadingUnderscoreCollision:
      return
        "generated action path name collides with another generated action path or existing static member; declare an explicit static alias or rename the case"
    case .optionalPayloadNote(let caseName):
      return
        "case `\(caseName)` has an optional payload; the synthesized CasePath still works but `.\(caseName)(nil)` extracts as `.some(nil)`; consider splitting into two cases or declaring a custom path"
    case .labeledPayloadNote(let caseName, let label, let actionPathBaseName):
      return
        "case `\(caseName)` has a labeled payload (`\(label):`); CasePath synthesis only handles unlabeled single payloads. Drop the label or declare a static `\(actionPathBaseName)CasePath` manually"
    case .multiPayloadNote(let caseName):
      return
        "case `\(caseName)` has multiple payload parameters; CasePath synthesis only handles unlabeled single payloads and `id:action:` collection routes. Declare a static path manually if you need one"
    }
  }

  var diagnosticID: MessageID {
    switch self {
    case .leadingUnderscoreCollision:
      return .init(domain: "InnoFlowMacro", id: "LeadingUnderscoreCollision")
    case .optionalPayloadNote:
      return .init(domain: "InnoFlowMacro", id: "OptionalPayloadActionPathNote")
    case .labeledPayloadNote:
      return .init(domain: "InnoFlowMacro", id: "LabeledPayloadActionPathNote")
    case .multiPayloadNote:
      return .init(domain: "InnoFlowMacro", id: "MultiPayloadActionPathNote")
    }
  }

  var severity: DiagnosticSeverity {
    switch self {
    case .leadingUnderscoreCollision:
      return .error
    case .optionalPayloadNote, .labeledPayloadNote, .multiPayloadNote:
      return .note
    }
  }
}
