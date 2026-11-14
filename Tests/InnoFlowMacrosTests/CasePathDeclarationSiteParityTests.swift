// MARK: - CasePathDeclarationSiteParityTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing

#if canImport(InnoFlowMacros)
  import InnoFlowMacros
#endif

// `Action` and `Output` path synthesis walk their cases through one
// traversal. Every rule below is asserted for both enums, so a change that
// makes them disagree fails here.
@Suite("Action and Output paths share declaration-site rules", .timeLimit(.minutes(5)))
struct CasePathDeclarationSiteParityTests {
  @Test("a manual path in the enum body replaces the synthesized one", arguments: [false, true])
  func manualPathTakesPrecedence(output: Bool) throws {
    #if canImport(InnoFlowMacros)
      let result = try paths(
        """
        enum Paths {
          case plain(Int)
          case named(_ value: Int)
          #if DEBUG
            case debug(Int)
            static let debugCasePath = makePath()
          #endif
          static let plainCasePath = makePath(), namedCasePath = makePath()
        }
        """,
        output: output
      )
      #expect(result.diagnostics.isEmpty)
      #expect(result.source.isEmpty)
    #endif
  }

  @Test(
    "a manual path in a narrower condition leaves the complement synthesized",
    arguments: [false, true])
  func manualPathInNarrowerConditionSynthesizesTheComplement(output: Bool) throws {
    #if canImport(InnoFlowMacros)
      let result = try paths(
        """
        enum Paths {
          case child(Int)
          #if LEGACY_PATHS
            static let childCasePath = makePath()
          #endif
        }
        """,
        output: output
      )
      #expect(result.diagnostics.isEmpty)
      #expect(result.parses)
      #expect(result.source.hasPrefix("#if !((LEGACY_PATHS))\n"))
      #expect(result.source.hasSuffix("\n#endif"))
      #expect(result.source.components(separatedBy: "static let childCasePath").count == 2)
    #endif
  }

  @Test("a manual path does not hide a collision outside its condition", arguments: [false, true])
  func manualPathDoesNotHideACollisionOutsideItsCondition(output: Bool) throws {
    #if canImport(InnoFlowMacros)
      let result = try paths(
        """
        enum Paths {
          case child(Int)
          case _child(Int)
          #if LEGACY_PATHS
            static let childCasePath = makePath()
          #endif
        }
        """,
        output: output
      )
      #expect(result.diagnostics.count == 1)
      #expect(result.diagnostics.first?.diagMessage.severity == .error)
      #expect(result.diagnostics.first?.message.contains("`childCasePath` collides") == true)
      #expect(result.source.components(separatedBy: "static let childCasePath").count == 2)
    #endif
  }

