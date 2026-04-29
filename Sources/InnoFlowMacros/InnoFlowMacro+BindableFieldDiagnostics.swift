// MARK: - InnoFlowMacro+BindableFieldDiagnostics.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

extension InnoFlowMacro {
  /// Emits a warning + Fix-It for every `@BindableField` stored property in
  /// `State` that lacks a matching `case set<Field>(Value)` case in `Action`.
  ///
  /// Only fires when the feature's State is a nested `struct` and Action is a
  /// nested `enum`. Typealiased State / Action (for example `typealias Action
  /// = Parent.ChildAction` in a row feature) is silently skipped — the macro
  /// cannot inspect those stored members from the attached declaration, and
  /// the project charter requires zero false positives.
  static func diagnoseMissingBindableFieldSetters(
    in structDecl: StructDeclSyntax,
    context: some MacroExpansionContext
  ) {
    guard let stateStruct = findNestedStruct(named: "State", in: structDecl) else {
      return
    }
    guard let actionEnum = findNestedEnum(named: "Action", in: structDecl) else {
      return
    }

    let bindableFields = collectBindableFields(in: stateStruct)
    guard !bindableFields.isEmpty else {
      return
    }

    let existingSetters = collectActionSetters(in: actionEnum)

    for field in bindableFields {
      let bareFieldName =
        field.name.hasPrefix("_") && field.name.count > 1
        ? String(field.name.dropFirst())
        : field.name
      let capitalizedBareFieldName =
        "\(bareFieldName.prefix(1).uppercased())\(bareFieldName.dropFirst())"
      let expectedCaseName = "set\(capitalizedBareFieldName)"

      let matchingSetters = matchingActionSetters(for: bareFieldName, in: existingSetters)
      if matchingSetters.contains(where: { setterSatisfiesBindableField($0, field: field) }) {
        continue
      }

      emitMissingBindableFieldSetterDiagnostic(
        field: field,
        expectedCaseName: expectedCaseName,
        actionEnum: actionEnum,
        canAddFixIt: matchingSetters.isEmpty,
        context: context
      )
    }
  }

  private static func collectBindableFields(in stateStruct: StructDeclSyntax) -> [BindableFieldInfo]
  {
    var results: [BindableFieldInfo] = []

    for member in stateStruct.memberBlock.members {
      guard let variable = member.decl.as(VariableDeclSyntax.self) else {
        continue
      }
      guard hasBindableFieldAttribute(variable) else {
        continue
      }

      for binding in variable.bindings {
        guard
          let patternName = binding.pattern
            .as(IdentifierPatternSyntax.self)?
            .identifier
            .text
        else {
          continue
        }

        let inferredType: String?
        if let typeAnnotation = binding.typeAnnotation {
          inferredType = typeAnnotation.type.trimmedDescription
        } else if let initializerValue = binding.initializer?.value {
          inferredType = inferLiteralType(initializerValue)
        } else {
          inferredType = nil
        }

        results.append(
          BindableFieldInfo(
            name: patternName,
            inferredType: inferredType,
            node: Syntax(variable)
          )
        )
      }
    }

    return results
  }

  private static func hasBindableFieldAttribute(_ variable: VariableDeclSyntax) -> Bool {
    for element in variable.attributes {
      guard let attribute = element.as(AttributeSyntax.self) else { continue }
      if let identifier = attribute.attributeName.as(IdentifierTypeSyntax.self),
        identifier.name.text == "BindableField"
      {
        return true
      }
    }
    return false
  }

  private static func inferLiteralType(_ expression: ExprSyntax) -> String? {
    if expression.is(IntegerLiteralExprSyntax.self) { return "Int" }
    if expression.is(FloatLiteralExprSyntax.self) { return "Double" }
    if expression.is(StringLiteralExprSyntax.self) { return "String" }
    if expression.is(BooleanLiteralExprSyntax.self) { return "Bool" }
    return nil
  }

  private static func collectActionSetters(in actionEnum: EnumDeclSyntax) -> [ActionSetterInfo] {
    var setters: [ActionSetterInfo] = []
    for member in actionEnum.memberBlock.members {
      guard let enumCase = member.decl.as(EnumCaseDeclSyntax.self) else {
        continue
      }
      for element in enumCase.elements {
        if let setter = actionSetterInfo(for: element) {
          setters.append(setter)
        }
      }
    }
    return setters
  }

  private static func actionSetterInfo(for element: EnumCaseElementSyntax) -> ActionSetterInfo? {
    let caseName = element.name.text
    let suffixLowercased: String
    if caseName.hasPrefix("_set") {
      suffixLowercased = String(caseName.dropFirst(4)).lowercased()
    } else if caseName.hasPrefix("set") {
      suffixLowercased = String(caseName.dropFirst(3)).lowercased()
    } else {
      return nil
    }

    let parameters = Array(element.parameterClause?.parameters ?? [])
    let singlePayloadType = parameters.count == 1 ? parameters[0].type.trimmedDescription : nil
    return ActionSetterInfo(
      suffixLowercased: suffixLowercased,
      payloadCount: parameters.count,
      singlePayloadType: singlePayloadType
    )
  }

