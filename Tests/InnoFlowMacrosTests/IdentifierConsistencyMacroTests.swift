// MARK: - IdentifierConsistencyMacroTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing

#if canImport(InnoFlowMacros)
  import InnoFlowMacros
#endif

@Suite("Macro logical identifier diagnostics")
struct IdentifierConsistencyMacroTests {
  @Test(
    "phase declarations and references normalize independently",
    arguments: ["default", "`default`"])
  func phaseReferencesNormalize(reference: String) throws {
    #if canImport(InnoFlowMacros)
      let diagnostics = try phaseDiagnostics(
        cases: "`default`, `ready`, `raw phase`",
        rules:
          "From(.\(reference)) { On(.advance, to: .ready) }; From(.`ready`) { On(.advance, to: .`raw phase`) }"
      )
      #expect(diagnostics.isEmpty)
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("a genuinely missing escaped phase still fails strict totality")
  func missingPhaseStillDiagnoses() throws {
    #if canImport(InnoFlowMacros)
      let diagnostics = try phaseDiagnostics(cases: "idle, `default`", rules: "From(.idle) {}")
      #expect(diagnostics.count == 1)
      #expect(
        diagnostics.first?.diagMessage.diagnosticID
          == MessageID(domain: "InnoFlowMacro", id: "StrictPhaseUnreferencedCase"))
      #expect(diagnostics.first?.diagMessage.severity == .error)
      #expect(diagnostics.first?.message.contains("`Phase.default`") == true)
    #endif
  }

  @Test("logical generated-name collisions survive escaping", arguments: [false, true])
  func generatedCollisions(output: Bool) throws {
    #if canImport(InnoFlowMacros)
      let result = try paths(
        "enum Paths { case `raw name`(Int), `_raw name`(Int) }", output: output)
      #expect(result.diagnostics.count == 1)
      #expect(result.diagnostics.first?.diagMessage.severity == .error)
      #expect(result.diagnostics.first?.message.contains("collides") == true)
      #expect(result.source.contains("static let `raw nameCasePath`"))
      #expect(!result.source.contains("static let raw nameCasePath"))
    #endif
  }

  @Test("escaped existing static functions still collide", arguments: [false, true])
  func existingMemberCollisions(output: Bool) throws {
    #if canImport(InnoFlowMacros)
      let result = try paths(
        "enum Paths { case plain(Int); static func `plainCasePath`() {} }",
        output: output
      )
      #expect(result.diagnostics.count == 1)
      #expect(result.diagnostics.first?.message.contains("collides") == true)
      #expect(result.source.isEmpty)
    #endif
  }

  @Test("manual and ignored raw paths do not synthesize or warn", arguments: [false, true])
  func manualAndIgnoredPaths(output: Bool) throws {
    #if canImport(InnoFlowMacros)
      let result = try paths(
        """
        enum Paths {
          case `manual path`(value: Int)
          static let `manual pathCasePath` = makePath()
          @InnoFlowCasePathIgnored case `ignored path`(first: Int, second: Int)
        }
        """,
        output: output
      )
      #expect(result.diagnostics.isEmpty)
      #expect(result.source.isEmpty)
    #endif
  }

  @Test("escaped and unescaped duplicate tuple labels remain a diagnostic")
  func duplicateLabelsNormalize() throws {
    #if canImport(InnoFlowMacros)
      let result = try paths("enum Output { case pair(value: Int, `value`: String) }", output: true)
      #expect(result.diagnostics.count == 1)
      #expect(result.diagnostics.first?.message.contains("repeats a payload label") == true)
      #expect(result.source.isEmpty)
    #endif
  }