  @Test("the same case name in separate conditions gets a path in each", arguments: [false, true])
  func sameCaseNameInSeparateConditionsIsNotACollision(output: Bool) throws {
    #if canImport(InnoFlowMacros)
      let result = try paths(
        """
        enum Paths {
          case plain
          #if FLAG_A
            case child(Int)
          #endif
          #if FLAG_B
            case child(String)
          #endif
        }
        """,
        output: output
      )
      #expect(result.diagnostics.isEmpty)
      #expect(result.parses)
      let pathForFlagA = try #require(
        result.source.range(of: "#if FLAG_A\nstatic let childCasePath"))
      let pathForFlagB = try #require(
        result.source.range(of: "#if FLAG_B\nstatic let childCasePath"))
      #expect(pathForFlagA.upperBound < pathForFlagB.lowerBound)
      #expect(result.source.contains("CasePath<Self, Int>"))
      #expect(result.source.contains("CasePath<Self, String>"))
    #endif
  }

  @Test("differently named cases that can be active together collide", arguments: [false, true])
  func differentlyNamedCasesInOverlappingConditionsCollide(output: Bool) throws {
    #if canImport(InnoFlowMacros)
      let result = try paths(
        """
        enum Paths {
          #if FLAG_A
            case child(Int)
          #endif
          #if FLAG_B
            case _child(String)
          #endif
        }
        """,
        output: output
      )
      #expect(result.diagnostics.count == 1)
      #expect(result.diagnostics.first?.diagMessage.severity == .error)
      #expect(result.diagnostics.first?.message.contains("`childCasePath` collides") == true)
    #endif
  }

  // Swift accepts same-named cases whose argument labels differ, so both can
  // be active in one configuration and their helpers would be declared twice.
  @Test("same-named Output cases that Swift lets coexist still collide")
  func overloadedOutputCasesInOverlappingConditionsCollide() throws {
    #if canImport(InnoFlowMacros)
      let result = try paths(
        """
        enum Output {
          #if FLAG_A
            case value(first: Int)
          #endif
          #if FLAG_B
            case value(second: Int)
          #endif
        }
        """,
        output: true
      )
      #expect(result.diagnostics.count == 1)
      #expect(result.diagnostics.first?.message.contains("`valueCasePath` collides") == true)
      #expect(result.source.components(separatedBy: "static let valueCasePath").count == 2)
    #endif
  }

  @Test("a payload-free Output case excludes every same-named case")
  func payloadFreeOutputCaseExcludesSameNamedCases() throws {
    #if canImport(InnoFlowMacros)
      let result = try paths(
        """
        enum Output {
          #if FLAG_A
            case done
          #endif
          #if FLAG_B
            case done(code: Int)
          #endif
        }
        """,
        output: true
      )
      #expect(result.diagnostics.isEmpty)
      #expect(result.parses)
      #expect(result.source.components(separatedBy: "static let doneCasePath").count == 3)
    #endif
  }

  @Test("a copied availability attribute carries no comment", arguments: [false, true])
  func copiedAvailabilityCarriesNoComment(output: Bool) throws {
    #if canImport(InnoFlowMacros)
      let result = try paths(
        """
        enum Paths {
          case current(Int)
          @available(*, deprecated // legacy
                     , renamed: "current")
          case previous(Int)
          @available(
            macOS,  // desktop only
            introduced: 26.0,  /* staged */ message: "Requires the new runtime"
          )
          case modern(Int)
        }
        """,
        output: output
      )
      #expect(result.diagnostics.isEmpty)
      #expect(result.parses)
      #expect(result.source.contains("@available(*, deprecated)\nstatic let previousCasePath"))
      #expect(
        result.source.contains(
          """
          @available(macOS, introduced: 26.0, message: "Requires the new runtime")
          static let modernCasePath
          """))
      #expect(!result.source.contains("legacy"))
      #expect(!result.source.contains("desktop only"))
      #expect(!result.source.contains("staged"))
      #expect(!result.source.contains("renamed:"))
    #endif
  }

  @Test("an availability attribute that only renames is not copied", arguments: [false, true])
  func renameOnlyAvailabilityIsNotCopied(output: Bool) throws {
    #if canImport(InnoFlowMacros)
      let result = try paths(
        """
        enum Paths {
          case current(Int)
          @available(*, renamed: "current")
          case previous(Int)
        }
        """,
        output: output
      )
      #expect(result.diagnostics.isEmpty)
      #expect(result.parses)
      #expect(result.source.contains("static let previousCasePath"))
      #expect(!result.source.contains("@available"))
    #endif
  }

  @Test("An Output payload with a local name and no label synthesizes like an unlabeled one")
  func outputLocalPayloadNamesSynthesizeLikeUnlabeledPayloads() throws {
    #if canImport(InnoFlowMacros)
      assertSwiftTestingMacroExpansion(
        """
        @_InnoFlowOutputPaths
        enum Output {
            case finished(_ result: Int)
            case paired(_ id: Int, _ name: String)
            case mixed(code: Int, _ detail: String)
            case manual(_ value: Int)
            @InnoFlowCasePathIgnored
            case ignored(_ value: Int)

            static let manualCasePath = makePath()
        }
        """,
        expandedSource: """
          enum Output {
              case finished(_ result: Int)
              case paired(_ id: Int, _ name: String)
              case mixed(code: Int, _ detail: String)
              case manual(_ value: Int)
              case ignored(_ value: Int)

              static let manualCasePath = makePath()

              static let finishedCasePath = CasePath<Self, Int>(
                embed: { value in
                  .finished(value)
                },
                extract: { output in
                  guard case .finished(let value) = output else {
                      return nil
                  }
                  return .some(value)
                }
              )

              static let pairedCasePath = CasePath<Self, (Int, String)>(
                embed: { value in
                  .paired(value.0, value.1)
                },
                extract: { output in
                  guard case let .paired(value0, value1) = output else {
                      return nil
                  }
                  return .some((value0, value1))
                }
              )

              static let mixedCasePath = CasePath<Self, (code: Int, String)>(
                embed: { value in
                  .mixed(code: value.code, value.1)
                },
                extract: { output in
                  guard case let .mixed(value0, value1) = output else {
                      return nil
                  }
                  return .some((code: value0, value1))
                }
              )
          }
          """,
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  #if canImport(InnoFlowMacros)
    private struct PathExpansion {
      let source: String
      let diagnostics: [Diagnostic]
      /// Whether every generated member is syntactically valid on its own.
      let parses: Bool
    }

    private func paths(_ source: String, output: Bool) throws -> PathExpansion {
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
      let generated = members.map(\.description).joined(separator: "\n")
      return PathExpansion(
        source: generated,
        diagnostics: context.diagnostics,
        parses: !Parser.parse(source: "enum Paths {\n\(generated)\n}").hasError
      )
    }
  #endif
}