  private static func matchingActionSetters(
    for fieldName: String,
    in setters: [ActionSetterInfo]
  ) -> [ActionSetterInfo] {
    let fieldLower = fieldName.lowercased()
    return setters.filter { $0.suffixLowercased == fieldLower }
  }

  private static func setterSatisfiesBindableField(
    _ setter: ActionSetterInfo,
    field: BindableFieldInfo
  ) -> Bool {
    guard setter.payloadCount == 1 else {
      return false
    }

    guard let fieldType = field.inferredType else {
      // Without a trustworthy field type, accept a same-name single-payload
      // setter and avoid guessing at a type mismatch.
      return true
    }

    return setter.singlePayloadType == fieldType
  }

  private static func emitMissingBindableFieldSetterDiagnostic(
    field: BindableFieldInfo,
    expectedCaseName: String,
    actionEnum: EnumDeclSyntax,
    canAddFixIt: Bool,
    context: some MacroExpansionContext
  ) {
    let message = BindableFieldDiagnosticMessage.missingSetter(
      field: field.name,
      expectedCase: expectedCaseName,
      valueType: field.inferredType
    )

    if canAddFixIt,
      let inferredType = field.inferredType,
      let replacement = actionEnumWithAppendedCase(
        actionEnum,
        caseName: expectedCaseName,
        payloadType: inferredType
      )
    {
      context.diagnose(
        Diagnostic(
          node: field.node,
          message: message,
          fixIt: .replace(
            message: BindableFieldDiagnosticFixIt.addSetterCase(
              caseName: expectedCaseName,
              valueType: inferredType
            ),
            oldNode: actionEnum,
            newNode: replacement
          )
        )
      )
    } else {
      context.diagnose(Diagnostic(node: field.node, message: message))
    }
  }

  private static func actionEnumWithAppendedCase(
    _ actionEnum: EnumDeclSyntax,
    caseName: String,
    payloadType: String
  ) -> EnumDeclSyntax? {
    let newCaseSource = "case \(caseName)(\(payloadType))"
    guard let newCaseDecl = try? EnumCaseDeclSyntax("\(raw: newCaseSource)") else {
      return nil
    }

    var existingMembers = actionEnum.memberBlock.members

    let lastMember = existingMembers.last
    let indentation =
      lastMember?.decl.leadingTrivia.firstIndentation ?? Trivia(pieces: [.spaces(2)])

    let newMemberItem = MemberBlockItemSyntax(
      decl: DeclSyntax(
        newCaseDecl
          .with(\.leadingTrivia, Trivia(pieces: [.newlines(1)]) + indentation)
          .with(\.trailingTrivia, [])
      )
    )

    if var lastItem = existingMembers.last {
      // Preserve the last member's trailing newline so the appended case does
      // not collapse onto the previous line.
      if lastItem.trailingTrivia.isEmpty {
        lastItem = lastItem.with(\.trailingTrivia, Trivia(pieces: [.newlines(1)]))
        let lastIndex = existingMembers.index(before: existingMembers.endIndex)
        existingMembers = existingMembers.with(\.[lastIndex], lastItem)
      }
    }

    existingMembers.append(newMemberItem)

    let updatedBlock = actionEnum.memberBlock.with(\.members, existingMembers)
    return actionEnum.with(\.memberBlock, updatedBlock)
  }
}

private struct BindableFieldInfo {
  let name: String
  let inferredType: String?
  let node: Syntax
}

private struct ActionSetterInfo {
  let suffixLowercased: String
  let payloadCount: Int
  let singlePayloadType: String?
}

enum BindableFieldDiagnosticMessage: DiagnosticMessage {
  case missingSetter(field: String, expectedCase: String, valueType: String?)

  var message: String {
    switch self {
    case .missingSetter(let field, let expectedCase, let valueType):
      let payload = valueType ?? "Value"
      return
        "`@BindableField var \(field)` has no matching `case \(expectedCase)(\(payload))` in `Action` — `store.binding(\\.$\(field), to:)` requires a single `\(payload)` payload setter"
    }
  }

  var diagnosticID: MessageID {
    switch self {
    case .missingSetter:
      return .init(domain: "InnoFlowMacro", id: "BindableFieldMissingSetter")
    }
  }

  var severity: DiagnosticSeverity {
    .warning
  }
}

enum BindableFieldDiagnosticFixIt: FixItMessage {
  case addSetterCase(caseName: String, valueType: String)

  var message: String {
    switch self {
    case .addSetterCase(let caseName, let valueType):
      return "Add `case \(caseName)(\(valueType))` to `Action`"
    }
  }

  var fixItID: MessageID {
    switch self {
    case .addSetterCase:
      return .init(domain: "InnoFlowMacro", id: "BindableFieldAddSetterCase")
    }
  }
}
