// MARK: - StrictPhaseTotalityMacroTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import SwiftSyntaxMacrosTestSupport
import Testing

@Suite("Strict PhaseMap totality macro")
struct StrictPhaseTotalityMacroTests {
  @Test("strict phase totality promotes an unreferenced phase to an error")
  func strictTotalityRejectsUnreferencedPhase() {
    #if canImport(InnoFlowMacros)
      assertSwiftTestingMacroExpansion(
        """
        @InnoFlow(phaseManaged: true, strictPhaseTotality: true)
        struct StrictPhaseFeature {
            struct State: Sendable {
                enum Phase: Hashable, Sendable {
                    case idle
                    case loading
                    case orphan
                }
                var phase: Phase = .idle
            }
            enum Action: Sendable, Equatable {
                case load
            }
            static var phaseMap: PhaseMap<State, Action, State.Phase> {
                PhaseMap(\\State.phase) {
                    From(.idle) {
                        On(.load, to: .loading)
                    }
                }
            }
            var body: some Reducer<State, Action, Never> {
                Reduce { _, _ in .none }
            }
        }
        """,
        expandedSource: """
          struct StrictPhaseFeature {
              struct State: Sendable {
                  enum Phase: Hashable, Sendable {
                      case idle
                      case loading
                      case orphan
                  }
                  var phase: Phase = .idle
              }
              enum Action: Sendable, Equatable {
                  case load
              }
              static var phaseMap: PhaseMap<State, Action, State.Phase> {
                  PhaseMap(\\State.phase) {
                      From(.idle) {
                          On(.load, to: .loading)
                      }
                  }
              }
              var body: some Reducer<State, Action, Never> {
                  Reduce { _, _ in .none }
              }

              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                body.phaseMap(Self.phaseMap).reduce(into: &state, action: action)
              }
          }

          extension StrictPhaseFeature: Reducer {
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message:
              "`Phase.orphan` is declared but never referenced from the static `phaseMap` — add a `From(.orphan) { ... }` rule, an `On(..., to: .orphan)` target, or remove the case if it is unused",
            line: 7,
            column: 18,
            severity: .error
          )
        ],
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("strict phase totality accepts direct source and target coverage")
  func strictTotalityAcceptsCompleteDeclaration() {
    #if canImport(InnoFlowMacros)
      assertSwiftTestingMacroExpansion(
        """
        @InnoFlow(phaseManaged: true, strictPhaseTotality: true)
        struct CompletePhaseFeature {
            struct State: Sendable {
                enum Phase: Hashable, Sendable {
                    case idle
                    case loaded
                }
                var phase: Phase = .idle
            }
            enum Action: Sendable, Equatable {
                case load
            }
            static var phaseMap: PhaseMap<State, Action, State.Phase> {
                PhaseMap(\\State.phase) {
                    From(.idle) {
                        On(.load, to: .loaded)
                    }
                }
            }
            var body: some Reducer<State, Action, Never> {
                Reduce { _, _ in .none }
            }
        }
        """,
        expandedSource: """
          struct CompletePhaseFeature {
              struct State: Sendable {
                  enum Phase: Hashable, Sendable {
                      case idle
                      case loaded
                  }
                  var phase: Phase = .idle
              }
              enum Action: Sendable, Equatable {
                  case load
              }
              static var phaseMap: PhaseMap<State, Action, State.Phase> {
                  PhaseMap(\\State.phase) {
                      From(.idle) {
                          On(.load, to: .loaded)
                      }
                  }
              }
              var body: some Reducer<State, Action, Never> {
                  Reduce { _, _ in .none }
              }

              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                body.phaseMap(Self.phaseMap).reduce(into: &state, action: action)
              }
          }

          extension CompletePhaseFeature: Reducer {
          }
          """,
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("strict phase totality requires phase management")
  func strictTotalityRequiresPhaseManagement() {
    #if canImport(InnoFlowMacros)
      assertSwiftTestingMacroExpansion(
        """
        @InnoFlow(phaseManaged: false, strictPhaseTotality: true)
        struct InvalidStrictPhaseFeature {
            struct State: Sendable {}
            enum Action: Sendable {
                case run
            }
            var body: some Reducer<State, Action, Never> {
                Reduce { _, _ in .none }
            }
        }
        """,
        expandedSource: """
          struct InvalidStrictPhaseFeature {
              struct State: Sendable {}
              enum Action: Sendable {
                  case run
              }
              var body: some Reducer<State, Action, Never> {
                  Reduce { _, _ in .none }
              }

              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                body.reduce(into: &state, action: action)
              }
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message:
              "@InnoFlow(strictPhaseTotality: true) requires `phaseManaged: true` because strict totality validates the static PhaseMap owned by the macro",
            line: 1,
            column: 1,
            severity: .error
          )
        ],
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }
}
