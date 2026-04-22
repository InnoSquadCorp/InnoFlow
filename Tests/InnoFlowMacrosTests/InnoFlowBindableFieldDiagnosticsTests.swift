// MARK: - InnoFlowBindableFieldDiagnosticsTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing

@Suite("Macro Tests")
struct InnoFlowBindableFieldDiagnosticsTests {

  @Test("@InnoFlow: @BindableField matched by Action.setX emits no diagnostics")
  func bindableFieldMatchedBySetterPassesCleanly() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct CounterFeature {
            struct State: Sendable {
                @BindableField var step = 1
            }
            enum Action: Sendable {
                case setStep(Int)
            }

            var body: some Reducer<State, Action> {
                Reduce { state, action in
                    .none
                }
            }
        }
        """,
        expandedSource: """
          struct CounterFeature {
              struct State: Sendable {
                  @BindableField var step = 1
              }
              enum Action: Sendable {
                  case setStep(Int)
              }

              var body: some Reducer<State, Action> {
                  Reduce { state, action in
                      .none
                  }
              }

              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                body.reduce(into: &state, action: action)
              }
          }

          extension CounterFeature: Reducer {
          }
          """,
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("@InnoFlow warns when @BindableField has no matching Action.setX case")
  func bindableFieldWithoutSetterWarns() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct CounterFeature {
            struct State: Sendable {
                @BindableField var step = 1
            }
            enum Action: Sendable {
                case increment
            }

            var body: some Reducer<State, Action> {
                Reduce { state, action in
                    .none
                }
            }
        }
        """,
        expandedSource: """
          struct CounterFeature {
              struct State: Sendable {
                  @BindableField var step = 1
              }
              enum Action: Sendable {
                  case increment
              }

              var body: some Reducer<State, Action> {
                  Reduce { state, action in
                      .none
                  }
              }

              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                body.reduce(into: &state, action: action)
              }
          }

          extension CounterFeature: Reducer {
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message:
              "`@BindableField var step` has no matching `case setStep(Int)` in `Action` — `store.binding(\\.$step, to:)` requires a single `Int` payload setter",
            line: 4,
            column: 9,
            severity: .warning,
            fixIts: [
              FixItSpec(message: "Add `case setStep(Int)` to `Action`")
            ]
          )
        ],
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("@InnoFlow skips @BindableField diagnostics when Action is a typealias")
  func typealiasedActionSkipsBindableFieldDiagnostic() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct ChildFeature {
            struct State: Sendable {
                @BindableField var step = 1
            }
            typealias Action = ParentFeature.ChildAction

            var body: some Reducer<State, Action> {
                Reduce { state, action in
                    .none
                }
            }
        }
        """,
        expandedSource: """
          struct ChildFeature {
              struct State: Sendable {
                  @BindableField var step = 1
              }
              typealias Action = ParentFeature.ChildAction

              var body: some Reducer<State, Action> {
                  Reduce { state, action in
                      .none
                  }
              }

              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                body.reduce(into: &state, action: action)
              }
          }

          extension ChildFeature: Reducer {
          }
          """,
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("@InnoFlow tolerates acronym casings like mfaCode ↔ setMFACode")
  func bindableFieldAcronymCasingIsAccepted() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct AuthFeature {
            struct State: Sendable {
                @BindableField var mfaCode = ""
            }
            enum Action: Sendable {
                case setMFACode(String)
            }

            var body: some Reducer<State, Action> {
                Reduce { state, action in
                    .none
                }
            }
        }
        """,
        expandedSource: """
          struct AuthFeature {
              struct State: Sendable {
                  @BindableField var mfaCode = ""
              }
              enum Action: Sendable {
                  case setMFACode(String)
              }

              var body: some Reducer<State, Action> {
                  Reduce { state, action in
                      .none
                  }
              }

              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                body.reduce(into: &state, action: action)
              }
          }

          extension AuthFeature: Reducer {
          }
          """,
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("@InnoFlow warns when Action.setX exists but takes the wrong payload type")
  func bindableFieldSetterPayloadTypeMismatchWarnsWithoutFixIt() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct CounterFeature {
            struct State: Sendable {
                @BindableField var step = 1
            }
            enum Action: Sendable {
                case setStep(String)
            }

            var body: some Reducer<State, Action> {
                Reduce { state, action in
                    .none
                }
            }
        }
        """,
        expandedSource: """
          struct CounterFeature {
              struct State: Sendable {
                  @BindableField var step = 1
              }
              enum Action: Sendable {
                  case setStep(String)
              }

              var body: some Reducer<State, Action> {
                  Reduce { state, action in
                      .none
                  }
              }

              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                body.reduce(into: &state, action: action)
              }
          }

          extension CounterFeature: Reducer {
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message:
              "`@BindableField var step` has no matching `case setStep(Int)` in `Action` — `store.binding(\\.$step, to:)` requires a single `Int` payload setter",
            line: 4,
            column: 9,
            severity: .warning
          )
        ],
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("@InnoFlow warns only for @BindableField fields missing their Action.setX")
  func bindableFieldDiagnosticIsFieldLocal() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct FormFeature {
            struct State: Sendable {
                @BindableField var step = 1
                @BindableField var name = ""
            }
            enum Action: Sendable {
                case setName(String)
            }

            var body: some Reducer<State, Action> {
                Reduce { state, action in
                    .none
                }
            }
        }
        """,
        expandedSource: """
          struct FormFeature {
              struct State: Sendable {
                  @BindableField var step = 1
                  @BindableField var name = ""
              }
              enum Action: Sendable {
                  case setName(String)
              }

              var body: some Reducer<State, Action> {
                  Reduce { state, action in
                      .none
                  }
              }

              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                body.reduce(into: &state, action: action)
              }
          }

          extension FormFeature: Reducer {
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message:
              "`@BindableField var step` has no matching `case setStep(Int)` in `Action` — `store.binding(\\.$step, to:)` requires a single `Int` payload setter",
            line: 4,
            column: 9,
            severity: .warning,
            fixIts: [
              FixItSpec(message: "Add `case setStep(Int)` to `Action`")
            ]
          )
        ],
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }
}
