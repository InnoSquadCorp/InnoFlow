// MARK: - ActionPathShapeMacroTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing

#if canImport(InnoFlowMacros)
  import InnoFlowMacros
#endif

// Action path synthesis shares the Output traversal, so conditional
// compilation, availability and local payload names behave identically for
// both enums. These expansions lock the Action side of that contract.
@Suite("Action path synthesis follows the declaration site", .timeLimit(.minutes(5)))
struct ActionPathShapeMacroTests {
  @Test("An Action case inside #if synthesizes its path inside the same condition")
  func actionCaseInsideIfConfigSynthesizesConditionalPath() throws {
    #if canImport(InnoFlowMacros)
      assertSwiftTestingMacroExpansion(
        """
        @_InnoFlowActionPaths
        enum Action {
            case plain(ChildAction)
            #if DEBUG
            case debugChild(ChildAction)
            #else
            case releaseChild(ChildAction)
            #endif
        }
        """,
        expandedSource: """
          enum Action {
              case plain(ChildAction)
              #if DEBUG
              case debugChild(ChildAction)
              #else
              case releaseChild(ChildAction)
              #endif

              static let plainCasePath = CasePath<Self, ChildAction>(
                embed: { childAction in
                  .plain(childAction)
                },
                extract: { action in
                  guard case .plain(let childAction) = action else {
                      return nil
                  }
                  return childAction
                }
              )

              #if DEBUG
              static let debugChildCasePath = CasePath<Self, ChildAction>(
                embed: { childAction in
                  .debugChild(childAction)
                },
                extract: { action in
                  guard case .debugChild(let childAction) = action else {
                      return nil
                  }
                  return childAction
                }
              )
              #else
              static let releaseChildCasePath = CasePath<Self, ChildAction>(
                embed: { childAction in
                  .releaseChild(childAction)
                },
                extract: { action in
                  guard case .releaseChild(let childAction) = action else {
                      return nil
                  }
                  return childAction
                }
              )
              #endif
          }
          """,
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("Action cases inside #elseif and nested #if keep their conditional structure")
  func actionCasesInsideElseIfAndNestedIfConfigKeepTheirStructure() throws {
    #if canImport(InnoFlowMacros)
      assertSwiftTestingMacroExpansion(
        """
        @_InnoFlowActionPaths
        enum Action {
            #if os(macOS)
            case desktop(ChildAction)
            #elseif os(iOS)
            case phone(ChildAction)
            #if DEBUG
            case phoneRow(id: Int, action: ChildAction)
            #endif
            #else
            case other(ChildAction)
            #endif
        }
        """,
        expandedSource: """
          enum Action {
              #if os(macOS)
              case desktop(ChildAction)
              #elseif os(iOS)
              case phone(ChildAction)
              #if DEBUG
              case phoneRow(id: Int, action: ChildAction)
              #endif
              #else
              case other(ChildAction)
              #endif

              #if os(macOS)
              static let desktopCasePath = CasePath<Self, ChildAction>(
                embed: { childAction in
                  .desktop(childAction)
                },
                extract: { action in
                  guard case .desktop(let childAction) = action else {
                      return nil
                  }
                  return childAction
                }
              )
              #elseif os(iOS)
              static let phoneCasePath = CasePath<Self, ChildAction>(
                embed: { childAction in
                  .phone(childAction)
                },
                extract: { action in
                  guard case .phone(let childAction) = action else {
                      return nil
                  }
                  return childAction
                }
              )
              #if DEBUG
              static let phoneRowActionPath = CollectionActionPath<Self, Int, ChildAction>(
                embed: { id, action in
                  .phoneRow(id: id, action: action)
                },
                extract: { action in
                  guard case let .phoneRow(id, childAction) = action else {
                      return nil
                  }
                  return (id, childAction)
                }
              )
              #endif
              #else
              static let otherCasePath = CasePath<Self, ChildAction>(
                embed: { childAction in
                  .other(childAction)
                },
                extract: { action in
                  guard case .other(let childAction) = action else {
                      return nil
                  }
                  return childAction
                }
              )
              #endif
          }
          """,
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("A manual Action path replaces synthesis wherever its declaration is active")
  func manualActionPathsReplaceSynthesisWhereTheyAreActive() throws {
    #if canImport(InnoFlowMacros)
      assertSwiftTestingMacroExpansion(
        """
        @_InnoFlowActionPaths
        enum Action {
            case named(_ action: ChildAction)
            case row(id: Int, action: ChildAction)
            case child(ChildAction)
            #if DEBUG
            case debug(ChildAction)
            static let debugCasePath = makeDebugPath()
            #endif

            static let namedCasePath = makeNamedPath()
            static var rowActionPath: CollectionActionPath<Self, Int, ChildAction> {
                makeRowPath()
            }
            #if LEGACY_PATHS
            static let childCasePath = makeChildPath()
            #endif
        }
        """,
        expandedSource: """
          enum Action {
              case named(_ action: ChildAction)
              case row(id: Int, action: ChildAction)
              case child(ChildAction)
              #if DEBUG
              case debug(ChildAction)
              static let debugCasePath = makeDebugPath()
              #endif

              static let namedCasePath = makeNamedPath()
              static var rowActionPath: CollectionActionPath<Self, Int, ChildAction> {
                  makeRowPath()
              }
              #if LEGACY_PATHS
              static let childCasePath = makeChildPath()
              #endif

              #if !((LEGACY_PATHS))
              static let childCasePath = CasePath<Self, ChildAction>(
                embed: { childAction in
                  .child(childAction)
                },
                extract: { action in
                  guard case .child(let childAction) = action else {
                      return nil
                  }
                  return childAction
                }
              )
              #endif
          }
          """,
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("The same Action case name in separate conditions gets a path in each")
  func sameActionCaseNameInSeparateConditionsSynthesizesBothPaths() throws {
    #if canImport(InnoFlowMacros)
      assertSwiftTestingMacroExpansion(
        """
        @_InnoFlowActionPaths
        enum Action {
            case plain
            #if FLAG_A
            case child(ChildAction)
            #endif
            #if FLAG_B
            case child(Int)
            #endif
        }
        """,
        expandedSource: """
          enum Action {
              case plain
              #if FLAG_A
              case child(ChildAction)
              #endif
              #if FLAG_B
              case child(Int)
              #endif

              #if FLAG_A
              static let childCasePath = CasePath<Self, ChildAction>(
                embed: { childAction in
                  .child(childAction)
                },
                extract: { action in
                  guard case .child(let childAction) = action else {
                      return nil
                  }
                  return childAction
                }
              )
              #endif

              #if FLAG_B
              static let childCasePath = CasePath<Self, Int>(
                embed: { childAction in
                  .child(childAction)
                },
                extract: { action in
                  guard case .child(let childAction) = action else {
                      return nil
                  }
                  return childAction
                }
              )
              #endif
          }
          """,
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("A payload with a local name but no argument label synthesizes a CasePath")
  func localPayloadNameWithoutLabelSynthesizesCasePath() throws {
    #if canImport(InnoFlowMacros)
      assertSwiftTestingMacroExpansion(
        """
        @_InnoFlowActionPaths
        enum Action {
            case named(_ action: ChildAction)
        }
        """,
        expandedSource: """
          enum Action {
              case named(_ action: ChildAction)

              static let namedCasePath = CasePath<Self, ChildAction>(
                embed: { childAction in
                  .named(childAction)
                },
                extract: { action in
                  guard case .named(let childAction) = action else {
                      return nil
                  }
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

  @Test("Generated Action paths mirror availability and skip unavailable cases")
  func actionPathsMirrorAvailability() throws {
    #if canImport(InnoFlowMacros)
      assertSwiftTestingMacroExpansion(
        """
        @_InnoFlowActionPaths
        enum Action {
            @available(*, deprecated, message: "old")
            case legacy(ChildAction)
            @available(*, unavailable)
            case removed(ChildAction)
            @available(*, deprecated, renamed: "current")
            case previous(id: Int, action: ChildAction)
        }
        """,
        expandedSource: """
          enum Action {
              @available(*, deprecated, message: "old")
              case legacy(ChildAction)
              @available(*, unavailable)
              case removed(ChildAction)
              @available(*, deprecated, renamed: "current")
              case previous(id: Int, action: ChildAction)

              @available(*, deprecated, message: "old")
              static let legacyCasePath = CasePath<Self, ChildAction>(
                embed: { childAction in
                  .legacy(childAction)
                },
                extract: { action in
                  guard case .legacy(let childAction) = action else {
                      return nil
                  }
                  return childAction
                }
              )

              @available(*, deprecated)
              static let previousActionPath = CollectionActionPath<Self, Int, ChildAction>(
                embed: { id, action in
                  .previous(id: id, action: action)
                },
                extract: { action in
                  guard case let .previous(id, childAction) = action else {
                      return nil
                  }
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

  @Test("A feature that states Reducer conformance itself receives no extension")
  func statedReducerConformanceReceivesNoExtension() throws {
    #if canImport(InnoFlowMacros)
      assertSwiftTestingMacroExpansion(
        """
        @InnoFlow
        struct ExplicitConformance: Reducer {
            struct State: Sendable {}
            enum Action: Sendable {
                case increment
            }
            var body: some Reducer<State, Action, Never> {
                Reduce { state, action in .none }
            }
        }
        """,
        expandedSource: """
          struct ExplicitConformance: Reducer {
              struct State: Sendable {}
              enum Action: Sendable {
                  case increment
              }
              var body: some Reducer<State, Action, Never> {
                  Reduce { state, action in .none }
              }

              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                body.reduce(into: &state, action: action)
              }
          }
          """,
        macros: testMacros,
        missingConformances: []
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("A child reducer may apply its own phase map inside a phase-managed parent")
  func childPhaseMapInsideScopeIsNotTheParentsPhaseMap() throws {
    #if canImport(InnoFlowMacros)
      assertSwiftTestingMacroExpansion(
        """
        @InnoFlow(phaseManaged: true)
        struct Parent {
            struct State: Sendable {
                enum Phase: Hashable, Sendable {
                    case idle
                }
                var phase: Phase = .idle
                var child = Child.State()
            }
            enum Action: Sendable {
                case child(Child.Action)
            }
            static var phaseMap: PhaseMap<State, Action, State.Phase> {
                PhaseMap(\\State.phase) {
                    From(.idle) {}
                }
            }
            var body: some Reducer<State, Action, Never> {
                CombineReducers {
                    Reduce<State, Action, Never> { state, action in .none }
                    Scope(
                        state: \\.child,
                        action: Action.childCasePath,
                        reducer: Child().phaseMap(Child.phaseMap)
                    )
                }
            }
        }
        """,
        expandedSource: """
          struct Parent {
              struct State: Sendable {
                  enum Phase: Hashable, Sendable {
                      case idle
                  }
                  var phase: Phase = .idle
                  var child = Child.State()
              }
              enum Action: Sendable {
                  case child(Child.Action)

                  static let childCasePath = CasePath<Self, Child.Action>(
                    embed: { childAction in
                      .child(childAction)
                    },
                    extract: { action in
                      guard case .child(let childAction) = action else {
                          return nil
                      }
                      return childAction
                    }
                  )
              }
              static var phaseMap: PhaseMap<State, Action, State.Phase> {
                  PhaseMap(\\State.phase) {
                      From(.idle) {}
                  }
              }
              var body: some Reducer<State, Action, Never> {
                  CombineReducers {
                      Reduce<State, Action, Never> { state, action in .none }
                      Scope(
                          state: \\.child,
                          action: Action.childCasePath,
                          reducer: Child().phaseMap(Child.phaseMap)
                      )
                  }
              }

              func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                body.phaseMap(Self.phaseMap).reduce(into: &state, action: action)
              }
          }

          extension Parent: Reducer {
          }
          """,
        macros: testMacros
      )
    #else
      Issue.record("Macros are only supported when running tests for the host platform")
    #endif
  }

  @Test("A phase map applied to the receiver of a child-domain combinator is still the parent's")
  func phaseMapOnCombinatorReceiverIsStillDiagnosed() throws {
    #if canImport(InnoFlowMacros)
      assertSwiftTestingMacroExpansion(
        """
        @InnoFlow(phaseManaged: true)
        struct Parent {
            struct State: Sendable {
                enum Phase: Hashable, Sendable {
                    case idle
                }
                var phase: Phase = .idle
                var child: Child.State?
            }
            enum Action: Sendable {
                case child(Child.Action)
            }
            static var phaseMap: PhaseMap<State, Action, State.Phase> {
                PhaseMap(\\State.phase) {
                    From(.idle) {}
                }
            }
            var body: some Reducer<State, Action, Never> {
                Reduce<State, Action, Never> { state, action in .none }
                    .phaseMap(Self.phaseMap)
                    .optionalChild(
                        state: \\.child,
                        action: Action.childCasePath,
                        instanceID: \\.id,
                        reducer: Child()
                    )
            }
        }
        """,
        expandedSource: """
          struct Parent {
              struct State: Sendable {
                  enum Phase: Hashable, Sendable {
                      case idle
                  }
                  var phase: Phase = .idle
                  var child: Child.State?
              }
              enum Action: Sendable {
                  case child(Child.Action)

                  static let childCasePath = CasePath<Self, Child.Action>(
                    embed: { childAction in
                      .child(childAction)
                    },
                    extract: { action in
                      guard case .child(let childAction) = action else {
                          return nil
                      }
                      return childAction
                    }
                  )
              }
              static var phaseMap: PhaseMap<State, Action, State.Phase> {
                  PhaseMap(\\State.phase) {
                      From(.idle) {}
                  }
              }
              var body: some Reducer<State, Action, Never> {
                  Reduce<State, Action, Never> { state, action in .none }
                      .phaseMap(Self.phaseMap)
                      .optionalChild(
                          state: \\.child,
                          action: Action.childCasePath,
                          instanceID: \\.id,
                          reducer: Child()
                      )
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
    "A phase map inside a child-domain argument is not the feature's own",
    arguments: [
      "Scope(state: \\.child, action: Action.childCasePath, reducer: CHILD)",
      "Scope.init(state: \\.child, action: Action.childCasePath, reducer: CHILD)",
      "Scope<State, Action, Child>(state: \\.child, action: Action.childCasePath, reducer: CHILD)",
      "Scope<State, Action, Child>.init(state: \\.child, action: Action.childCasePath, reducer: CHILD)",
      "InnoFlow.Scope.init(state: \\.child, action: Action.childCasePath, reducer: CHILD)",
      "IfLet(state: \\.optional, action: Action.childCasePath, reducer: CHILD)",
      "IfLet.init(state: \\.optional, action: Action.childCasePath, reducer: CHILD)",
      "IfCaseLet(state: State.loadedCasePath, action: Action.childCasePath, reducer: CHILD)",
      "IfCaseLet.init(state: State.loadedCasePath, action: Action.childCasePath, reducer: CHILD)",
      "ForEachReducer(state: \\.rows, action: Action.rowActionPath, reducer: CHILD)",
      "ForEachReducer.init(state: \\.rows, action: Action.rowActionPath, reducer: CHILD)",
      "ForEachIdentifiedReducer(state: \\.rows, action: Action.rowActionPath, reducer: CHILD)",
      "ForEachIdentifiedReducer.init(state: \\.rows, action: Action.rowActionPath, reducer: CHILD)",
      "OWN.optionalChild(state: \\.optional, action: Action.childCasePath, instanceID: \\.id, reducer: CHILD)",
      "OptionalChildLifetime(parent: OWN, state: \\.optional, action: Action.childCasePath, instanceID: { $0.id }, reducer: CHILD)",
      "OptionalChildLifetime.init(parent: OWN, state: \\.optional, action: Action.childCasePath, instanceID: { $0.id }, reducer: CHILD)",
      "OptionalChildLifetime<Reduce<State, Action, Never>, Child, Int>(parent: OWN, state: \\.optional, action: Action.childCasePath, instanceID: { $0.id }, reducer: CHILD)",
      "CombineReducers { OWN; Scope.init(state: \\.child, action: Action.childCasePath, reducer: CHILD) }",
    ])
  func childPhaseMapIsNotTheFeaturesOwn(composition: String) throws {
    #if canImport(InnoFlowMacros)
      let diagnostics = try phaseManagedDiagnostics(
        body:
          composition
          .replacingOccurrences(of: "OWN", with: "Reduce<State, Action, Never> { _, _ in .none }")
          .replacingOccurrences(of: "CHILD", with: "Child().phaseMap(Child.phaseMap)")
      )
      #expect(diagnostics.isEmpty)
    #endif
  }

  @Test(
    "A phase map in the feature's own domain is still diagnosed",
    arguments: [
      "OWN",
      "OWN.optionalChild(state: \\.optional, action: Action.childCasePath, instanceID: \\.id, reducer: CHILD)",
      "OptionalChildLifetime(parent: OWN, state: \\.optional, action: Action.childCasePath, instanceID: { $0.id }, reducer: CHILD)",
      "OptionalChildLifetime.init(parent: OWN, state: \\.optional, action: Action.childCasePath, instanceID: { $0.id }, reducer: CHILD)",
      "OptionalChildLifetime(parent: CombineReducers { OWN }, state: \\.optional, action: Action.childCasePath, instanceID: { $0.id }, reducer: Child())",
      "CombineReducers { OWN; Scope.init(state: \\.child, action: Action.childCasePath, reducer: CHILD) }",
      "Scope.init(state: \\.child, action: Action.childCasePath, reducer: CHILD).phaseMap(Self.phaseMap)",
      "IfLet(state: \\.optional, action: Action.childCasePath, reducer: Child()).phaseMap(Self.phaseMap)",
    ])
  func ownDomainPhaseMapIsStillDiagnosed(composition: String) throws {
    #if canImport(InnoFlowMacros)
      let diagnostics = try phaseManagedDiagnostics(
        body:
          composition
          .replacingOccurrences(
            of: "OWN",
            with: "Reduce<State, Action, Never> { _, _ in .none }.phaseMap(Self.phaseMap)"
          )
          .replacingOccurrences(of: "CHILD", with: "Child().phaseMap(Child.phaseMap)")
      )
      #expect(diagnostics.count == 1)
      #expect(
        diagnostics.first?.diagMessage.diagnosticID
          == MessageID(domain: "InnoFlowMacro", id: "PhaseManagedExplicitPhaseMap"))
      #expect(diagnostics.first?.diagMessage.severity == .error)
    #endif
  }

  #if canImport(InnoFlowMacros)
    /// The diagnostics `@InnoFlow(phaseManaged: true)` reports for a feature
    /// whose `body` is `body`.
    private func phaseManagedDiagnostics(body: String) throws -> [Diagnostic] {
      let source = """
        @InnoFlow(phaseManaged: true)
        struct Parent {
          struct State {
            enum Phase { case idle }
            var phase: Phase = .idle
          }
          enum Action { case child(Child.Action) }
          static var phaseMap: PhaseMap<State, Action, State.Phase> {
            PhaseMap(\\.phase) { From(.idle) {} }
          }
          var body: some Reducer<State, Action, Never> {
            \(body)
          }
        }
        """
      let declaration = try #require(
        Parser.parse(source: source).statements.first?.item.as(StructDeclSyntax.self))
      let attribute = try #require(declaration.attributes.first?.as(AttributeSyntax.self))
      let context = BasicMacroExpansionContext()
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
