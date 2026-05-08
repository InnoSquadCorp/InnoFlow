// MARK: - InnoFlowSharedContextDiagnosticsTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing

#if canImport(InnoFlowMacros)
  import InnoFlowMacros
#endif

@Suite("@InnoFlow shared-context typealias diagnostics")
struct InnoFlowSharedContextDiagnosticsTests {

  @Test("Typealiased Action emits a note explaining which diagnostics are skipped")
  func typealiasActionEmitsNote() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct RowFeature {
            struct State: Sendable {}
            typealias Action = ParentFeature.ChildAction

            var body: some Reducer<State, Action> {
                Reduce { state, action in .none }
            }
        }
        """,
        expandedSource: """
          struct RowFeature {
              struct State: Sendable {}
              typealias Action = ParentFeature.ChildAction

              var body: some Reducer<State, Action> {
                  Reduce { state, action in .none }
              }

              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                body.reduce(into: &state, action: action)
              }
          }
          extension RowFeature: Reducer {}
          """,
        diagnostics: [
          DiagnosticSpec(
            message:
              "@InnoFlow skips CasePath synthesis and phase-totality diagnostics for `Action` because it is declared as a `typealias`. Define `Action` as a nested `enum` directly inside this type to enable those diagnostics.",
            line: 4,
            column: 5,
            severity: .note
          )
        ],
        macros: [
          "InnoFlow": InnoFlowMacro.self,
          "_InnoFlowActionPaths": InnoFlowActionPathsMacro.self,
        ]
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("Typealiased State emits a note explaining which diagnostics are skipped")
  func typealiasStateEmitsNote() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct RowFeature {
            typealias State = ParentFeature.ChildState
            enum Action: Sendable {
                case noop
            }

            var body: some Reducer<State, Action> {
                Reduce { state, action in .none }
            }
        }
        """,
        expandedSource: """
          struct RowFeature {
              typealias State = ParentFeature.ChildState
              enum Action: Sendable {
                  case noop
              }

              var body: some Reducer<State, Action> {
                  Reduce { state, action in .none }
              }

              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                body.reduce(into: &state, action: action)
              }
          }
          extension RowFeature: Reducer {}
          """,
        diagnostics: [
          DiagnosticSpec(
            message:
              "@InnoFlow skips `@BindableField` and `BindableProperty` diagnostics for `State` because it is declared as a `typealias`. Define `State` as a nested `struct` directly inside this type to enable those diagnostics.",
            line: 3,
            column: 5,
            severity: .note
          )
        ],
        macros: [
          "InnoFlow": InnoFlowMacro.self,
          "_InnoFlowActionPaths": InnoFlowActionPathsMacro.self,
        ]
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("Both State and Action typealiased emits both notes")
  func bothTypealiasedEmitsBothNotes() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct RowFeature {
            typealias State = ParentFeature.ChildState
            typealias Action = ParentFeature.ChildAction

            var body: some Reducer<State, Action> {
                Reduce { state, action in .none }
            }
        }
        """,
        expandedSource: """
          struct RowFeature {
              typealias State = ParentFeature.ChildState
              typealias Action = ParentFeature.ChildAction

              var body: some Reducer<State, Action> {
                  Reduce { state, action in .none }
              }

              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                body.reduce(into: &state, action: action)
              }
          }
          extension RowFeature: Reducer {}
          """,
        diagnostics: [
          DiagnosticSpec(
            message:
              "@InnoFlow skips CasePath synthesis and phase-totality diagnostics for `Action` because it is declared as a `typealias`. Define `Action` as a nested `enum` directly inside this type to enable those diagnostics.",
            line: 4,
            column: 5,
            severity: .note
          ),
          DiagnosticSpec(
            message:
              "@InnoFlow skips `@BindableField` and `BindableProperty` diagnostics for `State` because it is declared as a `typealias`. Define `State` as a nested `struct` directly inside this type to enable those diagnostics.",
            line: 3,
            column: 5,
            severity: .note
          ),
        ],
        macros: [
          "InnoFlow": InnoFlowMacro.self,
          "_InnoFlowActionPaths": InnoFlowActionPathsMacro.self,
        ]
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("Direct enum / struct State and Action emit no shared-context note")
  func directDeclarationsDoNotEmitNote() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct DirectFeature {
            struct State: Sendable {}
            enum Action: Sendable {
                case noop
            }

            var body: some Reducer<State, Action> {
                Reduce { state, action in .none }
            }
        }
        """,
        expandedSource: """
          struct DirectFeature {
              struct State: Sendable {}
              enum Action: Sendable {
                  case noop
              }

              var body: some Reducer<State, Action> {
                  Reduce { state, action in .none }
              }

              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                body.reduce(into: &state, action: action)
              }
          }
          extension DirectFeature: Reducer {}
          """,
        diagnostics: [],
        macros: [
          "InnoFlow": InnoFlowMacro.self,
          "_InnoFlowActionPaths": InnoFlowActionPathsMacro.self,
        ]
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }
}
