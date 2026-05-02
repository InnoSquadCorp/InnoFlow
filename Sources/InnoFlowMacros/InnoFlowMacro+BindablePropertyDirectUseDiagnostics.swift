// MARK: - InnoFlowMacro+BindablePropertyDirectUseDiagnostics.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

extension InnoFlowMacro {
  /// Emits a warning + Fix-It for every stored property in `State` that is
  /// declared with `BindableProperty<...>` directly instead of through the
  /// `@BindableField` property wrapper.
  ///
  /// `BindableProperty` is a low-level storage type required on the public API
  /// surface (KeyPath signatures of `Store.binding(_:to:)` and friends), so it
  /// cannot be hidden via `internal` or `@_spi`. The macro therefore enforces
  /// the authoring guideline at compile time: feature State should always say
  /// `@BindableField var step: Int`, never `var step: BindableProperty<Int>`.
  ///
  /// Only fires when the feature's State is a nested `struct`. Typealiased
  /// State (for example `typealias State = Parent.ChildState`) is silently
  /// skipped — the macro cannot inspect those stored members from the
  /// attached declaration, and the project charter requires zero false
  /// positives.
  static func diagnoseDirectBindablePropertyUses(
    in structDecl: StructDeclSyntax,
    context: some MacroExpansionContext
  ) {
    guard let stateStruct = findNestedStruct(named: "State", in: structDecl) else {
      return
    }

    for member in stateStruct.memberBlock.members {
      guard let variable = member.decl.as(VariableDeclSyntax.self) else {
        continue
      }
      // Skip variables that already use the recommended @BindableField
      // wrapper — those are validated by a different diagnostic.
      if hasBindableFieldAttribute(variable) {
        continue
      }

      for binding in variable.bindings {
        guard
          let patternName = binding.pattern
            .as(IdentifierPatternSyntax.self)?
            .identifier
            .text,
          let typeAnnotation = binding.typeAnnotation,
          let payloadType = bindablePropertyPayload(in: typeAnnotation.type)
        else {
          continue
        }

        let message = BindablePropertyDirectUseMessage.directUseDiscouraged(
          field: patternName,
          valueType: payloadType
        )

        if let replacement = bindableFieldReplacement(
          variable: variable,
          binding: binding,
          fieldName: patternName,
          payloadType: payloadType
        ) {
          context.diagnose(
            Diagnostic(
              node: Syntax(typeAnnotation),
              message: message,
              fixIt: .replace(
                message: BindablePropertyDirectUseFixIt.replaceWithBindableField(
                  field: patternName,
                  valueType: payloadType
                ),
                oldNode: variable,
                newNode: replacement
              )
            )
          )
        } else {
          context.diagnose(Diagnostic(node: Syntax(typeAnnotation), message: message))
        }
      }
    }
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

  /// Returns the inner generic argument of `BindableProperty<T>` when the
  /// type spelling is either `BindableProperty<T>` or `InnoFlow.BindableProperty<T>`.
  /// Returns `nil` for any other type.
  private static func bindablePropertyPayload(in type: TypeSyntax) -> String? {
    if let identifier = type.as(IdentifierTypeSyntax.self),
      identifier.name.text == "BindableProperty",
      let arguments = identifier.genericArgumentClause?.arguments,
      arguments.count == 1,
      let first = arguments.first
    {
      return first.argument.trimmedDescription
    }

    if let member = type.as(MemberTypeSyntax.self),
      member.name.text == "BindableProperty",
      member.baseType.trimmedDescription == "InnoFlow",
      let arguments = member.genericArgumentClause?.arguments,
      arguments.count == 1,
      let first = arguments.first
    {
      return first.argument.trimmedDescription
    }

    return nil
  }

  /// Builds a Fix-It replacement: `var step: BindableProperty<Int> = .init(1)`
  /// becomes `@BindableField var step: Int = 1`. Returns `nil` when the macro
  /// cannot rewrite the declaration safely (e.g. multiple bindings, or an
  /// initializer the macro cannot trivially unwrap).
  private static func bindableFieldReplacement(
    variable: VariableDeclSyntax,
    binding: PatternBindingSyntax,
    fieldName: String,
    payloadType: String
  ) -> VariableDeclSyntax? {
    // Only rewrite single-binding declarations to keep the Fix-It safe.
    guard variable.bindings.count == 1 else {
      return nil
    }
    guard variable.modifiers.isEmpty, variable.attributes.isEmpty else {
      return nil
    }

    let initializerSource: String
    if let initializer = binding.initializer {
      guard let unwrapped = unwrappedBindablePropertyInitializer(initializer.value) else {
        return nil
      }
      initializerSource = " = \(unwrapped)"
    } else {
      initializerSource = ""
    }

    let source = "@BindableField var \(fieldName): \(payloadType)\(initializerSource)"
    return try? VariableDeclSyntax("\(raw: source)")
  }

  /// Recovers the wrapped value spelling from an initializer that explicitly
  /// constructs a `BindableProperty`. Returns `nil` for any other expression
  /// shape so callers fall back to the original spelling.
  private static func unwrappedBindablePropertyInitializer(_ expression: ExprSyntax) -> String? {
    guard let call = expression.as(FunctionCallExprSyntax.self) else {
      return nil
    }

    let calleeIsBindableProperty: Bool
    if let calleeIdentifier = call.calledExpression.as(DeclReferenceExprSyntax.self) {
      calleeIsBindableProperty = calleeIdentifier.baseName.text == "BindableProperty"
    } else if let memberAccess = call.calledExpression.as(MemberAccessExprSyntax.self),
      memberAccess.declName.baseName.text == "BindableProperty",
      memberAccess.base?.trimmedDescription == "InnoFlow"
    {
      calleeIsBindableProperty = true
    } else {
      calleeIsBindableProperty = false
    }

    guard calleeIsBindableProperty else { return nil }

    let arguments = Array(call.arguments)
    guard arguments.count == 1, let first = arguments.first else {
      return nil
    }

    if first.label == nil || first.label?.text == "wrappedValue" {
      return first.expression.trimmedDescription
    }

    return nil
  }
}

enum BindablePropertyDirectUseMessage: DiagnosticMessage {
  case directUseDiscouraged(field: String, valueType: String)

  var message: String {
    switch self {
    case .directUseDiscouraged(let field, let valueType):
      return
        "state field `\(field)` declares `BindableProperty<\(valueType)>` directly; use `@BindableField var \(field): \(valueType)` instead — `BindableProperty` is a low-level storage type that must not be authored directly in feature State"
    }
  }

  var diagnosticID: MessageID {
    switch self {
    case .directUseDiscouraged:
      return .init(domain: "InnoFlowMacro", id: "BindablePropertyDirectUse")
    }
  }

  var severity: DiagnosticSeverity {
    .warning
  }
}

enum BindablePropertyDirectUseFixIt: FixItMessage {
  case replaceWithBindableField(field: String, valueType: String)

  var message: String {
    switch self {
    case .replaceWithBindableField(let field, let valueType):
      return "Replace with `@BindableField var \(field): \(valueType)`"
    }
  }

  var fixItID: MessageID {
    switch self {
    case .replaceWithBindableField:
      return .init(domain: "InnoFlowMacro", id: "BindablePropertyReplaceWithBindableField")
    }
  }
}
