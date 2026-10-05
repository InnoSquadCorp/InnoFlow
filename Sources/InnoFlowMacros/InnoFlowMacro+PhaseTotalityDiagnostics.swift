// MARK: - InnoFlowMacro+PhaseTotalityDiagnostics.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import SwiftDiagnostics
import SwiftIfConfig
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
  ///
  /// Scope (deliberate, syntax-only — see `docs/MACRO_OPERATIONS.md`):
  /// the pass runs only when the phase enum is literally named `Phase` and a
  /// static `phaseMap` variable exists on the feature, and it collects
  /// references only from direct `From(...)` / `On(to:)` / `On(targets:)`
  /// calls. DSL wrapped in helper functions, aliased phase enums, or
  /// dynamically built rules are invisible to this syntax pass. Missing
  /// direct references are warnings by default and errors when
  /// `strictPhaseTotality` is enabled; helper-built semantics still require
  /// Runtime coverage for those shapes belongs to
  /// `PhaseMap.validationReport(...)` in tests.
  static func diagnosePhaseTotalityIfNeeded(
    in declaration: StructDeclSyntax,
    strict: Bool = false,
    context: some MacroExpansionContext
  ) {
    guard let phaseEnum = findPhaseEnum(in: declaration) else {
      if strict {
        context.diagnose(
          Diagnostic(
            node: Syntax(declaration.name),
            message: PhaseTotalityDiagnosticMessage.phaseEnumUnavailable
          )
        )
      }
      return
    }

    guard let phaseMapMember = findStaticPhaseMapVariable(in: declaration) else {
      return
    }

    var unresolvedConditional: Syntax?
    let phaseElements = phaseCaseElements(
      in: phaseEnum.memberBlock.members,
      configuration: context.buildConfiguration,
      unresolvedConditional: &unresolvedConditional
    )
    var referencedNames: Set<String> = []
    collectPhaseMapDSLPhaseReferences(
      in: Syntax(phaseMapMember),
      configuration: context.buildConfiguration,
      unresolvedConditional: &unresolvedConditional,
      into: &referencedNames
    )
    if let unresolvedConditional {
      context.diagnose(
        Diagnostic(
          node: unresolvedConditional,
          message: PhaseTotalityDiagnosticMessage.conditionalConfigurationUnavailable(
            strict: strict)
        ))
      return
    }

    for element in phaseElements where !referencedNames.contains(logicalIdentifier(element.name)) {
      context.diagnose(
        Diagnostic(
          node: Syntax(element.name),
          message: PhaseTotalityDiagnosticMessage.unreferencedCase(
            caseName: logicalIdentifier(element.name),
            strict: strict
          )
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

    if containsPhaseMapCall(in: bodyProperty) {
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
      .first(where: { logicalIdentifier($0.name) == typeName })
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
          binding.pattern.as(IdentifierPatternSyntax.self).map { logicalIdentifier($0.identifier) }
            == "phaseMap"
        }
      }
  }

  private static func phaseCaseElements(
    in members: MemberBlockItemListSyntax,
    configuration: (any BuildConfiguration)?,
    unresolvedConditional: inout Syntax?
  ) -> [EnumCaseElementSyntax] {
    var elements: [EnumCaseElementSyntax] = []
    for member in members {
      if let enumCase = member.decl.as(EnumCaseDeclSyntax.self) {
        elements.append(contentsOf: enumCase.elements)
      } else if let conditional = member.decl.as(IfConfigDeclSyntax.self) {
        guard let configuration else {
          unresolvedConditional = unresolvedConditional ?? Syntax(conditional)
          continue
        }
        if let clause = conditional.activeClause(in: configuration).clause,
          let activeMembers = clause.elements?.as(MemberBlockItemListSyntax.self)
        {
          elements.append(
            contentsOf: phaseCaseElements(
              in: activeMembers,
              configuration: configuration,
              unresolvedConditional: &unresolvedConditional
            ))
        }
      }
    }
    return elements
  }

  private static func collectPhaseMapDSLPhaseReferences(
    in node: Syntax,
    configuration: (any BuildConfiguration)?,
    unresolvedConditional: inout Syntax?,
    into names: inout Set<String>
  ) {
    if let conditional = node.as(IfConfigDeclSyntax.self) {
      guard let configuration else {
        unresolvedConditional = unresolvedConditional ?? node
        return
      }
      if let clause = conditional.activeClause(in: configuration).clause {
        collectPhaseMapDSLPhaseReferences(
          in: Syntax(clause),
          configuration: configuration,
          unresolvedConditional: &unresolvedConditional,
          into: &names
        )
      }
      return
    }
    if let call = node.as(FunctionCallExprSyntax.self) {
      collectPhaseReferences(from: call, into: &names)
    }
    for child in node.children(viewMode: .sourceAccurate) {
      collectPhaseMapDSLPhaseReferences(
        in: child,
        configuration: configuration,
        unresolvedConditional: &unresolvedConditional,
        into: &names
      )
    }
  }

  private static func collectPhaseReferences(
    from call: FunctionCallExprSyntax,
    into names: inout Set<String>
  ) {
    let callee = call.calledExpression.as(DeclReferenceExprSyntax.self)
      .map { logicalIdentifier($0.baseName) }

    if callee == "From", let firstArgument = call.arguments.first {
      collectMemberAccessNames(in: Syntax(firstArgument.expression), into: &names)
      return
    }

    guard callee == "On" else { return }
    for argument in call.arguments {
      guard let label = argument.label.map(logicalIdentifier), label == "to" || label == "targets"
      else {
        continue
      }
      collectMemberAccessNames(in: Syntax(argument.expression), into: &names)
    }
  }

  private static func collectMemberAccessNames(in node: some SyntaxProtocol) -> Set<String> {
    var names: Set<String> = []
    collectMemberAccessNames(in: Syntax(node), into: &names)
    return names
  }

  private static func collectMemberAccessNames(in node: Syntax, into names: inout Set<String>) {
    if let memberAccess = node.as(MemberAccessExprSyntax.self) {
      names.insert(logicalIdentifier(memberAccess.declName.baseName))
    }

    for child in node.children(viewMode: .sourceAccurate) {
      collectMemberAccessNames(in: child, into: &names)
    }
  }

  private static func containsPhaseMapCall(in node: some SyntaxProtocol) -> Bool {
    containsPhaseMapCall(in: Syntax(node))
  }

  private static func containsPhaseMapCall(in node: Syntax) -> Bool {
    if let call = node.as(FunctionCallExprSyntax.self),
      let memberAccess = call.calledExpression.as(MemberAccessExprSyntax.self),
      logicalIdentifier(memberAccess.declName.baseName) == "phaseMap"
    {
      return true
    }

    for child in node.children(viewMode: .sourceAccurate) where containsPhaseMapCall(in: child) {
      return true
    }
    return false
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
  case unreferencedCase(caseName: String, strict: Bool)
  case phaseEnumUnavailable
  case conditionalConfigurationUnavailable(strict: Bool)

  var message: String {
    switch self {
    case .unreferencedCase(let caseName, _):
      let source = InnoFlowMacro.generatedIdentifierSource(caseName)
      return
        "`Phase.\(source)` is declared but never referenced from the static `phaseMap` — add a `From(.\(source)) { ... }` rule, an `On(..., to: .\(source))` target, or remove the case if it is unused"
    case .conditionalConfigurationUnavailable:
      return
        "phase totality cannot validate conditional `Phase` cases or `phaseMap` rules without the compiler’s build configuration; use a supported compiler that provides macro build configuration or make these declarations unconditional"
    case .phaseEnumUnavailable:
      return
        "strict phase totality requires a directly nested `Phase` enum on the feature or its nested `State`; aliases and dynamically declared phase types cannot be proven at macro-expansion time"
    }
  }

  var diagnosticID: MessageID {
    switch self {
    case .unreferencedCase(_, let strict):
      return .init(
        domain: "InnoFlowMacro",
        id: strict ? "StrictPhaseUnreferencedCase" : "PhaseUnreferencedCase"
      )
    case .conditionalConfigurationUnavailable:
      return .init(domain: "InnoFlowMacro", id: "PhaseConditionalConfigurationUnavailable")
    case .phaseEnumUnavailable:
      return .init(domain: "InnoFlowMacro", id: "StrictPhaseEnumUnavailable")
    }
  }

  var severity: DiagnosticSeverity {
    switch self {
    case .unreferencedCase(_, let strict), .conditionalConfigurationUnavailable(let strict):
      return strict ? .error : .warning
    case .phaseEnumUnavailable:
      return .error
    }
  }
}
