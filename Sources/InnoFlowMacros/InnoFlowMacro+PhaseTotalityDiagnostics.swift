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

  /// Reducer types whose initializer arguments run in a child's state/action
  /// domain. A `.phaseMap(...)` inside them belongs to that child reducer,
  /// not to the phase-managed feature whose `body` is being inspected.
  private static let childDomainReducerTypes: Set<String> = [
    "Scope", "IfLet", "IfCaseLet", "ForEachReducer", "ForEachIdentifiedReducer",
  ]

  private static func containsPhaseMapCall(in node: some SyntaxProtocol) -> Bool {
    containsPhaseMapCall(in: Syntax(node))
  }

  /// Whether `body` applies a phase map in the feature's own domain.
  ///
  /// Any `.phaseMap(...)` call counts, except one written inside the child
  /// part of a call that composes a child reducer: a child may own a phase
  /// of its own and apply its map where it is composed.
  ///
  /// This is a syntax pass. It recognizes the composing call by the name
  /// written at the call site and the child by its position in that call, so
  /// a child reducer hoisted into a local constant, or a combinator reached
  /// through a typealias, is still read as the feature's own domain. Write
  /// the child's `.phaseMap(...)` inside the combinator's arguments, or build
  /// the child reducer outside `body` (see `docs/MACRO_OPERATIONS.md`).
  private static func containsPhaseMapCall(in node: Syntax) -> Bool {
    if let call = node.as(FunctionCallExprSyntax.self) {
      if let memberAccess = call.calledExpression.as(MemberAccessExprSyntax.self),
        logicalIdentifier(memberAccess.declName.baseName) == "phaseMap"
      {
        return true
      }
      if let ownDomain = ownDomainExpressions(inChildComposingCall: call) {
        return ownDomain.contains { containsPhaseMapCall(in: Syntax($0)) }
      }
    }

    for child in node.children(viewMode: .sourceAccurate) where containsPhaseMapCall(in: child) {
      return true
    }
    return false
  }

  /// The expressions of a child-composing call that still run in the
  /// feature's own domain, or `nil` when `call` does not compose a child.
  ///
  /// - `Scope`, `IfLet`, `IfCaseLet`, `ForEachReducer` and
  ///   `ForEachIdentifiedReducer` take only child-domain arguments.
  /// - `parent.optionalChild(...)` keeps its receiver in the feature's
  ///   domain, for example `Reduce { ... }.phaseMap(map).optionalChild(...)`.
  /// - `OptionalChildLifetime(parent:state:action:instanceID:reducer:)` is
  ///   the same composition spelled as an initializer: `parent:` is the
  ///   feature's domain and `reducer:` is the child's.
  ///
  /// A type may be written `Name(...)`, `Name<...>(...)`, `Name.init(...)`
  /// or with a module qualifier.
  private static func ownDomainExpressions(
    inChildComposingCall call: FunctionCallExprSyntax
  ) -> [ExprSyntax]? {
    var callee = call.calledExpression
    if let specialization = callee.as(GenericSpecializationExprSyntax.self) {
      callee = specialization.expression
    }

    let name: String?
    var receiver: ExprSyntax?
    if let reference = callee.as(DeclReferenceExprSyntax.self) {
      name = logicalIdentifier(reference.baseName)
    } else if let memberAccess = callee.as(MemberAccessExprSyntax.self) {
      if memberAccess.declName.baseName.tokenKind == .keyword(.`init`) {
        name = memberAccess.base.flatMap(rightmostTypeName)
      } else {
        name = logicalIdentifier(memberAccess.declName.baseName)
        receiver = memberAccess.base
      }
    } else {
      name = nil
    }
    guard let name else { return nil }

    // Whatever stands left of the call is outside the child's arguments.
    var ownDomain = receiver.map { [$0] } ?? []
    switch name {
    case "optionalChild":
      return ownDomain
    case "OptionalChildLifetime":
      ownDomain.append(
        contentsOf: call.arguments
          .filter { $0.label.map(logicalIdentifier) == "parent" }
          .map(\.expression)
      )
      return ownDomain
    case _ where childDomainReducerTypes.contains(name):
      return ownDomain
    default:
      return nil
    }
  }

  /// The rightmost name of a type written as an expression: `Scope`,
  /// `Scope<...>`, `Module.Scope`.
  private static func rightmostTypeName(of expression: ExprSyntax) -> String? {
    var expression = expression
    if let specialization = expression.as(GenericSpecializationExprSyntax.self) {
      expression = specialization.expression
    }
    if let reference = expression.as(DeclReferenceExprSyntax.self) {
      return logicalIdentifier(reference.baseName)
    }
    if let memberAccess = expression.as(MemberAccessExprSyntax.self) {
      return logicalIdentifier(memberAccess.declName.baseName)
    }
    return nil
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
