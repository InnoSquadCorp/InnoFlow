// MARK: - InnoFlowMacro+BodySignature.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import SwiftSyntax
import SwiftSyntaxMacros

extension InnoFlowMacro {
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

    if !isNestedTypeReference(args[0].argument, named: "State") {
      issues.append(
        "first generic parameter must be `State` (or `Self.State`), found `\(args[0].argument.trimmedDescription)`"
      )
    }

    if !isNestedTypeReference(args[1].argument, named: "Action") {
      issues.append(
        "second generic parameter must be `Action` (or `Self.Action`), found `\(args[1].argument.trimmedDescription)`"
      )
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

  /// Returns `true` when `argument` spells a reference to the nested type
  /// `named` — either the bare identifier (`State`) or the explicitly
  /// qualified `Self.State`. Both resolve to the same nested declaration, so
  /// rejecting the qualified spelling would refuse legitimate authoring.
  private static func isNestedTypeReference(
    _ argument: some SyntaxProtocol,
    named expected: String
  ) -> Bool {
    if let identifier = argument.as(IdentifierTypeSyntax.self) {
      return identifier.name.text == expected && identifier.genericArgumentClause == nil
    }
    if let member = argument.as(MemberTypeSyntax.self),
      member.name.text == expected,
      member.genericArgumentClause == nil,
      let base = member.baseType.as(IdentifierTypeSyntax.self),
      base.name.text == "Self",
      base.genericArgumentClause == nil
    {
      return true
    }
    return false
  }
}
