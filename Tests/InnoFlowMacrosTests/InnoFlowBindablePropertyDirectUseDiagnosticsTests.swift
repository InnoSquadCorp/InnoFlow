// MARK: - InnoFlowBindablePropertyDirectUseDiagnosticsTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing

@Suite("Macro Tests")
struct InnoFlowBindablePropertyDirectUseDiagnosticsTests {

  @Test("@InnoFlow warns when State declares BindableProperty<T> directly")
  func directBindablePropertyDeclarationWarns() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct CounterFeature {
            struct State: Sendable {
                var step: BindableProperty<Int> = BindableProperty(1)
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
                  var step: BindableProperty<Int> = BindableProperty(1)
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
        diagnostics: [
          DiagnosticSpec(
            message:
              "state field `step` declares `BindableProperty<Int>` directly; use `@BindableField var step: Int` instead — `BindableProperty` is a low-level storage type that must not be authored directly in feature State",
            line: 4,
            column: 18,
            severity: .warning,
            fixIts: [
              FixItSpec(message: "Replace with `@BindableField var step: Int`")
            ]
          )
        ],
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("@InnoFlow accepts @BindableField wrapped declarations without warning")
  func bindableFieldWrappedDeclarationPassesCleanly() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct CounterFeature {
            struct State: Sendable {
                @BindableField var step: Int = 1
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
                  @BindableField var step: Int = 1
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

  @Test("@InnoFlow recognizes the qualified InnoFlow.BindableProperty spelling")
  func qualifiedBindablePropertySpellingWarns() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct CounterFeature {
            struct State: Sendable {
                var step: InnoFlow.BindableProperty<Int> = InnoFlow.BindableProperty(0)
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
                  var step: InnoFlow.BindableProperty<Int> = InnoFlow.BindableProperty(0)
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
        diagnostics: [
          DiagnosticSpec(
            message:
              "state field `step` declares `BindableProperty<Int>` directly; use `@BindableField var step: Int` instead — `BindableProperty` is a low-level storage type that must not be authored directly in feature State",
            line: 4,
            column: 18,
            severity: .warning,
            fixIts: [
              FixItSpec(message: "Replace with `@BindableField var step: Int`")
            ]
          )
        ],
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("@InnoFlow ignores unrelated qualified BindableProperty spellings")
  func unrelatedQualifiedBindablePropertySpellingDoesNotWarn() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct CounterFeature {
            struct State: Sendable {
                var step: OtherModule.BindableProperty<Int> = OtherModule.BindableProperty(0)
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
                  var step: OtherModule.BindableProperty<Int> = OtherModule.BindableProperty(0)
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

  @Test("@InnoFlow omits unsafe BindableProperty Fix-Its")
  func unsafeBindablePropertyFixItsAreOmitted() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct CounterFeature {
            struct State: Sendable {
                @available(*, deprecated)
                private var step: BindableProperty<Int> = BindableProperty<Int>(1)
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
                  @available(*, deprecated)
                  private var step: BindableProperty<Int> = BindableProperty<Int>(1)
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
        diagnostics: [
          DiagnosticSpec(
            message:
              "state field `step` declares `BindableProperty<Int>` directly; use `@BindableField var step: Int` instead — `BindableProperty` is a low-level storage type that must not be authored directly in feature State",
            line: 5,
            column: 23,
            severity: .warning
          )
        ],
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("@InnoFlow skips BindableProperty diagnostics when State is a typealias")
  func typealiasedStateSkipsBindablePropertyDiagnostic() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct ChildFeature {
            typealias State = Parent.ChildState
            enum Action: Sendable {
                case noop
            }

            var body: some Reducer<State, Action> {
                Reduce { state, action in
                    .none
                }
            }
        }
        """,
        expandedSource: """
          struct ChildFeature {
              typealias State = Parent.ChildState
              enum Action: Sendable {
                  case noop
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

          extension ChildFeature: Reducer {
          }
          """,
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("@InnoFlow warns once per BindableProperty field even with multiple offenders")
  func multipleDirectBindablePropertyFieldsAllWarn() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct FormFeature {
            struct State: Sendable {
                var name: BindableProperty<String> = BindableProperty("")
                var age: BindableProperty<Int> = BindableProperty(0)
            }
            enum Action: Sendable {
                case setName(String)
                case setAge(Int)
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
                  var name: BindableProperty<String> = BindableProperty("")
                  var age: BindableProperty<Int> = BindableProperty(0)
              }
              enum Action: Sendable {
                  case setName(String)
                  case setAge(Int)
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
              "state field `name` declares `BindableProperty<String>` directly; use `@BindableField var name: String` instead — `BindableProperty` is a low-level storage type that must not be authored directly in feature State",
            line: 4,
            column: 18,
            severity: .warning,
            fixIts: [
              FixItSpec(message: "Replace with `@BindableField var name: String`")
            ]
          ),
          DiagnosticSpec(
            message:
              "state field `age` declares `BindableProperty<Int>` directly; use `@BindableField var age: Int` instead — `BindableProperty` is a low-level storage type that must not be authored directly in feature State",
            line: 5,
            column: 17,
            severity: .warning,
            fixIts: [
              FixItSpec(message: "Replace with `@BindableField var age: Int`")
            ]
          ),
        ],
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }
}
