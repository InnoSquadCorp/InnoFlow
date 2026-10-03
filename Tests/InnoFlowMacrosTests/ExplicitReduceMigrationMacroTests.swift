// MARK: - ExplicitReduceMigrationMacroTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import SwiftSyntaxMacrosTestSupport
import Testing

@Suite("Typed explicit reduce migration")
struct ExplicitReduceMigrationMacroTests {
  @Test("legacy EffectTask repair retains its effect type and promotes Output")
  func legacyEffectTaskRepair() {
    #if canImport(InnoFlowMacros)
      assertSwiftTestingMacroExpansion(
        """
        @InnoFlow
        struct Legacy {
            struct State: Sendable {
                var count = 0
            }
            enum Action: Sendable {
                case go
            }
            enum Output: Sendable {}
            func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                state.count += 1
                return EffectTask<Action>.none
            }
        }
        """,
        expandedSource: """
          struct Legacy {
              struct State: Sendable {
                  var count = 0
              }
              enum Action: Sendable {
                  case go
              }
              enum Output: Sendable {}
              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                  state.count += 1
                  return EffectTask<Action>.none
              }
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message:
              "@InnoFlow no longer supports explicit `reduce(into:action:)` authoring; declare `var body: some Reducer<State, Action, Output>` instead",
            line: 1,
            column: 1,
            fixIts: [
              FixItSpec(message: "replace explicit reduce with body-based reducer composition")
            ]
          )
        ],
        macros: testMacros,
        applyFixIts: ["replace explicit reduce with body-based reducer composition"],
        fixedSource: """
          @InnoFlow
          struct Legacy {
              struct State: Sendable {
                  var count = 0
              }
              enum Action: Sendable {
                  case go
              }
              enum Output: Sendable {}
              var body: some Reducer<State, Action, Output> {
                  Reduce<State, Action, Never> { state, action in
                      state.count += 1
                      return EffectTask<Action>.none
                  }
                  .promoteOutput(to: Output.self)
              }
          }
          """
      )
    #endif
  }

  @Test("typed ReducerEffect repair keeps the declared Output")
  func typedReducerEffectRepair() {
    #if canImport(InnoFlowMacros)
      assertSwiftTestingMacroExpansion(
        """
        @InnoFlow
        struct Legacy {
            struct State: Sendable {}
            enum Action: Sendable {}
            enum Output: Sendable {}
            func reduce(into state: inout State, action: Action) -> ReducerEffect<Action, Output> {
                return .none
            }
        }
        """,
        expandedSource: """
          struct Legacy {
              struct State: Sendable {}
              enum Action: Sendable {}
              enum Output: Sendable {}
              func reduce(into state: inout State, action: Action) -> ReducerEffect<Action, Output> {
                  return .none
              }
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message:
              "@InnoFlow no longer supports explicit `reduce(into:action:)` authoring; declare `var body: some Reducer<State, Action, Output>` instead",
            line: 1,
            column: 1,
            fixIts: [
              FixItSpec(message: "replace explicit reduce with body-based reducer composition")
            ]
          )
        ],
        macros: testMacros,
        applyFixIts: ["replace explicit reduce with body-based reducer composition"],
        fixedSource: """
          @InnoFlow
          struct Legacy {
              struct State: Sendable {}
              enum Action: Sendable {}
              enum Output: Sendable {}
              var body: some Reducer<State, Action, Output> {
                  Reduce { state, action in
                      return .none
                  }
              }
          }
          """
      )
    #endif
  }
}
