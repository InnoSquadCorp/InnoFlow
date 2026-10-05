// MARK: - ConditionalMacroConsistencyTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import SwiftDiagnostics
import SwiftIfConfig
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing

#if canImport(InnoFlowMacros)
  import InnoFlowMacros
#endif

@Suite("Conditional macro consistency")
struct ConditionalMacroConsistencyTests {
  @Test("equivalent OS spellings still overlap", arguments: ["os(OSX)", "os( macOS )"])
  func equivalentOSConditionsCollide(secondCondition: String) throws {
    #if canImport(InnoFlowMacros)
      let result = try outputPaths(
        """
        enum Output {
          #if os(macOS)
            case value(Int)
          #endif
          #if \(secondCondition)
            case _value(Int)
          #endif
        }
        """)
      #expect(result.diagnostics.count == 1)
      #expect(result.diagnostics.first?.message.contains("`valueCasePath` collides") == true)
    #endif
  }

  @Test("equivalent OS spellings in complementary conditions stay exclusive")
  func complementaryOSConditionsDoNotCollide() throws {
    #if canImport(InnoFlowMacros)
      let result = try outputPaths(
        """
        enum Output {
          #if os(OSX)
            case value(Int)
          #endif
          #if !os( macOS )
            case value(String)
          #endif
        }
        """)
      #expect(result.diagnostics.isEmpty)
      #expect(result.source.components(separatedBy: "static let valueCasePath").count == 3)
    #endif
  }

  @Test("helper availability retains deprecation without a constructor rename")
  func outputRenameDoesNotRetargetAPath() throws {
    #if canImport(InnoFlowMacros)
      let result = try outputPaths(
        """
        enum Output {
          @available(*, deprecated, renamed: "ready", message: "Use the new event")
          case old(Int)
          case ready(Int)
        }
        """)
      #expect(result.diagnostics.isEmpty)
      #expect(result.source.contains("deprecated"))
      #expect(result.source.contains("message: \"Use the new event\""))
      #expect(!result.source.contains("renamed:"))
      #expect(result.source.contains("oldCasePath"))
    #endif
  }

  @Test("strict totality checks active conditional cases only")
  func phaseCasesFollowTheCompilerConfiguration() throws {
    #if canImport(InnoFlowMacros)
      let cases = """
        #if os(macOS)
          case desktop
        #else
          case idle
        #endif
        """
      let linux = try phaseDiagnostics(cases: cases, rules: "From(.idle) {}", targetOS: "Linux")
      #expect(linux.isEmpty)
      let mac = try phaseDiagnostics(cases: cases, rules: "From(.idle) {}", targetOS: "macOS")
      #expect(mac.count == 1)
      #expect(mac.first?.message.contains("`Phase.desktop`") == true)
    #endif
  }

  @Test("an inactive rule cannot hide a missing active phase")
  func inactiveRulesDoNotCountAsCoverage() throws {
    #if canImport(InnoFlowMacros)
      let diagnostics = try phaseDiagnostics(
        cases: "case idle, orphan",
        rules: """
          From(.idle) {}
          #if os(macOS)
            From(.orphan) {}
          #endif
          """,
        targetOS: "Linux"
      )
      #expect(diagnostics.count == 1)
      #expect(diagnostics.first?.message.contains("`Phase.orphan`") == true)
    #endif
  }

  @Test(
    "nested conditional phase coverage succeeds in either active branch",
    arguments: ["Linux", "macOS"])
  func nestedConditionalCoverage(targetOS: String) throws {
    #if canImport(InnoFlowMacros)
      let diagnostics = try phaseDiagnostics(
        cases: """
          case idle
          #if os(macOS)
            #if compiler(>=6.0)
              case desktop
            #endif
          #else
            case portable
          #endif
          """,
        rules: """
          From(.idle) {
            #if os(macOS)
              #if compiler(>=6.0)
                On(.go, to: .desktop)
              #endif
            #else
              On(.go, to: .portable)
            #endif
          }
          """,
        targetOS: targetOS
      )
      #expect(diagnostics.isEmpty)
    #endif
  }

  @Test("unknown build configuration is an explicit strict failure")
  func unknownConfigurationIsNotAPass() throws {
    #if canImport(InnoFlowMacros)
      let diagnostics = try phaseDiagnostics(
        cases: "#if FLAG\ncase hidden\n#endif", rules: "", targetOS: nil)
      #expect(diagnostics.count == 1)
      #expect(diagnostics.first?.diagMessage.severity == .error)
      #expect(
        diagnostics.first?.diagMessage.diagnosticID
          == MessageID(domain: "InnoFlowMacro", id: "PhaseConditionalConfigurationUnavailable"))
    #endif
  }

  #if canImport(InnoFlowMacros)
    private func outputPaths(_ source: String) throws -> (source: String, diagnostics: [Diagnostic])
    {
      let declaration = try #require(
        Parser.parse(source: source).statements.first?.item.as(EnumDeclSyntax.self))
      let context = BasicMacroExpansionContext()
      let attribute = AttributeSyntax(
        attributeName: IdentifierTypeSyntax(name: .identifier("_InnoFlowOutputPaths")))
      let result = try InnoFlowOutputPathsMacro.expansion(
        of: attribute, providingMembersOf: declaration, in: context)
      return (result.map(\.description).joined(separator: "\n"), context.diagnostics)
    }

    private func phaseDiagnostics(cases: String, rules: String, targetOS: String?) throws
      -> [Diagnostic]
    {
      let source = """
        @InnoFlow(phaseManaged: true, strictPhaseTotality: true)
        struct Feature {
          struct State {
            enum Phase {
              \(cases)
            }
          }
          enum Action { case go }
          static var phaseMap: PhaseMap<State, Action, State.Phase> {
            \(rules)
          }
          var body: some Reducer<State, Action, Never> { Reduce { _, _ in .none } }
        }
        """
      let declaration = try #require(
        Parser.parse(source: source).statements.first?.item.as(StructDeclSyntax.self))
      let attribute = try #require(declaration.attributes.first?.as(AttributeSyntax.self))
      let configuration = targetOS.map {
        StaticBuildConfiguration(
          targetOSs: [$0], languageVersion: VersionTuple(6, 3), compilerVersion: VersionTuple(6, 3))
      }
      let context = BasicMacroExpansionContext(buildConfiguration: configuration)
      _ = try InnoFlowMacro.expansion(
        of: attribute,
        attachedTo: declaration,
        providingExtensionsOf: IdentifierTypeSyntax(name: declaration.name),
        conformingTo: [],
        in: context
      )
      return context.diagnostics
    }
  #endif
}
