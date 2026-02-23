// MARK: - InnoFlowMacrosTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing

#if canImport(InnoFlowMacros)
import InnoFlowMacros

let testMacros: [String: Macro.Type] = [
    "InnoFlow": InnoFlowMacro.self,
]
#endif

@Suite("Macro Tests")
struct InnoFlowMacrosTests {

    @Test("@InnoFlow adds Reducer conformance for valid v2 reducer")
    func reducerMacroAddsConformance() throws {
        #if canImport(InnoFlowMacros)
        assertMacroExpansion(
            """
            @InnoFlow
            struct CounterFeature {
                struct State: Sendable { var count = 0 }
                enum Action: Sendable { case increment }

                func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                    state.count += 1
                    return .none
                }
            }
            """,
            expandedSource: """
            struct CounterFeature {
                struct State: Sendable { var count = 0 }
                enum Action: Sendable { case increment }

                func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                    state.count += 1
                    return .none
                }
            }
            extension CounterFeature: Reducer {}
            """,
            macros: testMacros
        )
        #else
        throw Issue("Macros are only supported when running tests for the host platform")
        #endif
    }

    @Test("@InnoFlow accepts v2 reducer with EffectTask typealias return")
    func reducerMacroAcceptsTypeAliasReturn() throws {
        #if canImport(InnoFlowMacros)
        assertMacroExpansion(
            """
            @InnoFlow
            struct AliasFeature {
                struct State: Sendable { var count = 0 }
                enum Action: Sendable { case increment }
                typealias FeatureEffect = EffectTask<Action>

                func reduce(into state: inout State, action: Action) -> FeatureEffect {
                    state.count += 1
                    return .none
                }
            }
            """,
            expandedSource: """
            struct AliasFeature {
                struct State: Sendable { var count = 0 }
                enum Action: Sendable { case increment }
                typealias FeatureEffect = EffectTask<Action>

                func reduce(into state: inout State, action: Action) -> FeatureEffect {
                    state.count += 1
                    return .none
                }
            }
            extension AliasFeature: Reducer {}
            """,
            macros: testMacros
        )
        #else
        throw Issue("Macros are only supported when running tests for the host platform")
        #endif
    }

    @Test("@InnoFlow rejects legacy v1 reduce signature")
    func reducerMacroRejectsLegacySignature() throws {
        #if canImport(InnoFlowMacros)
        assertMacroExpansion(
            """
            @InnoFlow
            struct LegacyFeature {
                struct State: Sendable { var count = 0 }
                enum Action: Sendable { case increment }

                func reduce(state: State, action: Action) -> EffectTask<Action> {
                    .none
                }
            }
            """,
            expandedSource: """
            struct LegacyFeature {
                struct State: Sendable { var count = 0 }
                enum Action: Sendable { case increment }

                func reduce(state: State, action: Action) -> EffectTask<Action> {
                    .none
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: """
Invalid reducer signature for @InnoFlow.
Expected:
func reduce(into state: inout State, action: Action) -> EffectTask<Action>
Detected issues: first parameter label is `state`, expected `into`; `into` parameter must be declared as `inout`.
Remediation: use exactly two parameters labeled `into` and `action`, and mark the first parameter `inout`.
""",
                    line: 1,
                    column: 1
                )
            ],
            macros: testMacros
        )
        #else
        throw Issue("Macros are only supported when running tests for the host platform")
        #endif
    }

    @Test("@InnoFlow rejects wrong labels with actionable details")
    func reducerMacroRejectsWrongLabels() throws {
        #if canImport(InnoFlowMacros)
        assertMacroExpansion(
            """
            @InnoFlow
            struct WrongLabelFeature {
                struct State: Sendable { var count = 0 }
                enum Action: Sendable { case increment }

                func reduce(state: inout State, event: Action) -> EffectTask<Action> {
                    .none
                }
            }
            """,
            expandedSource: """
            struct WrongLabelFeature {
                struct State: Sendable { var count = 0 }
                enum Action: Sendable { case increment }

                func reduce(state: inout State, event: Action) -> EffectTask<Action> {
                    .none
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: """
Invalid reducer signature for @InnoFlow.
Expected:
func reduce(into state: inout State, action: Action) -> EffectTask<Action>
Detected issues: first parameter label is `state`, expected `into`; second parameter label is `event`, expected `action`.
Remediation: use exactly two parameters labeled `into` and `action`, and mark the first parameter `inout`.
""",
                    line: 1,
                    column: 1
                )
            ],
            macros: testMacros
        )
        #else
        throw Issue("Macros are only supported when running tests for the host platform")
        #endif
    }

    @Test("@InnoFlow rejects missing inout with explicit remediation")
    func reducerMacroRejectsMissingInout() throws {
        #if canImport(InnoFlowMacros)
        assertMacroExpansion(
            """
            @InnoFlow
            struct MissingInoutFeature {
                struct State: Sendable { var count = 0 }
                enum Action: Sendable { case increment }

                func reduce(into state: State, action: Action) -> EffectTask<Action> {
                    .none
                }
            }
            """,
            expandedSource: """
            struct MissingInoutFeature {
                struct State: Sendable { var count = 0 }
                enum Action: Sendable { case increment }

                func reduce(into state: State, action: Action) -> EffectTask<Action> {
                    .none
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: """
Invalid reducer signature for @InnoFlow.
Expected:
func reduce(into state: inout State, action: Action) -> EffectTask<Action>
Detected issues: `into` parameter must be declared as `inout`.
Remediation: use exactly two parameters labeled `into` and `action`, and mark the first parameter `inout`.
""",
                    line: 1,
                    column: 1
                )
            ],
            macros: testMacros
        )
        #else
        throw Issue("Macros are only supported when running tests for the host platform")
        #endif
    }

    @Test("@InnoFlow rejects wrong parameter arity with explicit details")
    func reducerMacroRejectsWrongArity() throws {
        #if canImport(InnoFlowMacros)
        assertMacroExpansion(
            """
            @InnoFlow
            struct WrongArityFeature {
                struct State: Sendable { var count = 0 }
                enum Action: Sendable { case increment }

                func reduce(into state: inout State) -> EffectTask<Action> {
                    .none
                }
            }
            """,
            expandedSource: """
            struct WrongArityFeature {
                struct State: Sendable { var count = 0 }
                enum Action: Sendable { case increment }

                func reduce(into state: inout State) -> EffectTask<Action> {
                    .none
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: """
Invalid reducer signature for @InnoFlow.
Expected:
func reduce(into state: inout State, action: Action) -> EffectTask<Action>
Detected issues: parameter count is 1, expected 2 parameters (`into`, `action`); missing second parameter `action: Action`.
Remediation: use exactly two parameters labeled `into` and `action`, and mark the first parameter `inout`.
""",
                    line: 1,
                    column: 1
                )
            ],
            macros: testMacros
        )
        #else
        throw Issue("Macros are only supported when running tests for the host platform")
        #endif
    }
}
