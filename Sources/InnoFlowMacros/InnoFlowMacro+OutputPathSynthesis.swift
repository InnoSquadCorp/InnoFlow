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
        self = .atom(source)
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

  private struct OutputConditionalContext {
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

  private struct OutputNameTable {
    private var contextsByName: [String: [OutputConditionalContext]] = [:]

    mutating func insert(_ name: String, context: OutputConditionalContext) {
      contextsByName[name, default: []].append(context)
    }

    func contains(_ name: String, overlapping context: OutputConditionalContext) -> Bool {
      contextsByName[name]?.contains { $0.overlaps(context) } == true
    }

    func contexts(_ name: String, overlapping context: OutputConditionalContext)
      -> [OutputConditionalContext]
    {
      contextsByName[name]?.filter { $0.overlaps(context) } ?? []
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
    return synthesizedOutputPathSources(
      in: outputEnum.memberBlock.members,
      conditionalContext: .init(),
      accessPrefix: accessPrefix,
      requiresComputedProperty: requiresComputedProperty,
      existingNames: existingNames,
      manualPathNames: manualPathNames,
      seenGeneratedNames: &seenGeneratedNames,
      context: context
    ).map(DeclSyntax.init(stringLiteral:))
  }

  private static func synthesizedOutputPathSources(
    in members: MemberBlockItemListSyntax,
    conditionalContext: OutputConditionalContext,
    accessPrefix: String,
    requiresComputedProperty: Bool,
    existingNames: OutputNameTable,
    manualPathNames: OutputNameTable,
    seenGeneratedNames: inout OutputNameTable,
    context: some MacroExpansionContext
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
          let memberName = "\(outputPathBaseName(from: element.name.text))CasePath"
          let manualContexts = manualPathNames.contexts(
            memberName,
            overlapping: conditionalContext
          )
          let exclusionContexts =
            manualContexts
            + (unavailableContexts + ignoredContexts).filter {
              $0.overlaps(conditionalContext)
            }
          if exclusionContexts.contains(where: { conditionalContext.isCovered(by: $0) }) {
            continue
          }
          let generationContext = conditionalContext.excluding(exclusionContexts)
          guard generationContext.isSatisfiable else { continue }

          guard
            !diagnoseOutputPathCollision(
              memberName: memberName,
              element: element,
              conditionalContext: generationContext,
              existingNames: existingNames,
              manualPathNames: manualPathNames,
              seenGeneratedNames: &seenGeneratedNames,
              context: context
            )
          else { continue }

          guard
            let source = synthesizedOutputPathSource(
              for: element,
              memberName: memberName,
              availabilityPrefix: availabilityPrefix,
              conditionalContext: generationContext,
              accessPrefix: accessPrefix,
              requiresComputedProperty: requiresComputedProperty,
              existingNames: existingNames,
              seenGeneratedNames: &seenGeneratedNames,
              context: context
            )
          else { continue }
          if exclusionContexts.isEmpty {
            declarations.append(contentsOf: source)
          } else {
            let exclusionCondition =
              exclusionContexts
              .map(\.conditionSource)
              .map { "(\($0))" }
              .joined(separator: " || ")
            declarations.append(
              "#if !(\(exclusionCondition))\n\(source.joined(separator: "\n"))\n#endif"
            )
          }
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
            synthesizedOutputPathSources(
              in: $0,
              conditionalContext: clauseContext,
              accessPrefix: accessPrefix,
              requiresComputedProperty: requiresComputedProperty,
              existingNames: existingNames,
              manualPathNames: manualPathNames,
              seenGeneratedNames: &seenGeneratedNames,
              context: context
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
    let caseName = element.name.text
    let parameters = Array(element.parameterClause?.parameters ?? [])

    if parameters.contains(where: { $0.secondName != nil }) {
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
      return name
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
      embedBody = ".\(caseName)"
      extractBody =
        "guard case .\(caseName) = output else { return nil }\nreturn .some(())"

    case 1:
      let parameter = parameters[0]
      valueType = parameter.type.trimmedDescription
      let label = outputParameterLabel(parameter)
      embedBody = label.map { ".\(caseName)(\($0): value)" } ?? ".\(caseName)(value)"
      extractBody =
        "guard case .\(caseName)(let value) = output else { return nil }\nreturn .some(value)"

    default:
      valueType =
        "("
        + parameters.enumerated().map { index, parameter in
          let type = parameter.type.trimmedDescription
          return outputParameterLabel(parameter).map { "\($0): \(type)" } ?? type
        }.joined(separator: ", ") + ")"
      let arguments = parameters.enumerated().map { index, parameter in
        let access = outputParameterLabel(parameter).map { "value.\($0)" } ?? "value.\(index)"
        return outputParameterLabel(parameter).map { "\($0): \(access)" } ?? access
      }.joined(separator: ", ")
      embedBody = ".\(caseName)(\(arguments))"
      let bindings = parameters.indices.map { "value\($0)" }.joined(separator: ", ")
      let tupleValues = parameters.enumerated().map { index, parameter in
        outputParameterLabel(parameter).map { "\($0): value\(index)" } ?? "value\(index)"
      }.joined(separator: ", ")
      extractBody =
        "guard case let .\(caseName)(\(bindings)) = output else { return nil }\nreturn .some((\(tupleValues)))"
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
        \(accessPrefix)static var \(memberName): CasePath<Self, \(valueType)> {
          CasePath<Self, \(valueType)>._innoFlowGenerated(
            marker: \(markerName).self,
            embed: { value in
              \(embedBody)
            },
            extract: { output in
              \(extractBody)
            }
          )
        }
        """
      return ["private enum \(markerName) {}", availabilityPrefix + declaration]
    }

    declaration =
      """
      \(accessPrefix)static let \(memberName) = CasePath<Self, \(valueType)>(
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

  private static func outputParameterLabel(_ parameter: EnumCaseParameterSyntax) -> String? {
    guard let name = parameter.firstName?.text, name != "_" else { return nil }
    return name
  }

  private static func outputExistingMemberNames(in outputEnum: EnumDeclSyntax) -> OutputNameTable {
    var names = OutputNameTable()
    collectOutputNames(
      in: outputEnum.memberBlock.members,
      conditionalContext: .init(),
      includeOnlyStaticVariables: false,
      names: &names
    )
    return names
  }

  private static func outputManualPathNames(in outputEnum: EnumDeclSyntax) -> OutputNameTable {
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
        names.insert(name, context: conditionalContext)
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
        if outputAttributeName(attribute) == "available" {
          sources.append(attribute.trimmedDescription)
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
      return identifier.name.text
    }
    if let member = attribute.attributeName.as(MemberTypeSyntax.self) {
      return member.name.text
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

  private static func outputPathBaseName(from caseName: String) -> String {
    let identifier: String
    if caseName.hasPrefix("`"), caseName.hasSuffix("`"), caseName.count >= 2 {
      identifier = String(caseName.dropFirst().dropLast())
    } else {
      identifier = caseName
    }
    return identifier.hasPrefix("_") && identifier.count > 1
      ? String(identifier.dropFirst())
      : identifier
  }

  private static func diagnoseOutputPathCollision(
    memberName: String,
    element: EnumCaseElementSyntax,
    conditionalContext: OutputConditionalContext,
    existingNames: OutputNameTable,
    manualPathNames: OutputNameTable,
    seenGeneratedNames: inout OutputNameTable,
    context: some MacroExpansionContext
  ) -> Bool {
    guard
      (existingNames.contains(memberName, overlapping: conditionalContext)
        && !manualPathNames.contains(memberName, overlapping: conditionalContext))
        || seenGeneratedNames.contains(memberName, overlapping: conditionalContext)
    else {
      seenGeneratedNames.insert(memberName, context: conditionalContext)
      return false
    }
    context.diagnose(
      Diagnostic(node: Syntax(element.name), message: InnoFlowOutputPathsMessage.collision)
    )
    return true
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
  case collision
  case duplicateLabels(caseName: String)
  case unsupportedLocalBinding(caseName: String)

  var message: String {
    switch self {
    case .collision:
      return
        "generated output path name collides with another generated output path or existing static member; declare an explicit static path or rename the case"
    case .duplicateLabels(let caseName):
      return
        "case `\(caseName)` repeats a payload label; declare a manual `<caseName>CasePath` or add `@InnoFlowCasePathIgnored`"
    case .unsupportedLocalBinding(let caseName):
      return
        "case `\(caseName)` uses separate external and local payload names; declare a manual `<caseName>CasePath` or add `@InnoFlowCasePathIgnored`"
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
