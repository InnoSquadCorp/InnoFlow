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
  static func isCollectionActionLikeType(_ typeName: String) -> Bool {
    typeName == "Action"
      || typeName.hasSuffix(".Action")
      || typeName.hasSuffix("Action")
  }
}
