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
    // Attached macros cannot resolve the semantic type of an existing member.
    // Treat the canonical static variable name as the author's explicit
    // manual-path signal so aliases and factory-built paths remain supported;
    // normal Swift type checking still validates consumers of that member.
    let existingNames = outputExistingMemberNames(in: actionEnum)
    let manualPathNames = outputManualPathNames(in: actionEnum)
    var seenGeneratedNames = OutputNameTable()

    // Action and Output cases share one traversal, so a case inside `#if`,
    // a case carrying `@available`, `@InnoFlowCasePathIgnored`, and a manual
    // path mean the same thing for both enums.
    return synthesizedConditionalCasePathSources(
      in: actionEnum.memberBlock.members,
      conditionalContext: .init()
    ) { site in
      synthesizedActionElementSources(
        at: site,
        accessPrefix: accessPrefix,
        requiresComputedProperty: requiresComputedProperty,
        existingNames: existingNames,
        manualPathNames: manualPathNames,
        seenGeneratedNames: &seenGeneratedNames,
        context: context
      )
    }.map(DeclSyntax.init(stringLiteral:))
  }

  /// The payload shapes `Action` path synthesis distinguishes.
  private enum ActionPathShape {
    /// `case child(ChildAction)` or `case child(_ action: ChildAction)`.
    case singlePayload(EnumCaseParameterSyntax)
    /// `case todo(id: ID, action: ChildAction)`.
    case collection(id: EnumCaseParameterSyntax, action: EnumCaseParameterSyntax)
    /// `case child(label: ChildAction)`; no path is synthesized.
    case labeledPayload(label: String)
    /// Any other multi-payload case; no path is synthesized.
    case multiplePayloads
  }

  private static func actionPathShape(of element: EnumCaseElementSyntax) -> ActionPathShape? {
    guard let parameters = element.parameterClause?.parameters, !parameters.isEmpty else {
      return nil
    }

    if parameters.count == 1, let parameter = parameters.first {
      // `_ name: Payload` declares a local documentation name only; the case
      // is still constructed and matched without an argument label.
      guard let label = parameter.firstName, label.text != "_" else {
        return .singlePayload(parameter)
      }
      return .labeledPayload(label: label.text)
    }

    if parameters.count == 2,
      let idParameter = parameters.first,
      let actionParameter = parameters.last,
      idParameter.firstName.map(logicalIdentifier) == "id",
      actionParameter.firstName.map(logicalIdentifier) == "action"
    {
      return .collection(id: idParameter, action: actionParameter)
    }

    return .multiplePayloads
  }

  private static func synthesizedActionElementSources(
    at site: CasePathElementSite,
    accessPrefix: String,
    requiresComputedProperty: Bool,
    existingNames: OutputNameTable,
    manualPathNames: OutputNameTable,
    seenGeneratedNames: inout OutputNameTable,
    context: some MacroExpansionContext
  ) -> [String] {
    let element = site.element
    guard let shape = actionPathShape(of: element) else { return [] }

    let caseName = logicalIdentifier(element.name)
    let caseSource = identifierSource(element.name)
    let actionPathBaseName = generatedPathBaseName(from: element.name)
    let memberName: String
    if case .collection = shape {
      memberName = "\(actionPathBaseName)ActionPath"
    } else {
      memberName = "\(actionPathBaseName)CasePath"
    }

    // A canonical manual path takes precedence for every shape, exactly as
    // it does for `Output`: it stands in for a shape the macro cannot
    // synthesize and replaces the path of one it can. Synthesis continues
    // only under the compiler conditions the manual declaration leaves open.
    let manualContexts = manualPathNames.contexts(
      memberName,
      overlapping: site.conditionalContext
    )
    guard let scope = casePathGenerationScope(at: site, manualContexts: manualContexts) else {
      return []
    }

    let pathDeclaration: (type: String, embed: String, extract: String)
    switch shape {
    case .labeledPayload(let label):
      context.diagnose(
        Diagnostic(
          node: Syntax(element.name),
          message: InnoFlowActionPathsMessage.labeledPayloadNote(
            caseName: caseName,
            label: label,
            actionPathBaseName: actionPathBaseName
          )
        )
      )
      return []

    case .multiplePayloads:
      context.diagnose(
        Diagnostic(
          node: Syntax(element.name),
          message: InnoFlowActionPathsMessage.multiPayloadNote(
            caseName: caseName,
            actionPathBaseName: actionPathBaseName
          )
        )
      )
      return []

    case .singlePayload(let parameter):
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
      let childActionType = parameter.type.trimmedDescription
      pathDeclaration = (
        type: "CasePath<Self, \(childActionType)>",
        embed: """
        embed: { childAction in
          .\(caseSource)(childAction)
        },
        """,
        extract: """
        extract: { action in
          guard case .\(caseSource)(let childAction) = action else { return nil }
          return childAction
        }
        """
      )

    case .collection(let idParameter, let actionParameter):
      let idType = idParameter.type.trimmedDescription
      let childActionType = actionParameter.type.trimmedDescription
      pathDeclaration = (
        type: "CollectionActionPath<Self, \(idType), \(childActionType)>",
        embed: """
        embed: { id, action in
          .\(caseSource)(id: id, action: action)
        },
        """,
        extract: """
        extract: { action in
          guard case let .\(caseSource)(id, childAction) = action else { return nil }
          return (id, childAction)
        }
        """
      )
    }

    guard
      reserveGeneratedCasePathName(
        memberName,
        for: element,
        in: scope.generationContext,
        existingNames: existingNames,
        manualPathNames: manualPathNames,
        seenGeneratedNames: &seenGeneratedNames
      )
    else {
      context.diagnose(
        Diagnostic(
          node: Syntax(element.name),
          message: InnoFlowActionPathsMessage.leadingUnderscoreCollision(memberName: memberName)
        )
      )
      return []
    }

    func indented(_ source: String, by width: Int) -> String {
      let padding = String(repeating: " ", count: width)
      return source.split(separator: "\n", omittingEmptySubsequences: false)
        .map { padding + $0 }
        .joined(separator: "\n")
    }

    if requiresComputedProperty {
      let markerName = generatedActionPathIdentityMarkerName(
        for: memberName,
        conditionalContext: scope.generationContext,
        existingNames: existingNames,
        seenGeneratedNames: &seenGeneratedNames
      )
      let declaration =
        """
        \(accessPrefix)static var \(generatedIdentifierSource(memberName)): \(pathDeclaration.type) {
          \(pathDeclaration.type)._innoFlowGenerated(
            marker: \(generatedIdentifierSource(markerName)).self,
        \(indented(pathDeclaration.embed, by: 4))
        \(indented(pathDeclaration.extract, by: 4))
          )
        }
        """
      return scope.wrapping([
        "private enum \(generatedIdentifierSource(markerName)) {}",
        site.availabilityPrefix + declaration,
      ])
    }

    let declaration =
      """
      \(accessPrefix)static let \(generatedIdentifierSource(memberName)) = \(pathDeclaration.type)(
      \(indented(pathDeclaration.embed, by: 2))
      \(indented(pathDeclaration.extract, by: 2))
      )
      """
    return scope.wrapping([site.availabilityPrefix + declaration])
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

  private static func generatedActionPathIdentityMarkerName(
    for memberName: String,
    conditionalContext: OutputConditionalContext,
    existingNames: OutputNameTable,
    seenGeneratedNames: inout OutputNameTable
  ) -> String {
    var markerName = "__InnoFlowGeneratedActionPathIdentity_\(memberName)"
    while existingNames.contains(markerName, overlapping: conditionalContext)
      || seenGeneratedNames.contains(markerName, overlapping: conditionalContext)
    {
      markerName.append("_")
    }
    seenGeneratedNames.insert(markerName, context: conditionalContext)
    return markerName
  }
}

