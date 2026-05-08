// MARK: - InnoFlowMacro+SharedContext.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// A shared analysis snapshot of a `@InnoFlow`-annotated struct.
///
/// Multiple diagnostic passes (CasePath synthesis, BindableField checks,
/// PhaseTotality, etc.) all start from `State` and `Action` lookups. The
/// snapshot caches each lookup as one of `NestedTypeKind` so subsequent
/// passes do not re-traverse the member list and so the macro can surface
/// `info`-level diagnostics for kinds it intentionally skips (the
/// `typealias` case in particular).
struct InnoFlowMacroAnalysisContext {
  enum NestedTypeKind {
    case missing
    case enumDecl(EnumDeclSyntax)
    case structDecl(StructDeclSyntax)
    case classDecl(ClassDeclSyntax)
    case typealiasDecl(TypeAliasDeclSyntax)
  }

  let stateKind: NestedTypeKind
  let actionKind: NestedTypeKind

  static func make(from structDecl: StructDeclSyntax) -> Self {
    Self(
      stateKind: detectNestedType(named: "State", in: structDecl),
      actionKind: detectNestedType(named: "Action", in: structDecl)
    )
  }

  private static func detectNestedType(
    named typeName: String,
    in declaration: StructDeclSyntax
  ) -> NestedTypeKind {
    for member in declaration.memberBlock.members {
      if let enumDecl = member.decl.as(EnumDeclSyntax.self), enumDecl.name.text == typeName {
        return .enumDecl(enumDecl)
      }
      if let structDecl = member.decl.as(StructDeclSyntax.self), structDecl.name.text == typeName {
        return .structDecl(structDecl)
      }
      if let classDecl = member.decl.as(ClassDeclSyntax.self), classDecl.name.text == typeName {
        return .classDecl(classDecl)
      }
      if let aliasDecl = member.decl.as(TypeAliasDeclSyntax.self),
        aliasDecl.name.text == typeName
      {
        return .typealiasDecl(aliasDecl)
      }
    }
    return .missing
  }
}

extension InnoFlowMacro {
  /// Surfaces `note`-level diagnostics for nested `State` / `Action`
  /// declarations that opt the type out of one or more diagnostic passes.
  ///
  /// The macro intentionally skips BindableField, CasePath synthesis, and
  /// PhaseTotality diagnostics for `typealias`-defined members — those
  /// declarations are common in row features (`typealias Action =
  /// Parent.ChildAction`) and the macro cannot inspect their underlying
  /// members from the attached declaration. Surfacing the skip as a `note`
  /// removes the silent-skip footgun without escalating it to a warning that
  /// would force authors to suppress legitimate row-feature wiring.
  static func emitTypealiasInfoDiagnostics(
    in declaration: StructDeclSyntax,
    context: some MacroExpansionContext
  ) {
    let analysis = InnoFlowMacroAnalysisContext.make(from: declaration)

    if case .typealiasDecl(let aliasDecl) = analysis.actionKind {
      context.diagnose(
        Diagnostic(
          node: aliasDecl,
          message: InnoFlowSharedContextDiagnostic.typealiasActionSkipped
        )
      )
    }

    if case .typealiasDecl(let aliasDecl) = analysis.stateKind {
      context.diagnose(
        Diagnostic(
          node: aliasDecl,
          message: InnoFlowSharedContextDiagnostic.typealiasStateSkipped
        )
      )
    }
  }
}

enum InnoFlowSharedContextDiagnostic: DiagnosticMessage {
  case typealiasActionSkipped
  case typealiasStateSkipped

  var message: String {
    switch self {
    case .typealiasActionSkipped:
      return
        "@InnoFlow skips CasePath synthesis and phase-totality diagnostics for `Action` because it is declared as a `typealias`. Define `Action` as a nested `enum` directly inside this type to enable those diagnostics."
    case .typealiasStateSkipped:
      return
        "@InnoFlow skips `@BindableField` and `BindableProperty` diagnostics for `State` because it is declared as a `typealias`. Define `State` as a nested `struct` directly inside this type to enable those diagnostics."
    }
  }

  var diagnosticID: MessageID {
    switch self {
    case .typealiasActionSkipped:
      return .init(domain: "InnoFlowMacro", id: "TypealiasActionSkipped")
    case .typealiasStateSkipped:
      return .init(domain: "InnoFlowMacro", id: "TypealiasStateSkipped")
    }
  }

  var severity: DiagnosticSeverity {
    .note
  }
}
