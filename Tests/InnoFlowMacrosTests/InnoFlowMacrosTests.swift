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
    "_InnoFlowActionPaths": InnoFlowActionPathsMacro.self,
  ]
#endif

@Suite("Macro Tests")
struct InnoFlowMacrosTests {

  @Test("@InnoFlow synthesizes reduce forwarding for body-based authoring")
  func bodyAuthoringAddsConformanceAndForwarder() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct CounterFeature {
            struct State: Sendable { var count = 0 }
            enum Action: Sendable { case increment }

            var body: some Reducer<State, Action> {
                Reduce { state, action in
                    switch action {
                    case .increment:
                        state.count += 1
                        return .none
                    }
                }
            }
        }
        """,
        expandedSource: """
          struct CounterFeature {
              struct State: Sendable { var count = 0 }
              enum Action: Sendable { case increment }

              var body: some Reducer<State, Action> {
                  Reduce { state, action in
                      switch action {
                      case .increment:
                          state.count += 1
                          return .none
                      }
                  }
              }

              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                body.reduce(into: &state, action: action)
              }
          }
          extension CounterFeature: Reducer {}
          """,
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("@InnoFlow synthesizes case paths for single child-action cases")
  func childActionCasePathIsSynthesized() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct ParentFeature {
            struct State: Sendable {}
            enum Action: Sendable {
                case child(ChildAction)
            }
            enum ChildAction: Sendable {
                case start
            }

            var body: some Reducer<State, Action> {
                Reduce { state, action in .none }
            }
        }
        """,
        expandedSource: """
          struct ParentFeature {
              struct State: Sendable {}
              enum Action: Sendable {
                  case child(ChildAction)
              }
              enum ChildAction: Sendable {
                  case start
              }

              var body: some Reducer<State, Action> {
                  Reduce { state, action in .none }
              }

              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                body.reduce(into: &state, action: action)
              }
          }
          extension ParentFeature: Reducer {}
          extension ParentFeature.Action {
            static let childCasePath = CasePath<Self, ChildAction>(
              embed: { childAction in
                .child(childAction)
              },
              extract: { action in
                guard case .child(let childAction) = action else { return nil }
                return childAction
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

  @Test("@InnoFlow synthesizes collection action paths for id/action cases")
  func collectionActionPathIsSynthesized() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct TodoFeature {
            struct State: Sendable {}
            enum Action: Sendable {
                case todo(id: UUID, action: TodoAction)
            }
            enum TodoAction: Sendable {
                case toggle
            }

            var body: some Reducer<State, Action> {
                Reduce { state, action in .none }
            }
        }
        """,
        expandedSource: """
          struct TodoFeature {
              struct State: Sendable {}
              enum Action: Sendable {
                  case todo(id: UUID, action: TodoAction)
              }
              enum TodoAction: Sendable {
                  case toggle
              }

              var body: some Reducer<State, Action> {
                  Reduce { state, action in .none }
              }

              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                body.reduce(into: &state, action: action)
              }
          }
          extension TodoFeature: Reducer {}
          extension TodoFeature.Action {
            static let todoActionPath = CollectionActionPath<Self, UUID, TodoAction>(
              embed: { id, action in
                .todo(id: id, action: action)
              },
              extract: { action in
                guard case let .todo(id, childAction) = action else { return nil }
                return (id, childAction)
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

  @Test("@InnoFlow strips one leading underscore from generated case path names")
  func leadingUnderscoreCasePathUsesCleanName() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct LoadingFeature {
            struct State: Sendable {}
            enum Action: Sendable {
                case _loaded(ChildAction)
            }
            enum ChildAction: Sendable {
                case start
            }

            var body: some Reducer<State, Action> {
                Reduce { state, action in .none }
            }
        }
        """,
        expandedSource: """
          struct LoadingFeature {
              struct State: Sendable {}
              enum Action: Sendable {
                  case _loaded(ChildAction)
              }
              enum ChildAction: Sendable {
                  case start
              }

              var body: some Reducer<State, Action> {
                  Reduce { state, action in .none }
              }

              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                body.reduce(into: &state, action: action)
              }
          }
          extension LoadingFeature: Reducer {}
          extension LoadingFeature.Action {
            static let loadedCasePath = CasePath<Self, ChildAction>(
              embed: { childAction in
                ._loaded(childAction)
              },
              extract: { action in
                guard case ._loaded(let childAction) = action else { return nil }
                return childAction
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

  @Test("@InnoFlow synthesizes payload case paths for single unlabeled payload cases")
  func singlePayloadCasePathIsSynthesized() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct LoadingFeature {
            struct State: Sendable {}
            enum Action: Sendable {
                case _loaded(String)
            }

            var body: some Reducer<State, Action> {
                Reduce { state, action in .none }
            }
        }
        """,
        expandedSource: """
          struct LoadingFeature {
              struct State: Sendable {}
              enum Action: Sendable {
                  case _loaded(String)
              }

              var body: some Reducer<State, Action> {
                  Reduce { state, action in .none }
              }

              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                body.reduce(into: &state, action: action)
              }
          }
          extension LoadingFeature: Reducer {}
          extension LoadingFeature.Action {
            static let loadedCasePath = CasePath<Self, String>(
              embed: { childAction in
                ._loaded(childAction)
              },
              extract: { action in
                guard case ._loaded(let childAction) = action else { return nil }
                return childAction
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

  @Test("@InnoFlow leaves empty action enums without synthesized action paths")
  func emptyActionEnumDoesNotSynthesizeActionPaths() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct EmptyActionFeature {
            struct State: Sendable {}
            enum Action: Sendable {}

            var body: some Reducer<State, Action> {
                Reduce { state, action in .none }
            }
        }
        """,
        expandedSource: """
          struct EmptyActionFeature {
              struct State: Sendable {}
              enum Action: Sendable {}

              var body: some Reducer<State, Action> {
                  Reduce { state, action in .none }
              }

              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                body.reduce(into: &state, action: action)
              }
          }
          extension EmptyActionFeature: Reducer {}
          """,
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("@InnoFlow notes labeled single-parameter cases instead of silently skipping them")
  func labeledSingleParameterCaseDoesNotSynthesizeActionPath() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct LabeledActionFeature {
            struct State: Sendable {}
            enum Action: Sendable {
                case child(action: ChildAction)
            }
            enum ChildAction: Sendable {
                case start
            }

            var body: some Reducer<State, Action> {
                Reduce { state, action in .none }
            }
        }
        """,
        expandedSource: """
          struct LabeledActionFeature {
              struct State: Sendable {}
              enum Action: Sendable {
                  case child(action: ChildAction)
              }
              enum ChildAction: Sendable {
                  case start
              }

              var body: some Reducer<State, Action> {
                  Reduce { state, action in .none }
              }

              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                body.reduce(into: &state, action: action)
              }
          }
          extension LabeledActionFeature: Reducer {}
          """,
        diagnostics: [
          DiagnosticSpec(
            message:
              "case `child` has a labeled payload (`action:`); CasePath synthesis only handles unlabeled single payloads. Drop the label or declare a static `childCasePath` manually",
            line: 5,
            column: 14,
            severity: .note
          )
        ],
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("@InnoFlow labeled-payload notes use the generated action path base name")
  func labeledLeadingUnderscorePayloadNoteUsesGeneratedBaseName() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct LabeledActionFeature {
            struct State: Sendable {}
            enum Action: Sendable {
                case _child(action: ChildAction)
            }
            enum ChildAction: Sendable {
                case start
            }

            var body: some Reducer<State, Action> {
                Reduce { state, action in .none }
            }
        }
        """,
        expandedSource: """
          struct LabeledActionFeature {
              struct State: Sendable {}
              enum Action: Sendable {
                  case _child(action: ChildAction)
              }
              enum ChildAction: Sendable {
                  case start
              }

              var body: some Reducer<State, Action> {
                  Reduce { state, action in .none }
              }

              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                body.reduce(into: &state, action: action)
              }
          }
          extension LabeledActionFeature: Reducer {}
          """,
        diagnostics: [
          DiagnosticSpec(
            message:
              "case `_child` has a labeled payload (`action:`); CasePath synthesis only handles unlabeled single payloads. Drop the label or declare a static `childCasePath` manually",
            line: 5,
            column: 14,
            severity: .note
          )
        ],
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("@InnoFlow notes multi-parameter cases instead of silently skipping them")
  func multiParameterCaseDoesNotSynthesizeActionPath() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct MultiParameterActionFeature {
            struct State: Sendable {}
            enum Action: Sendable {
                case child(id: UUID, action: ChildAction, metadata: String)
            }
            enum ChildAction: Sendable {
                case start
            }

            var body: some Reducer<State, Action> {
                Reduce { state, action in .none }
            }
        }
        """,
        expandedSource: """
          struct MultiParameterActionFeature {
              struct State: Sendable {}
              enum Action: Sendable {
                  case child(id: UUID, action: ChildAction, metadata: String)
              }
              enum ChildAction: Sendable {
                  case start
              }

              var body: some Reducer<State, Action> {
                  Reduce { state, action in .none }
              }

              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                body.reduce(into: &state, action: action)
              }
          }
          extension MultiParameterActionFeature: Reducer {}
          """,
        diagnostics: [
          DiagnosticSpec(
            message:
              "case `child` has multiple payload parameters; CasePath synthesis only handles unlabeled single payloads and `id:action:` collection routes. Declare a static path manually if you need one",
            line: 5,
            column: 14,
            severity: .note
          )
        ],
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("@InnoFlow notes optional payload cases while still synthesizing a CasePath")
  func optionalPayloadCaseEmitsNote() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct OptionalPayloadFeature {
            struct State: Sendable {}
            enum Action: Sendable {
                case child(ChildAction?)
            }
            enum ChildAction: Sendable {
                case start
            }

            var body: some Reducer<State, Action> {
                Reduce { state, action in .none }
            }
        }
        """,
        expandedSource: """
          struct OptionalPayloadFeature {
              struct State: Sendable {}
              enum Action: Sendable {
                  case child(ChildAction?)
              }
              enum ChildAction: Sendable {
                  case start
              }

              var body: some Reducer<State, Action> {
                  Reduce { state, action in .none }
              }

              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                body.reduce(into: &state, action: action)
              }
          }
          extension OptionalPayloadFeature: Reducer {}
          extension OptionalPayloadFeature.Action {
            static let childCasePath = CasePath<Self, ChildAction?>(
              embed: { childAction in
                .child(childAction)
              },
              extract: { action in
                guard case .child(let childAction) = action else { return nil }
                return childAction
              }
            )
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message:
              "case `child` has an optional payload; the synthesized CasePath still works but `.child(nil)` round-trips as `nil` — consider splitting into two cases or declaring a custom path",
            line: 5,
            column: 14,
            severity: .note
          )
        ],
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("@InnoFlow strips one leading underscore from generated collection action path names")
  func leadingUnderscoreCollectionActionPathUsesCleanName() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct TodoListFeature {
            struct State: Sendable {}
            enum Action: Sendable {
                case _todo(id: UUID, action: TodoAction)
            }
            enum TodoAction: Sendable {
                case toggle
            }

            var body: some Reducer<State, Action> {
                Reduce { state, action in .none }
            }
        }
        """,
        expandedSource: """
          struct TodoListFeature {
              struct State: Sendable {}
              enum Action: Sendable {
                  case _todo(id: UUID, action: TodoAction)
              }
              enum TodoAction: Sendable {
                  case toggle
              }

              var body: some Reducer<State, Action> {
                  Reduce { state, action in .none }
              }

              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                body.reduce(into: &state, action: action)
              }
          }
          extension TodoListFeature: Reducer {}
          extension TodoListFeature.Action {
            static let todoActionPath = CollectionActionPath<Self, UUID, TodoAction>(
              embed: { id, action in
                ._todo(id: id, action: action)
              },
              extract: { action in
                guard case let ._todo(id, childAction) = action else { return nil }
                return (id, childAction)
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

  @Test("@InnoFlow diagnoses stripped action path collisions")
  func strippedActionPathCollisionsAreDiagnosed() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct CollisionFeature {
            struct State: Sendable {}
            enum Action: Sendable {
                case child(ChildAction)
                case _child(ChildAction)
            }
            enum ChildAction: Sendable {
                case start
            }

            var body: some Reducer<State, Action> {
                Reduce { state, action in .none }
            }
        }
        """,
        expandedSource: """
          struct CollisionFeature {
              struct State: Sendable {}
              enum Action: Sendable {
                  case child(ChildAction)
                  case _child(ChildAction)
              }
              enum ChildAction: Sendable {
                  case start
              }

              var body: some Reducer<State, Action> {
                  Reduce { state, action in .none }
              }

              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                body.reduce(into: &state, action: action)
              }
          }
          extension CollisionFeature: Reducer {}
          extension CollisionFeature.Action {
            static let childCasePath = CasePath<Self, ChildAction>(
              embed: { childAction in
                .child(childAction)
              },
              extract: { action in
                guard case .child(let childAction) = action else { return nil }
                return childAction
              }
            )
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message:
              "generated action path name collides after stripping leading underscore; declare an explicit static alias or rename the case",
            line: 6,
            column: 10
          )
        ],
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("@InnoFlow diagnoses generated action path collisions in static multi-bindings")
  func staticMultiBindingActionPathCollisionsAreDiagnosed() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct CollisionFeature {
            struct State: Sendable {}
            enum Action: Sendable {
                static let unrelated = 0, childCasePath = 1
                case child(ChildAction)
            }
            enum ChildAction: Sendable {
                case start
            }

            var body: some Reducer<State, Action> {
                Reduce { state, action in .none }
            }
        }
        """,
        expandedSource: """
          struct CollisionFeature {
              struct State: Sendable {}
              enum Action: Sendable {
                  static let unrelated = 0, childCasePath = 1
                  case child(ChildAction)
              }
              enum ChildAction: Sendable {
                  case start
              }

              var body: some Reducer<State, Action> {
                  Reduce { state, action in .none }
              }

              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                body.reduce(into: &state, action: action)
              }
          }
          extension CollisionFeature: Reducer {}
          """,
        diagnostics: [
          DiagnosticSpec(
            message:
              "generated action path name collides after stripping leading underscore; declare an explicit static alias or rename the case",
            line: 6,
            column: 14
          )
        ],
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("@InnoFlow rejects missing body")
  func missingBodyIsRejected() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct MissingBodyFeature {
            struct State: Sendable {}
            enum Action: Sendable {}
        }
        """,
        expandedSource: """
          struct MissingBodyFeature {
              struct State: Sendable {}
              enum Action: Sendable {}
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message: "@InnoFlow requires `var body: some Reducer<State, Action>`",
            line: 1,
            column: 1
          )
        ],
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("@InnoFlow rejects explicit reduce authoring")
  func explicitReduceIsRejected() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct LegacyFeature {
            struct State: Sendable { var count = 0 }
            enum Action: Sendable { case increment }

            func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                state.count += 1
                return .none
            }
        }
        """,
        expandedSource: """
          struct LegacyFeature {
              struct State: Sendable { var count = 0 }
              enum Action: Sendable { case increment }

              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                  state.count += 1
                  return .none
              }
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message:
              "@InnoFlow no longer supports explicit `reduce(into:action:)` authoring; declare `var body: some Reducer<State, Action>` instead",
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
          struct LegacyFeature {
              struct State: Sendable { var count = 0 }
              enum Action: Sendable { case increment }

              var body: some Reducer<State, Action> {
                  Reduce { state, action in
                      state.count += 1
                      return .none
                  }
              }
          }
          """,
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("@InnoFlow omits explicit reduce Fix-It when body contains a multiline string")
  func explicitReduceWithMultilineStringOmitsFixIt() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct LegacyFeature {
            struct State: Sendable { var message = "" }
            enum Action: Sendable { case log }

            func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                state.message = \"\"\"
                line 1
                  line 2
                \"\"\"
                return .none
            }
        }
        """,
        expandedSource: """
          struct LegacyFeature {
              struct State: Sendable { var message = "" }
              enum Action: Sendable { case log }

              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                  state.message = \"\"\"
                  line 1
                    line 2
                  \"\"\"
                  return .none
              }
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message:
              "@InnoFlow no longer supports explicit `reduce(into:action:)` authoring; declare `var body: some Reducer<State, Action>` instead",
            line: 1,
            column: 1
          )
        ],
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("@InnoFlow rejects body without reducer surface")
  func invalidBodyTypeIsRejected() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct InvalidBodyFeature {
            struct State: Sendable {}
            enum Action: Sendable {}

            var body: Int { 0 }
        }
        """,
        expandedSource: """
          struct InvalidBodyFeature {
              struct State: Sendable {}
              enum Action: Sendable {}

              var body: Int { 0 }
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message: """
              Invalid body signature for @InnoFlow.
              Expected:
              var body: some Reducer<State, Action>
              Detected issues: `body` type `Int` must be an opaque type (`some Reducer<State, Action>`).
              Remediation: expose reducer composition from `body` using `Reduce`, `CombineReducers`, and `Scope`.
              """,
            line: 1,
            column: 1
          )
        ],
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("@InnoFlow rejects `any Reducer` (existential instead of opaque)")
  func anyReducerIsRejected() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct AnyReducerFeature {
            struct State: Sendable {}
            enum Action: Sendable {}

            var body: any Reducer<State, Action> {
                Reduce { state, action in .none }
            }
        }
        """,
        expandedSource: """
          struct AnyReducerFeature {
              struct State: Sendable {}
              enum Action: Sendable {}

              var body: any Reducer<State, Action> {
                  Reduce { state, action in .none }
              }
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message: """
              Invalid body signature for @InnoFlow.
              Expected:
              var body: some Reducer<State, Action>
              Detected issues: `body` must use `some` (not `any`).
              Remediation: expose reducer composition from `body` using `Reduce`, `CombineReducers`, and `Scope`.
              """,
            line: 1,
            column: 1
          )
        ],
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("@InnoFlow rejects wrong constraint name like ReducerLike")
  func wrongConstraintNameIsRejected() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct WrongConstraintFeature {
            struct State: Sendable {}
            enum Action: Sendable {}

            var body: some ReducerLike<State, Action> {
                Reduce { state, action in .none }
            }
        }
        """,
        expandedSource: """
          struct WrongConstraintFeature {
              struct State: Sendable {}
              enum Action: Sendable {}

              var body: some ReducerLike<State, Action> {
                  Reduce { state, action in .none }
              }
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message: """
              Invalid body signature for @InnoFlow.
              Expected:
              var body: some Reducer<State, Action>
              Detected issues: `body` type must constrain to `Reducer`, found `ReducerLike`.
              Remediation: expose reducer composition from `body` using `Reduce`, `CombineReducers`, and `Scope`.
              """,
            line: 1,
            column: 1
          )
        ],
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("@InnoFlow rejects wrong generic parameters like Reducer<Int, String>")
  func wrongGenericParamsRejected() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct WrongGenericsFeature {
            struct State: Sendable {}
            enum Action: Sendable {}

            var body: some Reducer<Int, String> {
                Reduce { state, action in .none }
            }
        }
        """,
        expandedSource: """
          struct WrongGenericsFeature {
              struct State: Sendable {}
              enum Action: Sendable {}

              var body: some Reducer<Int, String> {
                  Reduce { state, action in .none }
              }
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message: """
              Invalid body signature for @InnoFlow.
              Expected:
              var body: some Reducer<State, Action>
              Detected issues: first generic parameter must be `State`, found `Int`; second generic parameter must be `Action`, found `String`.
              Remediation: expose reducer composition from `body` using `Reduce`, `CombineReducers`, and `Scope`.
              """,
            line: 1,
            column: 1
          )
        ],
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("@InnoFlow rejects reduce and body declared together")
  func conflictingAuthoringModesAreRejected() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow
        struct ConflictingFeature {
            struct State: Sendable { var count = 0 }
            enum Action: Sendable { case increment }

            var body: some Reducer<State, Action> {
                Reduce { state, action in
                    state.count += 1
                    return .none
                }
            }

            func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                .none
            }
        }
        """,
        expandedSource: """
          struct ConflictingFeature {
              struct State: Sendable { var count = 0 }
              enum Action: Sendable { case increment }

              var body: some Reducer<State, Action> {
                  Reduce { state, action in
                      state.count += 1
                      return .none
                  }
              }

              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                  .none
              }
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message:
              "@InnoFlow no longer supports explicit `reduce(into:action:)` authoring; declare `var body: some Reducer<State, Action>` instead",
            line: 1,
            column: 1
          )
        ],
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("@InnoFlow(phaseManaged:) wraps body in static phaseMap")
  func phaseManagedAuthoringAddsPhaseMapWrapper() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow(phaseManaged: true)
        struct PhaseManagedFeature {
            struct State: Sendable {
                enum Phase: Hashable, Sendable {
                    case idle
                    case loading
                }
                var phase: Phase = .idle
            }
            enum Action: Sendable {
                case load
            }
            static var phaseMap: PhaseMap<State, Action, State.Phase> {
                PhaseMap(\\State.phase) {
                    From(.idle) {
                        On(.load, to: .loading)
                    }
                    From(.loading) {}
                }
            }
            var body: some Reducer<State, Action> {
                Reduce { state, action in .none }
            }
        }
        """,
        expandedSource: """
          struct PhaseManagedFeature {
              struct State: Sendable {
                  enum Phase: Hashable, Sendable {
                      case idle
                      case loading
                  }
                  var phase: Phase = .idle
              }
              enum Action: Sendable {
                  case load
              }
              static var phaseMap: PhaseMap<State, Action, State.Phase> {
                  PhaseMap(\\State.phase) {
                      From(.idle) {
                          On(.load, to: .loading)
                      }
                      From(.loading) {}
                  }
              }
              var body: some Reducer<State, Action> {
                  Reduce { state, action in .none }
              }

              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                body.phaseMap(Self.phaseMap).reduce(into: &state, action: action)
              }
          }

          extension PhaseManagedFeature: Reducer {
          }
          """,
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("@InnoFlow(phaseManaged:) requires static phaseMap")
  func phaseManagedRequiresStaticPhaseMap() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow(phaseManaged: true)
        struct MissingPhaseMapFeature {
            struct State: Sendable {
                enum Phase: Hashable, Sendable {
                    case idle
                }
                var phase: Phase = .idle
            }
            enum Action: Sendable {
                case load
            }
            var body: some Reducer<State, Action> {
                Reduce { state, action in .none }
            }
        }
        """,
        expandedSource: """
          struct MissingPhaseMapFeature {
              struct State: Sendable {
                  enum Phase: Hashable, Sendable {
                      case idle
                  }
                  var phase: Phase = .idle
              }
              enum Action: Sendable {
                  case load
              }
              var body: some Reducer<State, Action> {
                  Reduce { state, action in .none }
              }
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message:
              "@InnoFlow(phaseManaged: true) requires a static `phaseMap` property so the macro can synthesize `body.phaseMap(Self.phaseMap)`",
            line: 1,
            column: 1
          )
        ],
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("@InnoFlow(phaseManaged:) rejects explicit body phaseMap wrapping")
  func phaseManagedRejectsExplicitBodyPhaseMap() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow(phaseManaged: true)
        struct ExplicitPhaseMapFeature {
            struct State: Sendable {
                enum Phase: Hashable, Sendable {
                    case idle
                }
                var phase: Phase = .idle
            }
            enum Action: Sendable {
                case load
            }
            static var phaseMap: PhaseMap<State, Action, State.Phase> {
                PhaseMap(\\State.phase) {
                    From(.idle) {}
                }
            }
            var body: some Reducer<State, Action> {
                Reduce { state, action in .none }
                    .phaseMap(Self.phaseMap)
            }
        }
        """,
        expandedSource: """
          struct ExplicitPhaseMapFeature {
              struct State: Sendable {
                  enum Phase: Hashable, Sendable {
                      case idle
                  }
                  var phase: Phase = .idle
              }
              enum Action: Sendable {
                  case load
              }
              static var phaseMap: PhaseMap<State, Action, State.Phase> {
                  PhaseMap(\\State.phase) {
                      From(.idle) {}
                  }
              }
              var body: some Reducer<State, Action> {
                  Reduce { state, action in .none }
                      .phaseMap(Self.phaseMap)
              }
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message:
              "@InnoFlow(phaseManaged: true) synthesizes `body.phaseMap(Self.phaseMap)` automatically; remove the explicit `.phaseMap(...)` call from `body` or disable phaseManaged",
            line: 1,
            column: 1
          )
        ],
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test(
    "@InnoFlow(phaseManaged:) wraps reduce with phaseMap and warns on unreferenced phase cases"
  )
  func phaseManagedWarnsWhenPhaseCaseIsNeverReferencedFromPhaseMap() throws {
    #if canImport(InnoFlowMacros)
      assertMacroExpansion(
        """
        @InnoFlow(phaseManaged: true)
        struct UnreferencedPhaseFeature {
            struct State: Sendable {
                enum Phase: Hashable, Sendable {
                    case idle
                    case loading
                    case orphan
                }
                var phase: Phase = .idle
            }
            enum Action: Sendable {
                case load
            }
            static var phaseMap: PhaseMap<State, Action, State.Phase> {
                PhaseMap(\\State.phase) {
                    From(.idle) {
                        On(.load, to: .loading)
                    }
                }
            }
            var body: some Reducer<State, Action> {
                Reduce { state, action in .none }
            }
        }
        """,
        expandedSource: """
          struct UnreferencedPhaseFeature {
              struct State: Sendable {
                  enum Phase: Hashable, Sendable {
                      case idle
                      case loading
                      case orphan
                  }
                  var phase: Phase = .idle
              }
              enum Action: Sendable {
                  case load
              }
              static var phaseMap: PhaseMap<State, Action, State.Phase> {
                  PhaseMap(\\State.phase) {
                      From(.idle) {
                          On(.load, to: .loading)
                      }
                  }
              }
              var body: some Reducer<State, Action> {
                  Reduce { state, action in .none }
              }

              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                body.phaseMap(Self.phaseMap).reduce(into: &state, action: action)
              }
          }

          extension UnreferencedPhaseFeature: Reducer {
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message:
              "`Phase.orphan` is declared but never referenced from the static `phaseMap` — add a `From(.orphan) { ... }` rule, an `On(..., to: .orphan)` target, or remove the case if it is unused",
            line: 7,
            column: 18,
            severity: .warning
          )
        ],
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

}