enum InnoFlowActionPathsMessage: DiagnosticMessage {
  case leadingUnderscoreCollision(memberName: String)
  case optionalPayloadNote(caseName: String)
  case labeledPayloadNote(caseName: String, label: String, actionPathBaseName: String)
  case multiPayloadNote(caseName: String, actionPathBaseName: String)

  var message: String {
    switch self {
    case .leadingUnderscoreCollision(let memberName):
      return
        "generated action path `\(memberName)` collides with another generated action path or existing static member; declare an explicit static alias or rename the case"
    case .optionalPayloadNote(let caseName):
      return
        "case `\(caseName)` has an optional payload; CasePath is still synthesized but `.\(caseName)(nil)` extracts as `.some(nil)`, which is rarely intended. Why: `CasePath.extract` already wraps the payload in an outer optional, so an inner optional collapses ambiguously. Fix: split into two cases (e.g. `.\(caseName)(value)` + `.\(caseName)Cleared`) or declare a custom CasePath that flattens the inner optional"
    case .labeledPayloadNote(let caseName, let label, let actionPathBaseName):
      return
        "case `\(caseName)` has a labeled payload (`\(label):`); no CasePath is synthesized for this case. Why: CasePath auto-synthesis only handles the canonical unlabeled single-payload shape so the embed/extract closures remain unambiguous. Fix: drop the label, declare `static let \(InnoFlowMacro.generatedIdentifierSource("\(actionPathBaseName)CasePath")) = CasePath<Self, …>(embed:extract:)` manually, or add `@InnoFlowCasePathIgnored` when no path is needed"
    case .multiPayloadNote(let caseName, let actionPathBaseName):
      return
        "case `\(caseName)` has multiple payload parameters; no CasePath is synthesized. Why: CasePath auto-synthesis only handles unlabeled single payloads and `id:action:` collection routes. Fix: collapse the payload into a single struct/tuple, declare `static let \(InnoFlowMacro.generatedIdentifierSource("\(actionPathBaseName)CasePath")) = CasePath<Self, …>(embed:extract:)` manually, or add `@InnoFlowCasePathIgnored` when no path is needed"
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
