// MARK: - InnoFlowMacro+PhaseTotalityDiagnostics.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

extension InnoFlowMacro {
  static func hasPhaseManagedContractIssue(
    in declaration: StructDeclSyntax,
    bodyProperty: VariableDeclSyntax
  ) -> Bool {
    phaseManagedContractIssue(in: declaration, bodyProperty: bodyProperty) != nil
  }

  static func diagnosePhaseManagedContractIssueIfNeeded(
    in declaration: StructDeclSyntax,
    bodyProperty: VariableDeclSyntax,
    anchoredAt anchor: some SyntaxProtocol,
    context: some MacroExpansionContext
  ) -> Bool {
    guard let issue = phaseManagedContractIssue(in: declaration, bodyProperty: bodyProperty) else {
      return false
    }

    context.diagnose(Diagnostic(node: anchor, message: issue))
    return true
  }

  /// Diagnoses Phase enum cases that are never referenced inside the static
  /// `phaseMap` declaration. Catches the typo / forgotten-rule class of
  /// errors at macro-expansion time instead of leaving them for opt-in
  /// `validationReport(...)` calls in tests.
  static func diagnosePhaseTotalityIfNeeded(
    in declaration: StructDeclSyntax,
    context: some MacroExpansionContext
  ) {
    guard let phaseEnum = findPhaseEnum(in: declaration) else {
      return
    }

    let phaseElements = phaseEnum.memberBlock.members
      .compactMap { $0.decl.as(EnumCaseDeclSyntax.self) }
      .flatMap { caseDecl in caseDecl.elements.map { $0 } }
    guard !phaseElements.isEmpty else {
      return
    }

    guard let phaseMapMember = findStaticPhaseMapVariable(in: declaration) else {
      return
    }

    let referencedNames = collectMemberAccessNames(in: phaseMapMember)

    for element in phaseElements where !referencedNames.contains(element.name.text) {
      context.diagnose(
        Diagnostic(
          node: Syntax(element.name),
          message: PhaseTotalityDiagnosticMessage.unreferencedCase(caseName: element.name.text)
        )
      )
    }
  }

  private static func phaseManagedContractIssue(
    in declaration: StructDeclSyntax,
    bodyProperty: VariableDeclSyntax
  ) -> PhaseManagedContractDiagnosticMessage? {
    guard findStaticPhaseMapVariable(in: declaration) != nil else {
      return .missingStaticPhaseMap
    }

    if collectMemberAccessNames(in: bodyProperty).contains("phaseMap") {
      return .bodyAlreadyAppliesPhaseMap
    }

    return nil
  }

  private static func findPhaseEnum(in declaration: StructDeclSyntax) -> EnumDeclSyntax? {
    if let phaseEnum = findNestedEnum(named: "Phase", in: declaration) {
      return phaseEnum
    }
    if let stateStruct = findNestedStruct(named: "State", in: declaration),
      let phaseEnum = findNestedEnumInDeclGroup(named: "Phase", in: stateStruct.memberBlock)
    {
      return phaseEnum
    }
    if let stateEnum = findNestedEnum(named: "State", in: declaration),
      let phaseEnum = findNestedEnumInDeclGroup(named: "Phase", in: stateEnum.memberBlock)
    {
      return phaseEnum
    }
    return nil
  }

  private static func findNestedEnumInDeclGroup(
    named typeName: String,
    in memberBlock: MemberBlockSyntax
  ) -> EnumDeclSyntax? {
    memberBlock.members
      .compactMap { $0.decl.as(EnumDeclSyntax.self) }
      .first(where: { $0.name.text == typeName })
  }

  private static func findStaticPhaseMapVariable(in declaration: StructDeclSyntax)
    -> VariableDeclSyntax?
  {
    declaration.memberBlock.members
      .compactMap { $0.decl.as(VariableDeclSyntax.self) }
      .first { variable in
        guard variable.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) })
        else { return false }
        return variable.bindings.contains { binding in
          binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "phaseMap"
        }
      }
  }

  private static func collectMemberAccessNames(in node: some SyntaxProtocol) -> Set<String> {
    let collector = MemberAccessNameCollector()
    collector.walk(node)
    return collector.names
  }
}

private final class MemberAccessNameCollector: SyntaxVisitor {
  var names: Set<String> = []

  init() {
    super.init(viewMode: .sourceAccurate)
  }

  override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
    names.insert(node.declName.baseName.text)
    return .visitChildren
  }
}

private enum PhaseManagedContractDiagnosticMessage: DiagnosticMessage {
  case missingStaticPhaseMap
  case bodyAlreadyAppliesPhaseMap

  var message: String {
    switch self {
    case .missingStaticPhaseMap:
      return
        "@InnoFlow(phaseManaged: true) requires a static `phaseMap` property so the macro can synthesize `body.phaseMap(Self.phaseMap)`"
    case .bodyAlreadyAppliesPhaseMap:
      return
        "@InnoFlow(phaseManaged: true) synthesizes `body.phaseMap(Self.phaseMap)` automatically; remove the explicit `.phaseMap(...)` call from `body` or disable phaseManaged"
    }
  }

  var diagnosticID: MessageID {
    switch self {
    case .missingStaticPhaseMap:
      return .init(domain: "InnoFlowMacro", id: "PhaseManagedMissingStaticPhaseMap")
    case .bodyAlreadyAppliesPhaseMap:
      return .init(domain: "InnoFlowMacro", id: "PhaseManagedExplicitPhaseMap")
    }
  }

  var severity: DiagnosticSeverity {
    .error
  }
}

private enum PhaseTotalityDiagnosticMessage: DiagnosticMessage {
  case unreferencedCase(caseName: String)

  var message: String {
    switch self {
    case .unreferencedCase(let caseName):
      return
        "`Phase.\(caseName)` is declared but never referenced from the static `phaseMap` — add a `From(.\(caseName)) { ... }` rule, an `On(..., to: .\(caseName))` target, or remove the case if it is unused"
    }
  }

  var diagnosticID: MessageID {
    switch self {
    case .unreferencedCase:
      return .init(domain: "InnoFlowMacro", id: "PhaseUnreferencedCase")
    }
  }

  var severity: DiagnosticSeverity {
    .warning
  }
}
