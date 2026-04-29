// MARK: - InnoFlowMacro+Support.swift
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
    diagnoseMissingBindableFieldSetters(in: declaration, context: context)
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

  static func synthesizedActionPathDeclarations(
    in actionEnum: EnumDeclSyntax,
    context: some MacroExpansionContext
  ) -> [DeclSyntax] {
    let existingNames = Set<String>(
      actionEnum.memberBlock.members.compactMap { member in
        if let variableDecl = member.decl.as(VariableDeclSyntax.self) {
          guard variableDecl.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) })
          else {
            return nil
          }
          return variableDecl.bindings.first?
            .pattern
            .as(IdentifierPatternSyntax.self)?
            .identifier
            .text
        }

        if let functionDecl = member.decl.as(FunctionDeclSyntax.self) {
          guard functionDecl.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) })
          else {
            return nil
          }
          return functionDecl.name.text
        }

        return nil
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

    if parameters.count == 2,
      let idParameter = parameters.first,
      let actionParameter = parameters.last,
      idParameter.firstName?.text == "id",
      actionParameter.firstName?.text == "action",
      isCollectionActionLikeType(actionParameter.type.trimmedDescription)
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

    return nil
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

  static func diagnoseExplicitReduceIfNeeded(
    in declaration: StructDeclSyntax,
    anchoredAt anchor: some SyntaxProtocol,
    context: some MacroExpansionContext
  ) -> Bool {
    guard let reduceFunction = findReduceFunction(in: declaration) else {
      return false
    }

    let diagnostic = explicitReduceDiagnostic(
      anchoredAt: anchor,
      reduceFunction: reduceFunction,
      hasBodyProperty: findBodyProperty(in: declaration) != nil
    )
    context.diagnose(diagnostic)
    return true
  }

  private static func explicitReduceDiagnostic(
    anchoredAt anchor: some SyntaxProtocol,
    reduceFunction: FunctionDeclSyntax,
    hasBodyProperty: Bool
  ) -> Diagnostic {
    let message = InnoFlowMacroMessage.explicitReduceUnsupported

    guard !hasBodyProperty,
      isCanonicalReduceFunction(reduceFunction),
      let replacement = bodyReplacement(for: reduceFunction)
    else {
      return Diagnostic(node: anchor, message: message)
    }

    return Diagnostic(
      node: anchor,
      message: message,
      fixIt: .replace(
        message: InnoFlowMacroFixIt.replaceExplicitReduce,
        oldNode: reduceFunction,
        newNode: replacement
      )
    )
  }

  private static func isCanonicalReduceFunction(_ function: FunctionDeclSyntax) -> Bool {
    guard function.name.text == "reduce",
      function.signature.effectSpecifiers == nil,
      let body = function.body,
      !body.statements.isEmpty
    else {
      return false
    }

    let parameters = Array(function.signature.parameterClause.parameters)
    guard parameters.count == 2 else { return false }
    guard isCanonicalIntoParameter(parameters[0]),
      isCanonicalActionParameter(parameters[1]),
      isCanonicalEffectTaskReturn(function.signature.returnClause?.type)
    else {
      return false
    }

    return true
  }

  private static func isCanonicalIntoParameter(_ parameter: FunctionParameterSyntax) -> Bool {
    guard parameter.firstName.text == "into",
      parameter.secondName?.text == "state"
    else {
      return false
    }

    return parameter.type.trimmedDescription == "inout State"
  }

  private static func isCanonicalActionParameter(_ parameter: FunctionParameterSyntax) -> Bool {
    guard parameter.firstName.text == "action",
      parameter.secondName == nil,
      let identifier = parameter.type.as(IdentifierTypeSyntax.self)
    else {
      return false
    }

    return identifier.name.text == "Action"
  }

  private static func isCanonicalEffectTaskReturn(_ type: TypeSyntax?) -> Bool {
    guard let identifier = type?.as(IdentifierTypeSyntax.self),
      identifier.name.text == "EffectTask",
      let genericArguments = identifier.genericArgumentClause
    else {
      return false
    }

    let arguments = Array(genericArguments.arguments)
    guard arguments.count == 1,
      let actionType = arguments[0].argument.as(IdentifierTypeSyntax.self)
    else {
      return false
    }

    return actionType.name.text == "Action"
  }

  private static func bodyReplacement(for function: FunctionDeclSyntax) -> VariableDeclSyntax? {
    guard let body = function.body else { return nil }

    let renderedStatements = indentCodeBlockItems(body.statements, spaces: 8)
    return try? VariableDeclSyntax(
      """
      var body: some Reducer<State, Action> {
          Reduce { state, action in
      \(raw: renderedStatements)
          }
      }
      """
    )
  }

  private static func indentCodeBlockItems(
    _ items: CodeBlockItemListSyntax,
    spaces: Int
  ) -> String {
    let prefix = String(repeating: " ", count: spaces)

    return items.map { item in
      item.description
        .trimmingCharacters(in: .newlines)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { line in
          let lineText = String(line)
          if lineText.trimmingCharacters(in: .whitespaces).isEmpty {
            return prefix
          }

          let leadingWhitespace = String(lineText.prefix { $0.isWhitespace })
          let normalizedLeadingWhitespace = leadingWhitespace.replacingOccurrences(
            of: "\t",
            with: String(repeating: " ", count: 4)
          )
          let content = String(lineText.dropFirst(leadingWhitespace.count))
          return prefix + normalizedLeadingWhitespace + content
        }
        .joined(separator: "\n")
    }
    .joined(separator: "\n")
  }

  static func bodySignatureIssues(_ variable: VariableDeclSyntax) -> [String] {
    var issues: [String] = []
    guard let binding = variable.bindings.first else {
      issues.append("missing `body` binding")
      return issues
    }

    guard let typeAnnotation = binding.typeAnnotation else {
      issues.append("`body` must declare an explicit `some Reducer<State, Action>` type")
      return issues
    }

    let type = typeAnnotation.type

    guard let someOrAny = type.as(SomeOrAnyTypeSyntax.self) else {
      issues.append(
        "`body` type `\(type.trimmedDescription)` must be an opaque type (`some Reducer<State, Action>`)"
      )
      return issues
    }

    guard someOrAny.someOrAnySpecifier.tokenKind == .keyword(.some) else {
      issues.append("`body` must use `some` (not `\(someOrAny.someOrAnySpecifier.text)`)")
      return issues
    }

    guard let identifierType = someOrAny.constraint.as(IdentifierTypeSyntax.self) else {
      issues.append(
        "`body` constraint `\(someOrAny.constraint.trimmedDescription)` is not a recognized type")
      return issues
    }

    guard identifierType.name.text == "Reducer" else {
      issues.append("`body` type must constrain to `Reducer`, found `\(identifierType.name.text)`")
      return issues
    }

    guard let genericArgs = identifierType.genericArgumentClause else {
      issues.append("`body` type must specify `Reducer<State, Action>`")
      return issues
    }

    let args = Array(genericArgs.arguments)
    guard args.count == 2 else {
      issues.append(
        "`body` must have exactly 2 generic parameters (State, Action), found \(args.count)")
      return issues
    }

    if let first = args[0].argument.as(IdentifierTypeSyntax.self) {
      if first.name.text != "State" {
        issues.append("first generic parameter must be `State`, found `\(first.name.text)`")
      }
    } else {
      issues.append("first generic parameter must be `State`")
    }

    if let second = args[1].argument.as(IdentifierTypeSyntax.self) {
      if second.name.text != "Action" {
        issues.append("second generic parameter must be `Action`, found `\(second.name.text)`")
      }
    } else {
      issues.append("second generic parameter must be `Action`")
    }

    guard let accessorBlock = binding.accessorBlock else {
      issues.append("`body` must be a computed property returning reducer composition")
      return issues
    }

    switch accessorBlock.accessors {
    case .getter:
      return issues

    case .accessors(let accessors):
      let hasGetter = accessors.contains { accessor in
        accessor.accessorSpecifier.tokenKind == .keyword(.get)
      }
      if !hasGetter {
        issues.append("`body` must provide a getter returning reducer composition")
      }
      return issues
    }
  }

  // Nested collection routes often use child action types like `TodoAction`.
  // Treating `*Action` as collection-like preserves canonical synthesis for
  // those feature-local wrappers without forcing a single `CollectionAction`
  // type name across sample and app code.
  private static func isCollectionActionLikeType(_ typeName: String) -> Bool {
    typeName == "Action"
      || typeName.hasSuffix(".Action")
      || typeName.hasSuffix("Action")
  }
}

