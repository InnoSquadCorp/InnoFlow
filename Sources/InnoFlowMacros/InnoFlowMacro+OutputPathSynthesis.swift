// MARK: - InnoFlowMacro+OutputPathSynthesis.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

extension InnoFlowMacro {
  private indirect enum OutputBooleanExpression {
    private struct Literal: Hashable {
      let atom: String
      let isPositive: Bool
    }

    case alwaysFalse
    case alwaysTrue
    case atom(String)
    case not(Self)
    case and([Self])
    case or([Self])

    init(parsing source: String) {
      let source = InnoFlowMacro.outputStrippingOuterParentheses(
        source.trimmingCharacters(in: .whitespacesAndNewlines)
      )
      if source == "true" {
        self = .alwaysTrue
      } else if source == "false" {
        self = .alwaysFalse
      } else if let components = InnoFlowMacro.outputSplitTopLevel(source, operator: "||") {
        self = .or(components.map(Self.init(parsing:)))
      } else if let components = InnoFlowMacro.outputSplitTopLevel(source, operator: "&&") {
        self = .and(components.map(Self.init(parsing:)))
      } else if source.hasPrefix("!"), !source.hasPrefix("!=") {
        self = .not(Self(parsing: String(source.dropFirst())))
      } else {
        // These predicates have no whitespace-sensitive arguments. Compare
        // their semantic spelling, while leaving custom conditions untouched.
        let compact = source.filter { !$0.isWhitespace }
        let predicatePrefixes = ["os(", "arch(", "targetEnvironment(", "swift(", "compiler("]
        let atom = predicatePrefixes.contains(where: compact.hasPrefix) ? compact : source
        self = .atom(atom == "os(OSX)" ? "os(macOS)" : atom)
      }
    }

    static func && (lhs: Self, rhs: Self) -> Self {
      switch (lhs, rhs) {
      case (.alwaysFalse, _), (_, .alwaysFalse): .alwaysFalse
      case (.alwaysTrue, let expression), (let expression, .alwaysTrue): expression
      case (.and(let left), .and(let right)): .and(left + right)
      case (.and(let expressions), let expression), (let expression, .and(let expressions)):
        .and(expressions + [expression])
      default: .and([lhs, rhs])
      }
    }

    var negated: Self {
      switch self {
      case .alwaysFalse: .alwaysTrue
      case .alwaysTrue: .alwaysFalse
      case .not(let expression): expression
      default: .not(self)
      }
    }

    var conditionSource: String {
      switch self {
      case .alwaysFalse: "false"
      case .alwaysTrue: "true"
      case .atom(let source): source
      case .not(let expression): "!(\(expression.conditionSource))"
      case .and(let expressions):
        expressions.map { "(\($0.conditionSource))" }.joined(separator: " && ")
      case .or(let expressions):
        expressions.map { "(\($0.conditionSource))" }.joined(separator: " || ")
      }
    }

    var isSatisfiable: Bool {
      dnf(negated: false, limit: 256)?.contains(where: Self.isSatisfiable) ?? true
    }

    private static func isSatisfiable(_ literals: [Literal]) -> Bool {
      let literalSet = Set(literals)
      guard
        !literalSet.contains(where: {
          literalSet.contains(Literal(atom: $0.atom, isPositive: !$0.isPositive))
        })
      else { return false }

      let positivePlatforms = Set(
        literalSet.compactMap { literal -> String? in
          guard literal.isPositive,
            literal.atom.hasPrefix("os("),
            literal.atom.hasSuffix(")")
          else { return nil }
          return literal.atom
        }
      )
      guard positivePlatforms.count <= 1 else { return false }

      let positiveArchitectures = Set(
        literalSet.compactMap { literal -> String? in
          guard literal.isPositive,
            literal.atom.hasPrefix("arch("),
            literal.atom.hasSuffix(")")
          else { return nil }
          return literal.atom
        }
      )
      guard positiveArchitectures.count <= 1 else { return false }

      let positiveTargetEnvironments = Set(
        literalSet.compactMap { literal -> String? in
          guard literal.isPositive,
            literal.atom.hasPrefix("targetEnvironment("),
            literal.atom.hasSuffix(")")
          else { return nil }
          return literal.atom
        }
      )
      guard positiveTargetEnvironments.count <= 1 else { return false }

      return versionPredicatesAreSatisfiable(literalSet, domain: "swift")
        && versionPredicatesAreSatisfiable(literalSet, domain: "compiler")
    }

    private struct Version: Comparable {
      let components: [Int]

      static func < (lhs: Self, rhs: Self) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
          let left = index < lhs.components.count ? lhs.components[index] : 0
          let right = index < rhs.components.count ? rhs.components[index] : 0
          if left != right { return left < right }
        }
        return false
      }
    }

    private struct VersionPredicate {
      let operation: String
      let version: Version
    }

    private static func versionPredicatesAreSatisfiable(
      _ literals: Set<Literal>,
      domain: String
    ) -> Bool {
      var lower: (version: Version, inclusive: Bool)?
      var upper: (version: Version, inclusive: Bool)?

      for literal in literals {
        guard var predicate = versionPredicate(literal.atom, domain: domain) else { continue }
        if !literal.isPositive {
          predicate = VersionPredicate(
            operation: [">=": "<", ">": "<=", "<": ">=", "<=": ">"][
              predicate.operation
            ] ?? predicate.operation,
            version: predicate.version
          )
        }
        switch predicate.operation {
        case ">=", ">":
          let candidate = (predicate.version, predicate.operation == ">=")
          if lower == nil || lower!.version < candidate.0
            || (lower!.version == candidate.0 && lower!.inclusive && !candidate.1)
          {
            lower = candidate
          }
        case "<", "<=":
          let candidate = (predicate.version, predicate.operation == "<=")
          if upper == nil || candidate.0 < upper!.version
            || (upper!.version == candidate.0 && upper!.inclusive && !candidate.1)
          {
            upper = candidate
          }
        default:
          continue
        }
      }

      guard let lower, let upper else { return true }
      if lower.version < upper.version { return true }
      if upper.version < lower.version { return false }
      return lower.inclusive && upper.inclusive
    }

    private static func versionPredicate(_ atom: String, domain: String) -> VersionPredicate? {
      let compact = atom.filter { !$0.isWhitespace }
      let prefix = "\(domain)("
      guard compact.hasPrefix(prefix), compact.hasSuffix(")") else { return nil }
      let contents = String(compact.dropFirst(prefix.count).dropLast())
      let operation = [">=", "<=", ">", "<"].first { contents.hasPrefix($0) }
      guard let operation else { return nil }
      let versionSource = contents.dropFirst(operation.count)
      let components = versionSource.split(separator: ".").compactMap { Int($0) }
      guard !components.isEmpty,
        components.count == versionSource.split(separator: ".").count
      else { return nil }
      return VersionPredicate(operation: operation, version: Version(components: components))
    }

    /// Converts the expression into a bounded disjunctive normal form. The
    /// fallback on an unexpectedly large expression is conservative: callers
    /// assume satisfiable so a potentially colliding declaration is never
    /// silently generated.
    private func dnf(negated: Bool, limit: Int) -> [[Literal]]? {
      switch self {
      case .alwaysFalse:
        return negated ? [[]] : []
      case .alwaysTrue:
        return negated ? [] : [[]]
      case .atom(let source):
        return [[Literal(atom: source, isPositive: !negated)]]
      case .not(let expression):
        return expression.dnf(negated: !negated, limit: limit)
      case .and(let expressions):
        return negated
          ? Self.union(expressions, negated: true, limit: limit)
          : Self.product(expressions, negated: false, limit: limit)
      case .or(let expressions):
        return negated
          ? Self.product(expressions, negated: true, limit: limit)
          : Self.union(expressions, negated: false, limit: limit)
      }
    }

    private static func union(
      _ expressions: [Self],
      negated: Bool,
      limit: Int
    ) -> [[Literal]]? {
      var result: [[Literal]] = []
      for expression in expressions {
        guard let clauses = expression.dnf(negated: negated, limit: limit) else { return nil }
        result.append(contentsOf: clauses)
        guard result.count <= limit else { return nil }
      }
      return result
    }

    private static func product(
      _ expressions: [Self],
      negated: Bool,
      limit: Int
    ) -> [[Literal]]? {
      var result: [[Literal]] = [[]]
      for expression in expressions {
        guard let clauses = expression.dnf(negated: negated, limit: limit) else { return nil }
        var next: [[Literal]] = []
        for left in result {
          for right in clauses {
            let combined = left + right
            if isSatisfiable(combined) {
              next.append(combined)
            }
            guard next.count <= limit else { return nil }
          }
        }
        result = next
        if result.isEmpty { break }
      }
      return result
    }
  }

  struct OutputConditionalContext {
    private var expression: OutputBooleanExpression = .alwaysTrue

    func entering(clause: IfConfigClauseSyntax, priorConditions: [String]) -> Self {
      var copy = self
      for condition in priorConditions {
        copy.expression = copy.expression && OutputBooleanExpression(parsing: condition).negated
      }
      if let condition = clause.condition?.trimmedDescription {
        copy.expression = copy.expression && OutputBooleanExpression(parsing: condition)
      }
      return copy
    }

    func overlaps(_ other: Self) -> Bool {
      (expression && other.expression).isSatisfiable
    }

    func isCovered(by other: Self) -> Bool {
      !(expression && other.expression.negated).isSatisfiable
    }

    func excluding(_ contexts: [Self]) -> Self {
      guard !contexts.isEmpty else { return self }
      var copy = self
      let excludedExpression = OutputBooleanExpression.or(contexts.map(\.expression))
      copy.expression = copy.expression && excludedExpression.negated
      return copy
    }

    var isSatisfiable: Bool {
      expression.isSatisfiable
    }

    var conditionSource: String {
      expression.conditionSource
    }
  }

  /// The part of an enum case declaration the compiler compares to decide
  /// whether two cases redeclare each other: the base name and, for a case
  /// with a payload, its argument labels.
  struct CaseDeclarationName {
    private let baseName: String
    /// `nil` for a case without a payload.
    private let argumentLabels: [String]?

    init(_ element: EnumCaseElementSyntax) {
      baseName = InnoFlowMacro.logicalIdentifier(element.name)
      if let parameters = element.parameterClause?.parameters, !parameters.isEmpty {
        argumentLabels = parameters.map { parameter in
          parameter.firstName.map(InnoFlowMacro.logicalIdentifier) ?? "_"
        }
      } else {
        argumentLabels = nil
      }
    }

    /// Whether the compiler rejects an enum in which both cases are active.
    /// A payload-free case redeclares every same-named case; two cases with
    /// payloads redeclare each other when their argument labels match.
    func redeclares(_ other: Self) -> Bool {
      guard baseName == other.baseName else { return false }
      guard let argumentLabels, let otherLabels = other.argumentLabels else { return true }
      return argumentLabels == otherLabels
    }
  }

  struct OutputNameTable {
    private struct Entry {
      let context: OutputConditionalContext
      /// The case a generated helper was synthesized from; `nil` for members
      /// the author declared and for generated identity markers.
      let sourceCase: CaseDeclarationName?
    }

    private var entriesByName: [String: [Entry]] = [:]

    mutating func insert(
      _ name: String,
      context: OutputConditionalContext,
      sourceCase: CaseDeclarationName? = nil
    ) {
      entriesByName[name, default: []].append(.init(context: context, sourceCase: sourceCase))
    }

    func contains(_ name: String, overlapping context: OutputConditionalContext) -> Bool {
      entriesByName[name]?.contains { $0.context.overlaps(context) } == true
    }

    /// Whether `name` is taken, under conditions that overlap `context`, by
    /// anything that can exist next to the helper of `sourceCase`. The helper
    /// of a case that redeclares `sourceCase` does not count: the compiler
    /// never accepts both cases in one configuration, so their helpers never
    /// meet either.
    func contains(
      _ name: String,
      overlapping context: OutputConditionalContext,
      coexistingWith sourceCase: CaseDeclarationName
    ) -> Bool {
      entriesByName[name]?.contains { entry in
        guard entry.context.overlaps(context) else { return false }
        guard let other = entry.sourceCase else { return true }
        return !other.redeclares(sourceCase)
      } == true
    }

    func contexts(_ name: String, overlapping context: OutputConditionalContext)
      -> [OutputConditionalContext]
    {
      entriesByName[name]?.map(\.context).filter { $0.overlaps(context) } ?? []
    }
  }

  static func synthesizedOutputPathDeclarations(
    in outputEnum: EnumDeclSyntax,
    context: some MacroExpansionContext
  ) -> [DeclSyntax] {
    let accessPrefix = synthesizedMemberAccessPrefix(
      from: outputEnum.modifiers,
      declaration: outputEnum,
      in: context
    )
    let requiresComputedProperty = outputPathRequiresComputedProperty(
      outputEnum: outputEnum,
      context: context
    )
    let existingNames = outputExistingMemberNames(in: outputEnum)
    let manualPathNames = outputManualPathNames(in: outputEnum)
    var seenGeneratedNames = OutputNameTable()
    return synthesizedConditionalCasePathSources(
      in: outputEnum.memberBlock.members,
      conditionalContext: .init()
    ) { site in
      synthesizedOutputElementSources(
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

  /// One enum case element together with everything its declaration site
  /// contributes to path synthesis: the compiler conditions that enclose it,
  /// the availability to mirror, and the conditions under which the case is
  /// unavailable or explicitly ignored.
  struct CasePathElementSite {
    let element: EnumCaseElementSyntax
    let conditionalContext: OutputConditionalContext
    let availabilityPrefix: String
    let unavailableContexts: [OutputConditionalContext]
    let ignoredContexts: [OutputConditionalContext]
  }

  /// The compiler conditions in which a path member is generated, after
  /// removing the conditions where the case is unavailable, ignored, or
  /// already covered by a manual path.
  struct CasePathGenerationScope {
    let generationContext: OutputConditionalContext
    let exclusionContexts: [OutputConditionalContext]

    /// Wraps generated declarations so they exist only outside the excluded
    /// conditions.
    func wrapping(_ source: [String]) -> [String] {
      guard !exclusionContexts.isEmpty else { return source }
      let exclusionCondition =
        exclusionContexts
        .map(\.conditionSource)
        .map { "(\($0))" }
        .joined(separator: " || ")
      return ["#if !(\(exclusionCondition))\n\(source.joined(separator: "\n"))\n#endif"]
    }
  }

  /// Returns `nil` when no compiler condition remains in which the member
  /// should exist.
  static func casePathGenerationScope(
    at site: CasePathElementSite,
    manualContexts: [OutputConditionalContext]
  ) -> CasePathGenerationScope? {
    let conditionalContext = site.conditionalContext
    let exclusionContexts =
      manualContexts
      + (site.unavailableContexts + site.ignoredContexts).filter {
        $0.overlaps(conditionalContext)
      }
    if exclusionContexts.contains(where: { conditionalContext.isCovered(by: $0) }) {
      return nil
    }
    let generationContext = conditionalContext.excluding(exclusionContexts)
    guard generationContext.isSatisfiable else { return nil }
    return .init(generationContext: generationContext, exclusionContexts: exclusionContexts)
  }

  /// Reserves `memberName` for the helper of `element` in `generationContext`.
  ///
  /// Returns `false`, reserving nothing, when the name is already taken in a
  /// compiler configuration where this helper would also exist: by a member
  /// the author declared that is not a manual path, or by the helper of a
  /// case that can be active together with `element`. Two cases the compiler
  /// treats as redeclarations of each other are never active together, so
  /// each keeps its helper inside its own mirrored clause.
  static func reserveGeneratedCasePathName(
    _ memberName: String,
    for element: EnumCaseElementSyntax,
    in generationContext: OutputConditionalContext,
    existingNames: OutputNameTable,
    manualPathNames: OutputNameTable,
    seenGeneratedNames: inout OutputNameTable
  ) -> Bool {
    let sourceCase = CaseDeclarationName(element)
    // `generationContext` already excludes the conditions of a manual path,
    // so a static variable of this name never meets the helper. Other kinds
    // of members (a case, a static function, a nested type) do.
    let collidesWithDeclaredMember =
      existingNames.contains(memberName, overlapping: generationContext)
      && !manualPathNames.contains(memberName, overlapping: generationContext)
    guard
      !collidesWithDeclaredMember,
      !seenGeneratedNames.contains(
        memberName,
        overlapping: generationContext,
        coexistingWith: sourceCase
      )
    else { return false }
    seenGeneratedNames.insert(memberName, context: generationContext, sourceCase: sourceCase)
    return true
  }

  /// Walks enum members and asks `synthesizeElement` for the declarations of
  /// every case element, recreating the enclosing `#if` / `#elseif` / `#else`
  /// structure around whatever it returns.
  ///
  /// `Action` and `Output` path synthesis share this traversal so conditional
  /// compilation, availability and `@InnoFlowCasePathIgnored` behave the same
  /// for both.
  static func synthesizedConditionalCasePathSources(
    in members: MemberBlockItemListSyntax,
    conditionalContext: OutputConditionalContext,
    synthesizeElement: (CasePathElementSite) -> [String]
  ) -> [String] {
    var declarations: [String] = []
    for member in members {
      if let enumCaseDecl = member.decl.as(EnumCaseDeclSyntax.self) {
        let availabilityPrefix = outputAvailabilityPrefix(enumCaseDecl)
        let unavailableContexts = outputUnavailableContexts(
          in: enumCaseDecl.attributes,
          conditionalContext: conditionalContext
        )
        let ignoredContexts = outputAttributeContexts(
          named: "InnoFlowCasePathIgnored",
          in: enumCaseDecl.attributes,
          conditionalContext: conditionalContext
        )
        for element in enumCaseDecl.elements {
          declarations.append(
            contentsOf: synthesizeElement(
              .init(
                element: element,
                conditionalContext: conditionalContext,
                availabilityPrefix: availabilityPrefix,
                unavailableContexts: unavailableContexts,
                ignoredContexts: ignoredContexts
              )
            )
          )
        }
        continue
      }

      guard let ifConfig = member.decl.as(IfConfigDeclSyntax.self) else { continue }
      var generatedClauses: [String] = []
      var hasGeneratedMember = false
      var priorConditions: [String] = []
      for clause in ifConfig.clauses {
        let clauseContext = conditionalContext.entering(
          clause: clause,
          priorConditions: priorConditions
        )
        let clauseMembers = clause.elements?.as(MemberBlockItemListSyntax.self)
        let clauseDeclarations =
          clauseMembers.map {
            synthesizedConditionalCasePathSources(
              in: $0,
              conditionalContext: clauseContext,
              synthesizeElement: synthesizeElement
            )
          } ?? []
        hasGeneratedMember = hasGeneratedMember || !clauseDeclarations.isEmpty
        let directive =
          clause.poundKeyword.trimmedDescription
          + (clause.condition.map { " \($0.trimmedDescription)" } ?? "")
        generatedClauses.append(
          ([directive] + clauseDeclarations).joined(separator: "\n")
        )
        if let condition = clause.condition?.trimmedDescription {
          priorConditions.append(condition)
        }
      }
      if hasGeneratedMember {
        declarations.append(
          (generatedClauses + ["#endif"]).joined(separator: "\n")
        )
      }
    }
    return declarations
  }

  private static func synthesizedOutputElementSources(
    at site: CasePathElementSite,
    accessPrefix: String,
    requiresComputedProperty: Bool,
    existingNames: OutputNameTable,
    manualPathNames: OutputNameTable,
    seenGeneratedNames: inout OutputNameTable,
    context: some MacroExpansionContext
  ) -> [String] {
    let element = site.element
    let memberName = "\(generatedPathBaseName(from: element.name))CasePath"
    guard
      let scope = casePathGenerationScope(
        at: site,
        manualContexts: manualPathNames.contexts(
          memberName,
          overlapping: site.conditionalContext
        )
      )
    else { return [] }

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
          message: InnoFlowOutputPathsMessage.collision(memberName: memberName))
      )
      return []
    }

    guard
      let source = synthesizedOutputPathSource(
        for: element,
        memberName: memberName,
        availabilityPrefix: site.availabilityPrefix,
        conditionalContext: scope.generationContext,
        accessPrefix: accessPrefix,
        requiresComputedProperty: requiresComputedProperty,
        existingNames: existingNames,
        seenGeneratedNames: &seenGeneratedNames,
        context: context
      )
    else { return [] }
    return scope.wrapping(source)
  }

  private static func synthesizedOutputPathSource(
    for element: EnumCaseElementSyntax,
    memberName: String,
    availabilityPrefix: String,
    conditionalContext: OutputConditionalContext,
    accessPrefix: String,
    requiresComputedProperty: Bool,
    existingNames: OutputNameTable,
    seenGeneratedNames: inout OutputNameTable,
    context: some MacroExpansionContext
  ) -> [String]? {
    let caseName = logicalIdentifier(element.name)
    let caseSource = identifierSource(element.name)
    let parameters = Array(element.parameterClause?.parameters ?? [])

    // `_ name: Payload` only documents the payload: the case is constructed
    // and matched without an argument label, exactly like `Payload` alone.
    // Any other pair of names is not a declaration the compiler accepts.
    if parameters.contains(where: { $0.secondName != nil && $0.firstName?.text != "_" }) {
      context.diagnose(
        Diagnostic(
          node: Syntax(element.name),
          message: InnoFlowOutputPathsMessage.unsupportedLocalBinding(caseName: caseName)
        )
      )
      return nil
    }

    let labels = parameters.compactMap { parameter -> String? in
      guard let name = parameter.firstName?.text, name != "_" else { return nil }
      return logicalIdentifier(name)
    }
    if Set(labels).count != labels.count {
      context.diagnose(
        Diagnostic(
          node: Syntax(element.name),
          message: InnoFlowOutputPathsMessage.duplicateLabels(caseName: caseName)
        )
      )
      return nil
    }

    let valueType: String
    let embedBody: String
    let extractBody: String

    switch parameters.count {
    case 0:
      valueType = "Void"
      embedBody = ".\(caseSource)"
      extractBody =
        "guard case .\(caseSource) = output else { return nil }\nreturn .some(())"

    case 1:
      let parameter = parameters[0]
      valueType = parameter.type.trimmedDescription
      let label = outputParameterLabel(parameter, asArgumentLabel: true)
      embedBody = label.map { ".\(caseSource)(\($0): value)" } ?? ".\(caseSource)(value)"
      extractBody =
        "guard case .\(caseSource)(let value) = output else { return nil }\nreturn .some(value)"

    default:
      valueType =
        "("
        + parameters.enumerated().map { index, parameter in
          let type = parameter.type.trimmedDescription
          return outputParameterLabel(parameter).map { "\($0): \(type)" } ?? type
        }.joined(separator: ", ") + ")"
      let arguments = parameters.enumerated().map { index, parameter in
        let access = outputParameterLabel(parameter).map { "value.\($0)" } ?? "value.\(index)"
        return outputParameterLabel(parameter, asArgumentLabel: true).map { "\($0): \(access)" }
          ?? access
      }.joined(separator: ", ")
      embedBody = ".\(caseSource)(\(arguments))"
      let bindings = parameters.indices.map { "value\($0)" }.joined(separator: ", ")
      let tupleValues = parameters.enumerated().map { index, parameter in
        outputParameterLabel(parameter, asArgumentLabel: true).map { "\($0): value\(index)" }
          ?? "value\(index)"
      }.joined(separator: ", ")
      extractBody =
        "guard case let .\(caseSource)(\(bindings)) = output else { return nil }\nreturn .some((\(tupleValues)))"
    }

    let declaration: String
    if requiresComputedProperty {
      let markerName = outputIdentityMarkerName(
        for: memberName,
        conditionalContext: conditionalContext,
        existingNames: existingNames,
        seenGeneratedNames: &seenGeneratedNames
      )
      declaration =
        """
        \(accessPrefix)static var \(generatedIdentifierSource(memberName)): CasePath<Self, \(valueType)> {
          CasePath<Self, \(valueType)>._innoFlowGenerated(
            marker: \(generatedIdentifierSource(markerName)).self,
            embed: { value in
              \(embedBody)
            },
            extract: { output in
              \(extractBody)
            }
          )
        }
        """
      return [
        "private enum \(generatedIdentifierSource(markerName)) {}",
        availabilityPrefix + declaration,
      ]
    }

    declaration =
      """
      \(accessPrefix)static let \(generatedIdentifierSource(memberName)) = CasePath<Self, \(valueType)>(
        embed: { value in
          \(embedBody)
        },
        extract: { output in
          \(extractBody)
        }
      )
      """
    return [availabilityPrefix + declaration]
  }

  private static func outputParameterLabel(
    _ parameter: EnumCaseParameterSyntax,
    asArgumentLabel: Bool = false
  ) -> String? {
    guard let name = parameter.firstName, name.text != "_" else { return nil }
    return identifierSource(name, asArgumentLabel: asArgumentLabel)
  }

  static func outputExistingMemberNames(in outputEnum: EnumDeclSyntax) -> OutputNameTable {
    var names = OutputNameTable()
    collectOutputNames(
      in: outputEnum.memberBlock.members,
      conditionalContext: .init(),
      includeOnlyStaticVariables: false,
      names: &names
    )
    return names
  }

  static func outputManualPathNames(in outputEnum: EnumDeclSyntax) -> OutputNameTable {
    var names = OutputNameTable()
    collectOutputNames(
      in: outputEnum.memberBlock.members,
      conditionalContext: .init(),
      includeOnlyStaticVariables: true,
      names: &names
    )
    return names
  }

  private static func collectOutputNames(
    in members: MemberBlockItemListSyntax,
    conditionalContext: OutputConditionalContext,
    includeOnlyStaticVariables: Bool,
    names: inout OutputNameTable
  ) {
    for member in members {
      let memberNames: [String] = {
        if let enumCase = member.decl.as(EnumCaseDeclSyntax.self) {
          return includeOnlyStaticVariables ? [] : enumCase.elements.map { $0.name.text }
        }
        if let variable = member.decl.as(VariableDeclSyntax.self),
          variable.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) })
        {
          return variable.bindings.compactMap {
            $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
          }
        }
        if let function = member.decl.as(FunctionDeclSyntax.self),
          function.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) })
        {
          return includeOnlyStaticVariables ? [] : [function.name.text]
        }
        guard !includeOnlyStaticVariables else { return [] }
        if let declaration = member.decl.as(EnumDeclSyntax.self) { return [declaration.name.text] }
        if let declaration = member.decl.as(StructDeclSyntax.self) {
          return [declaration.name.text]
        }
        if let declaration = member.decl.as(ClassDeclSyntax.self) { return [declaration.name.text] }
        if let declaration = member.decl.as(ActorDeclSyntax.self) { return [declaration.name.text] }
        if let declaration = member.decl.as(ProtocolDeclSyntax.self) {
          return [declaration.name.text]
        }
        if let declaration = member.decl.as(TypeAliasDeclSyntax.self) {
          return [declaration.name.text]
        }
        return []
      }()
      for name in memberNames {
        names.insert(logicalIdentifier(name), context: conditionalContext)
      }

      guard let ifConfig = member.decl.as(IfConfigDeclSyntax.self) else { continue }
      var priorConditions: [String] = []
      for clause in ifConfig.clauses {
        guard let clauseMembers = clause.elements?.as(MemberBlockItemListSyntax.self) else {
          continue
        }
        collectOutputNames(
          in: clauseMembers,
          conditionalContext: conditionalContext.entering(
            clause: clause,
            priorConditions: priorConditions
          ),
          includeOnlyStaticVariables: includeOnlyStaticVariables,
          names: &names
        )
        if let condition = clause.condition?.trimmedDescription {
          priorConditions.append(condition)
        }
      }
    }
  }

  private static func outputAvailabilityPrefix(_ declaration: EnumCaseDeclSyntax) -> String {
    let attributes = outputAvailabilitySources(in: declaration.attributes)
    return attributes.isEmpty ? "" : attributes.joined(separator: "\n") + "\n"
  }

  private static func outputAvailabilitySources(in attributes: AttributeListSyntax) -> [String] {
    var sources: [String] = []
    for element in attributes {
      if let attribute = element.as(AttributeSyntax.self) {
        if outputAttributeName(attribute) == "available",
          let helperAttribute = outputHelperAvailability(attribute)
        {
          sources.append(outputSingleLineSource(of: helperAttribute))
        }
        continue
      }

      guard let ifConfig = element.as(IfConfigDeclSyntax.self) else { continue }
      var clauses: [String] = []
      var containsAvailability = false
      for clause in ifConfig.clauses {
        let nested =
          clause.elements?.as(AttributeListSyntax.self).map {
            outputAvailabilitySources(in: $0)
          } ?? []
        containsAvailability = containsAvailability || !nested.isEmpty
        let directive =
          clause.poundKeyword.trimmedDescription
          + (clause.condition.map { " \($0.trimmedDescription)" } ?? "")
        clauses.append(([directive] + nested).joined(separator: "\n"))
      }
      if containsAvailability {
        sources.append((clauses + ["#endif"]).joined(separator: "\n"))
      }
    }
    return sources
  }

  /// A case-level rename targets an enum constructor, not a CasePath. Keep
  /// deprecation/availability/message metadata, but do not teach the compiler
  /// to replace a path use with a value or constructor of a different type.
  ///
  /// Returns `nil` when the rename was all the attribute said: what remains
  /// names a platform without restricting it, which the compiler rejects.
  private static func outputHelperAvailability(_ attribute: AttributeSyntax) -> AttributeSyntax? {
    guard case .availability(let arguments)? = attribute.arguments else { return attribute }
    var retained = arguments.filter { argument in
      guard case .availabilityLabeledArgument(let labeled) = argument.argument else { return true }
      return logicalIdentifier(labeled.label) != "renamed"
    }
    guard retained.count != arguments.count else { return attribute }
    guard retained.count > 1 else { return nil }
    if let last = retained.indices.last {
      retained[last].trailingComma = nil
    }
    var copy = attribute
    copy.arguments = .availability(retained)
    return copy
  }

  /// Renders a copied attribute on one line, without comments.
  ///
  /// Trivia is the layout of the case declaration, not part of the
  /// attribute. Carried into generated source it can change what the source
  /// means: once an argument is dropped, a line comment that stood before it
  /// swallows the closing parenthesis. Tokens the author separated stay
  /// separated by one space; none is added before a comma or inside the
  /// parentheses.
  private static func outputSingleLineSource(of attribute: AttributeSyntax) -> String {
    var source = ""
    var previous: TokenSyntax?
    for token in attribute.tokens(viewMode: .sourceAccurate) {
      if let previous {
        let wasSeparated = !previous.trailingTrivia.isEmpty || !token.leadingTrivia.isEmpty
        let hugsItsNeighbor =
          previous.tokenKind == .leftParen
          || token.tokenKind == .rightParen
          || token.tokenKind == .comma
        if wasSeparated && !hugsItsNeighbor {
          source += " "
        }
      }
      source += token.text
      previous = token
    }
    return source
  }

  private static func outputAttributeContexts(
    named expectedName: String,
    in attributes: AttributeListSyntax,
    conditionalContext: OutputConditionalContext
  ) -> [OutputConditionalContext] {
    var contexts: [OutputConditionalContext] = []
    for element in attributes {
      if let attribute = element.as(AttributeSyntax.self) {
        if outputAttributeName(attribute) == expectedName {
          contexts.append(conditionalContext)
        }
        continue
      }
      guard let ifConfig = element.as(IfConfigDeclSyntax.self) else { continue }
      var priorConditions: [String] = []
      for clause in ifConfig.clauses {
        let clauseContext = conditionalContext.entering(
          clause: clause,
          priorConditions: priorConditions
        )
        if let clauseAttributes = clause.elements?.as(AttributeListSyntax.self) {
          contexts.append(
            contentsOf: outputAttributeContexts(
              named: expectedName,
              in: clauseAttributes,
              conditionalContext: clauseContext
            )
          )
        }
        if let condition = clause.condition?.trimmedDescription {
          priorConditions.append(condition)
        }
      }
    }
    return contexts
  }

  /// Returns the compiler conditions under which a case is unavailable. The
  /// generated path is emitted only in their complement, preserving useful API
  /// on supported platforms without referencing the case in a forbidden branch.
  private static func outputUnavailableContexts(
    in attributes: AttributeListSyntax,
    conditionalContext: OutputConditionalContext
  ) -> [OutputConditionalContext] {
    var contexts: [OutputConditionalContext] = []
    for element in attributes {
      if let attribute = element.as(AttributeSyntax.self) {
        guard let availability = outputUnavailableAvailability(attribute) else { continue }
        if availability == "*" {
          contexts.append(conditionalContext)
          continue
        }
        // Platform- and environment-specific availability is copied verbatim
        // to the generated helper. Let the compiler resolve inheritance and
        // more-specific overrides (for example iOS unavailable plus a
        // macCatalyst introduction) instead of approximating them with #if.
        // An unavailable declaration may reference its unavailable case while
        // callers still receive the native availability diagnostic.
        continue
      }

      guard let ifConfig = element.as(IfConfigDeclSyntax.self) else { continue }
      var priorConditions: [String] = []
      for clause in ifConfig.clauses {
        let clauseContext = conditionalContext.entering(
          clause: clause,
          priorConditions: priorConditions
        )
        if let clauseAttributes = clause.elements?.as(AttributeListSyntax.self) {
          contexts.append(
            contentsOf: outputUnavailableContexts(
              in: clauseAttributes,
              conditionalContext: clauseContext
            )
          )
        }
        if let condition = clause.condition?.trimmedDescription {
          priorConditions.append(condition)
        }
      }
    }
    return contexts
  }

  private static func outputAttributeName(_ attribute: AttributeSyntax) -> String? {
    if let identifier = attribute.attributeName.as(IdentifierTypeSyntax.self) {
      return logicalIdentifier(identifier.name)
    }
    if let member = attribute.attributeName.as(MemberTypeSyntax.self) {
      return logicalIdentifier(member.name)
    }
    return nil
  }

  /// Returns the unavailable availability domain only when `unavailable` is
  /// an actual top-level argument. Message text and renamed strings must not
  /// suppress generated API.
  private static func outputUnavailableAvailability(_ attribute: AttributeSyntax) -> String? {
    guard
      outputAttributeName(attribute) == "available",
      case .availability(let arguments)? = attribute.arguments
    else { return nil }

    var domain: String?
    var isUnavailable = false
    for argument in arguments {
      switch argument.argument {
      case .token(let token):
        if domain == nil, token.text != "unavailable" {
          domain = token.text
        }
        if token.text == "unavailable" {
          isUnavailable = true
        }
      case .availabilityVersionRestriction(let restriction):
        if domain == nil {
          domain = restriction.platform.text
        }
      case .availabilityLabeledArgument:
        break
      }
    }
    guard isUnavailable else { return nil }
    return domain
  }

  private static func outputStrippingOuterParentheses(_ source: String) -> String {
    var result = source
    while result.first == "(", result.last == ")" {
      var depth = 0
      var closesAtEnd = false
      for (offset, character) in result.enumerated() {
        if character == "(" { depth += 1 }
        if character == ")" { depth -= 1 }
        if depth == 0 {
          closesAtEnd = offset == result.count - 1
          break
        }
      }
      guard closesAtEnd else { break }
      result = String(result.dropFirst().dropLast())
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return result
  }

  private static func outputSplitTopLevel(_ source: String, operator: String) -> [String]? {
    var depth = 0
    let characters = Array(source)
    let operatorCharacters = Array(`operator`)
    var components: [String] = []
    var componentStart = 0
    var isInString = false
    var isEscaped = false
    var index = 0
    while index < characters.count {
      let character = characters[index]
      if isInString {
        if isEscaped {
          isEscaped = false
        } else if character == "\\" {
          isEscaped = true
        } else if character == "\"" {
          isInString = false
        }
        index += 1
        continue
      }
      if character == "\"" {
        isInString = true
        index += 1
        continue
      }
      switch characters[index] {
      case "(": depth += 1
      case ")": depth -= 1
      default:
        if depth == 0,
          index + operatorCharacters.count <= characters.count,
          Array(characters[index..<(index + operatorCharacters.count)]) == operatorCharacters
        {
          let component = String(characters[componentStart..<index])
            .trimmingCharacters(in: .whitespacesAndNewlines)
          guard !component.isEmpty else { return nil }
          components.append(component)
          index += operatorCharacters.count
          componentStart = index
          continue
        }
      }
      index += 1
    }
    guard !components.isEmpty else { return nil }
    let tail = String(characters[componentStart...])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !tail.isEmpty else { return nil }
    components.append(tail)
    return components
  }

  private static func outputPathRequiresComputedProperty(
    outputEnum: EnumDeclSyntax,
    context: some MacroExpansionContext
  ) -> Bool {
    if outputEnum.genericParameterClause != nil { return true }
    return context.lexicalContext.contains { lexicalContext in
      if lexicalContext.is(ExtensionDeclSyntax.self) { return true }
      if let declaration = lexicalContext.as(StructDeclSyntax.self) {
        return declaration.genericParameterClause != nil
      }
      if let declaration = lexicalContext.as(EnumDeclSyntax.self) {
        return declaration.genericParameterClause != nil
      }
      if let declaration = lexicalContext.as(ClassDeclSyntax.self) {
        return declaration.genericParameterClause != nil
      }
      if let declaration = lexicalContext.as(ActorDeclSyntax.self) {
        return declaration.genericParameterClause != nil
      }
      return false
    }
  }

  private static func outputIdentityMarkerName(
    for memberName: String,
    conditionalContext: OutputConditionalContext,
    existingNames: OutputNameTable,
    seenGeneratedNames: inout OutputNameTable
  ) -> String {
    var name = "__InnoFlowGeneratedOutputPathIdentity_\(memberName)"
    while existingNames.contains(name, overlapping: conditionalContext)
      || seenGeneratedNames.contains(name, overlapping: conditionalContext)
    {
      name.append("_")
    }
    seenGeneratedNames.insert(name, context: conditionalContext)
    return name
  }
}

