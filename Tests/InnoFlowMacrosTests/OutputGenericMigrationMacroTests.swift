// MARK: - OutputGenericMigrationMacroTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import SwiftSyntaxMacrosTestSupport
import Testing

@Suite("Explicit reducer output migration")
struct OutputGenericMigrationMacroTests {
  @Test("a missing third generic gets the actual output type", arguments: [false, true])
  func missingOutputFixIt(hasOutput: Bool) {
    assertOutputRepair(
      hasOutput: hasOutput,
      arguments: "State, Action",
      detail: "`body` must have exactly 3 generic parameters (State, Action, Output), found 2"
    )
  }

  @Test("a mismatched third generic gets a targeted fix", arguments: [false, true])
  func mismatchedOutputFixIt(hasOutput: Bool) {
    assertOutputRepair(
      hasOutput: hasOutput,
      arguments: "State, Action, \(hasOutput ? "Never" : "String")",
      detail: hasOutput
        ? "third generic parameter must be `Output` (or `Self.Output`) because the nested `Output` declares this feature’s output type, found `Never`"
        : "third generic parameter must be `Never` when the feature declares no nested `Output`, found `String`"
    )
  }

  @Test("a foreign state parameter is not silently rewritten")
  func foreignStateHasNoOutputFixIt() {
    #if canImport(InnoFlowMacros)
      assertSwiftTestingMacroExpansion(
        """
        @InnoFlow
        struct Feature {
            struct State: Sendable {}
            enum Action: Sendable {}
            var body: some Reducer<OtherState, Action> { Reduce { _, _ in .none } }
        }
        """,
        expandedSource: """
          struct Feature {
              struct State: Sendable {}
              enum Action: Sendable {}
              var body: some Reducer<OtherState, Action> { Reduce { _, _ in .none } }
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message: """
              Invalid body signature for @InnoFlow.
              Expected:
              var body: some Reducer<State, Action, Never>
              Detected issues: `body` must have exactly 3 generic parameters (State, Action, Output), found 2.
              """,
            line: 1,
            column: 1
          )
        ],
        macros: testMacros
      )
    #endif
  }

  private func assertOutputRepair(hasOutput: Bool, arguments: String, detail: String) {
    #if canImport(InnoFlowMacros)
      let outputType = hasOutput ? "Output" : "Never"
      let outputDeclaration = hasOutput ? "    enum Output: Sendable {}\n" : ""
      let fix = "use explicit `\(outputType)` as the third reducer generic parameter"
      let original = """
        @InnoFlow
        struct Feature {
            struct State: Sendable {}
            enum Action: Sendable {}
        \(outputDeclaration)    var body: some Reducer<\(arguments)> { Reduce { _, _ in .none } }
        }
        """
      assertSwiftTestingMacroExpansion(
        original,
        expandedSource: String(original.dropFirst("@InnoFlow\n".count)),
        diagnostics: [
          DiagnosticSpec(
            message: """
              Invalid body signature for @InnoFlow.
              Expected:
              var body: some Reducer<State, Action, \(outputType)>
              Detected issues: \(detail).
              """,
            line: 1,
            column: 1,
            fixIts: [FixItSpec(message: fix)]
          )
        ],
        macros: testMacros,
        applyFixIts: [fix],
        fixedSource: original.replacingOccurrences(
          of: "Reducer<\(arguments)>",
          with: "Reducer<State, Action, \(outputType)>"
        )
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }
}