private struct SynthesizedActionPathMember {
  let declaration: String
}

extension Trivia {
  /// Returns just the indentation portion (trailing spaces/tabs) of the
  /// trivia that follows the last newline. Used to inherit enum member
  /// indentation when synthesising a new `case` via Fix-It.
  var firstIndentation: Trivia {
    var indent: [TriviaPiece] = []
    for piece in pieces.reversed() {
      switch piece {
      case .newlines, .carriageReturns, .carriageReturnLineFeeds:
        return Trivia(pieces: indent.reversed())
      case .spaces, .tabs:
        indent.append(piece)
      default:
        indent.removeAll()
      }
    }
    return Trivia(pieces: indent.reversed())
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

private enum InnoFlowMacroMessage: DiagnosticMessage {
  case explicitReduceUnsupported

  var message: String {
    switch self {
    case .explicitReduceUnsupported:
      return
        "@InnoFlow no longer supports explicit `reduce(into:action:)` authoring; declare `var body: some Reducer<State, Action>` instead"
    }
  }

  var diagnosticID: MessageID {
    switch self {
    case .explicitReduceUnsupported:
      return .init(domain: "InnoFlowMacro", id: "ExplicitReduceUnsupported")
    }
  }

  var severity: DiagnosticSeverity {
    .error
  }
}

private enum InnoFlowActionPathsMessage: DiagnosticMessage {
  case leadingUnderscoreCollision

  var message: String {
    switch self {
    case .leadingUnderscoreCollision:
      return
        "generated action path name collides after stripping leading underscore; declare an explicit static alias or rename the case"
    }
  }

  var diagnosticID: MessageID {
    switch self {
    case .leadingUnderscoreCollision:
      return .init(domain: "InnoFlowMacro", id: "LeadingUnderscoreCollision")
    }
  }

  var severity: DiagnosticSeverity {
    .error
  }
}

private enum InnoFlowMacroFixIt: FixItMessage {
  case replaceExplicitReduce

  var message: String {
    switch self {
    case .replaceExplicitReduce:
      return "replace explicit reduce with body-based reducer composition"
    }
  }

  var fixItID: MessageID {
    switch self {
    case .replaceExplicitReduce:
      return .init(domain: "InnoFlowMacro", id: "ReplaceExplicitReduce")
    }
  }
}