enum InnoFlowOutputPathsMessage: DiagnosticMessage {
  case collision(memberName: String)
  case duplicateLabels(caseName: String)
  case unsupportedLocalBinding(caseName: String)

  var message: String {
    switch self {
    case .collision(let memberName):
      return
        "generated output path `\(memberName)` collides with another generated output path or existing static member; declare an explicit static path or rename the case"
    case .duplicateLabels(let caseName):
      return
        "case `\(caseName)` repeats a payload label; declare a manual `\(InnoFlowMacro.generatedPathBaseName(from: caseName))CasePath` or add `@InnoFlowCasePathIgnored`"
    case .unsupportedLocalBinding(let caseName):
      return
        "case `\(caseName)` uses separate external and local payload names; declare a manual `\(InnoFlowMacro.generatedPathBaseName(from: caseName))CasePath` or add `@InnoFlowCasePathIgnored`"
    }
  }

  var diagnosticID: MessageID {
    switch self {
    case .collision: .init(domain: "InnoFlowMacro", id: "OutputPathCollision")
    case .duplicateLabels: .init(domain: "InnoFlowMacro", id: "OutputPathDuplicateLabels")
    case .unsupportedLocalBinding:
      .init(domain: "InnoFlowMacro", id: "OutputPathUnsupportedLocalBinding")
    }
  }

  var severity: DiagnosticSeverity {
    switch self {
    case .collision: .error
    case .duplicateLabels, .unsupportedLocalBinding: .warning
    }
  }
}
