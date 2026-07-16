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
    let accessPrefix = synthesizedMemberAccessPrefix(
      from: actionEnum.modifiers,
      declaration: actionEnum,
      in: context
    )
    let requiresComputedProperty = actionPathRequiresComputedProperty(
      actionEnum: actionEnum,
      context: context
    )
    let existingNames = Set(
      actionEnum.memberBlock.members.flatMap { member -> [String] in
        if let enumCaseDecl = member.decl.as(EnumCaseDeclSyntax.self) {
          return enumCaseDecl.elements.map { $0.name.text }
        }

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

        if let enumDecl = member.decl.as(EnumDeclSyntax.self) {
          return [enumDecl.name.text]
        }
        if let structDecl = member.decl.as(StructDeclSyntax.self) {
          return [structDecl.name.text]
        }
        if let classDecl = member.decl.as(ClassDeclSyntax.self) {
          return [classDecl.name.text]
        }
        if let actorDecl = member.decl.as(ActorDeclSyntax.self) {
          return [actorDecl.name.text]
        }
        if let protocolDecl = member.decl.as(ProtocolDeclSyntax.self) {
          return [protocolDecl.name.text]
        }
        if let typeAliasDecl = member.decl.as(TypeAliasDeclSyntax.self) {
          return [typeAliasDecl.name.text]
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
            accessPrefix: accessPrefix,
            requiresComputedProperty: requiresComputedProperty,
            existingNames: existingNames,
            seenGeneratedNames: &seenGeneratedNames,
            context: context
          )
        else {
          continue
        }
        for declaration in member.declarations {
          declarations.append(DeclSyntax(stringLiteral: declaration))
        }
      }
    }

    return declarations
  }

  private static func synthesizedActionPathMember(
    for element: EnumCaseElementSyntax,
    accessPrefix: String,
    requiresComputedProperty: Bool,
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
      if requiresComputedProperty {
        let markerName = generatedActionPathIdentityMarkerName(
          for: memberName,
          existingNames: existingNames,
          seenGeneratedNames: &seenGeneratedNames
        )
        return .init(
          declarations: [
            "private enum \(markerName) {}",
            """
            \(accessPrefix)static var \(memberName): CasePath<Self, \(childActionType)> {
              CasePath<Self, \(childActionType)>._innoFlowGenerated(
                marker: \(markerName).self,
                embed: { childAction in
                  .\(caseName)(childAction)
                },
                extract: { action in
                  guard case .\(caseName)(let childAction) = action else { return nil }
                  return childAction
                }
              )
            }
            """,
          ]
        )
      }
      return .init(
        declarations: [
          """
          \(accessPrefix)static let \(memberName) = CasePath<Self, \(childActionType)>(
            embed: { childAction in
              .\(caseName)(childAction)
            },
            extract: { action in
              guard case .\(caseName)(let childAction) = action else { return nil }
              return childAction
            }
          )
          """
        ]
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
      if requiresComputedProperty {
        let markerName = generatedActionPathIdentityMarkerName(
          for: memberName,
          existingNames: existingNames,
          seenGeneratedNames: &seenGeneratedNames
        )
        return .init(
          declarations: [
            "private enum \(markerName) {}",
            """
            \(accessPrefix)static var \(memberName): CollectionActionPath<Self, \(idType), \(childActionType)> {
              CollectionActionPath<Self, \(idType), \(childActionType)>._innoFlowGenerated(
                marker: \(markerName).self,
                embed: { id, action in
                  .\(caseName)(id: id, action: action)
                },
                extract: { action in
                  guard case let .\(caseName)(id, childAction) = action else { return nil }
                  return (id, childAction)
                }
              )
            }
            """,
          ]
        )
      }
      return .init(
        declarations: [
          """
          \(accessPrefix)static let \(memberName) = CollectionActionPath<Self, \(idType), \(childActionType)>(
            embed: { id, action in
              .\(caseName)(id: id, action: action)
            },
            extract: { action in
              guard case let .\(caseName)(id, childAction) = action else { return nil }
              return (id, childAction)
            }
          )
          """
        ]
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

  private static func actionPathRequiresComputedProperty(
    actionEnum: EnumDeclSyntax,
    context: some MacroExpansionContext
  ) -> Bool {
    if actionEnum.genericParameterClause != nil {
      return true
    }

    return context.lexicalContext.contains { lexicalContext in
      // An extension's syntax does not reveal whether its extended nominal
      // type is generic. Nested declarations inherit that generic context, so
      // conservatively avoid stored properties in every extension context.
      if lexicalContext.is(ExtensionDeclSyntax.self) {
        return true
      }
      if let structDecl = lexicalContext.as(StructDeclSyntax.self) {
        return structDecl.genericParameterClause != nil
      }
      if let enumDecl = lexicalContext.as(EnumDeclSyntax.self) {
        return enumDecl.genericParameterClause != nil
      }
      if let classDecl = lexicalContext.as(ClassDeclSyntax.self) {
        return classDecl.genericParameterClause != nil
      }
      if let actorDecl = lexicalContext.as(ActorDeclSyntax.self) {
        return actorDecl.genericParameterClause != nil
      }
      return false
    }
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

  private static func generatedActionPathIdentityMarkerName(
    for memberName: String,
    existingNames: Set<String>,
    seenGeneratedNames: inout Set<String>
  ) -> String {
    var markerName = "__InnoFlowGeneratedActionPathIdentity_\(memberName)"
    while existingNames.contains(markerName) || seenGeneratedNames.contains(markerName) {
      markerName.append("_")
    }
    seenGeneratedNames.insert(markerName)
    return markerName
  }
}

private struct SynthesizedActionPathMember {
  let declarations: [String]
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
        "case `\(caseName)` has an optional payload; CasePath is still synthesized but `.\(caseName)(nil)` extracts as `.some(nil)`, which is rarely intended. Why: `CasePath.extract` already wraps the payload in an outer optional, so an inner optional collapses ambiguously. Fix: split into two cases (e.g. `.\(caseName)(value)` + `.\(caseName)Cleared`) or declare a custom CasePath that flattens the inner optional"
    case .labeledPayloadNote(let caseName, let label, let actionPathBaseName):
      return
        "case `\(caseName)` has a labeled payload (`\(label):`); no CasePath is synthesized for this case. Why: CasePath auto-synthesis only handles the canonical unlabeled single-payload shape so the embed/extract closures remain unambiguous. Fix: drop the label, or declare `static let \(actionPathBaseName)CasePath = CasePath<Self, …>(embed:extract:)` manually"
    case .multiPayloadNote(let caseName):
      return
        "case `\(caseName)` has multiple payload parameters; no CasePath is synthesized. Why: CasePath auto-synthesis only handles unlabeled single payloads and `id:action:` collection routes. Fix: collapse the payload into a single struct/tuple or declare a static path manually if you need routing"
    }
  }

  var diagnosticID: MessageID {
    // The note→warning elevation keeps the same diagnostic IDs so existing
    // suppression configurations (e.g. `-Wno-…`-style pragmas, downstream
    // CI rules) keep targeting the same diagnostic identity.
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
      // Elevated from `.note` so the diagnostic surfaces next to the
      // downstream "unresolved identifier 'Action.fooCasePath'" error
      // a user sees at the Scope/IfLet callsite. Without this, the
      // root cause (CasePath was not synthesized) was easy to miss.
      return .warning
    }
  }
}