  @Test("raw names retain conditional, availability, and manual-path boundaries")
  func conditionalOutputBoundaries() throws {
    #if canImport(InnoFlowMacros)
      let result = try paths(
        """
        enum Output {
          #if os(macOS)
            case `platform value`(Int)
          #else
            case `platform value`(String)
          #endif
          case `manual value`(Int)
          #if os(macOS)
            static let `manual valueCasePath` = makePath()
          #endif
          @available(macOS 26.0, *)
          case `modern value`(Int)
          @available(*, unavailable)
          case `absent value`(Int)
        }
        """,
        output: true
      )
      #expect(result.diagnostics.isEmpty)
      #expect(result.source.contains("#if os(macOS)"))
      #expect(result.source.contains("#else"))
      #expect(
        result.source.components(separatedBy: "static let `platform valueCasePath`").count == 3)
      #expect(result.source.contains("static let `manual valueCasePath`"))
      #expect(result.source.contains("@available(macOS 26.0, *)"))
      #expect(result.source.contains("static let `modern valueCasePath`"))
      #expect(!result.source.contains("absent valueCasePath"))
    #endif
  }

  @Test("overlapping output branches continue diagnosing logical collisions")
  func overlappingConditionalCollision() throws {
    #if canImport(InnoFlowMacros)
      let result = try paths(
        """
        enum Output {
          #if os(macOS)
            case `raw name`(Int)
          #endif
          #if arch(arm64)
            case `_raw name`(Int)
          #endif
        }
        """,
        output: true
      )
      #expect(result.diagnostics.count == 1)
      #expect(result.diagnostics.first?.message.contains("collides") == true)
    #endif
  }

  @Test("spaces and punctuation do not collapse into underscore aliases")
  func distinctRawNamesStayDistinct() throws {
    #if canImport(InnoFlowMacros)
      for output in [false, true] {
        let result = try paths(
          "enum Paths { case `raw name`(Int), raw_name(Int), `raw-name`(Int), __loaded(Int) }",
          output: output)
        #expect(result.diagnostics.isEmpty)
        #expect(result.source.contains("static let `raw nameCasePath`"))
        #expect(result.source.contains("static let raw_nameCasePath"))
        #expect(result.source.contains("static let `raw-nameCasePath`"))
        #expect(result.source.contains("static let _loadedCasePath"))
      }
    #endif
  }

  #if canImport(InnoFlowMacros)
    private func phaseDiagnostics(cases: String, rules: String) throws -> [Diagnostic] {
      let file = Parser.parse(
        source: """
          @InnoFlow(phaseManaged: true, strictPhaseTotality: true)
          struct Feature {
            struct State {
              enum Phase { case \(cases) }
            }
            enum Action { case advance }
            static var phaseMap: PhaseMap<State, Action, State.Phase> { \(rules) }
            var body: some Reducer<State, Action, Never> { Reduce { _, _ in .none } }
          }
          """)
      let declaration = try #require(file.statements.first?.item.as(StructDeclSyntax.self))
      let attribute = try #require(declaration.attributes.first?.as(AttributeSyntax.self))
      let context = BasicMacroExpansionContext()
      _ = try InnoFlowMacro.expansion(
        of: attribute,
        attachedTo: declaration,
        providingExtensionsOf: IdentifierTypeSyntax(name: declaration.name),
        conformingTo: [],
        in: context
      )
      return context.diagnostics
    }

    private func paths(_ source: String, output: Bool) throws -> (
      source: String, diagnostics: [Diagnostic]
    ) {
      let file = Parser.parse(source: source)
      let declaration = try #require(file.statements.first?.item.as(EnumDeclSyntax.self))
      let context = BasicMacroExpansionContext()
      let attribute = AttributeSyntax(
        attributeName: IdentifierTypeSyntax(name: .identifier("PathMacro")))
      let members =
        try output
        ? InnoFlowOutputPathsMacro.expansion(
          of: attribute, providingMembersOf: declaration, in: context)
        : InnoFlowActionPathsMacro.expansion(
          of: attribute, providingMembersOf: declaration, in: context)
      return (members.map(\.description).joined(separator: "\n"), context.diagnostics)
    }
  #endif
}
