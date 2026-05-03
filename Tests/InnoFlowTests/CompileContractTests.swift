// MARK: - CompileContractTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import SwiftUI
import Testing
import os

@testable import InnoFlow
@testable import InnoFlowTesting

@Suite("Compile Contract Tests")
struct CompileContractTests {

  @Test("EffectID rejects dynamic String construction at compile time")
  func effectIDRejectsDynamicStringConstruction() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlow

      let dynamic = String("dynamic-id")
      let _ = EffectID(dynamic)
      """

    let result = try typecheckSource(
      source,
      moduleDirectory: moduleDirectory
    )

    #expect(result.status != 0)
    let diagnostics = result.normalizedOutput
    #expect(!diagnostics.isEmpty)
    #expect(
      diagnostics.localizedCaseInsensitiveContains("error")
        || diagnostics.localizedCaseInsensitiveContains("failed")
    )
    #expect(
      diagnostics.contains("EffectID")
        || diagnostics.contains("StaticString")
        || diagnostics.contains("String")
    )
  }

  @Test("Store.binding rejects non-bindable key paths at compile time")
  func bindingRejectsNonBindableKeyPathAtCompileTime() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlow

      struct NonBindableFeature: Reducer {
          struct State: Sendable, DefaultInitializable {
              var count = 0
              init() {}
          }

          enum Action: Sendable {
              case setCount(Int)
          }

          func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
              .none
          }
      }

      @MainActor
      func compileContract() {
          let store = Store(reducer: NonBindableFeature(), initialState: .init())
          _ = store.binding(\\.count, send: { .setCount($0) })
      }
      """

    let result = try typecheckSource(
      source,
      moduleDirectory: moduleDirectory
    )

    #expect(result.status != 0)
    let diagnostics = result.normalizedOutput
    #expect(!diagnostics.isEmpty)
    #expect(
      diagnostics.localizedCaseInsensitiveContains("error")
        || diagnostics.localizedCaseInsensitiveContains("failed")
    )
    #expect(!diagnostics.localizedCaseInsensitiveContains("no such module 'InnoFlow'"))
    #expect(
      diagnostics.localizedCaseInsensitiveContains("binding")
        || diagnostics.contains("BindableProperty")
        || diagnostics.contains("KeyPath")
        || diagnostics.localizedCaseInsensitiveContains("cannot convert")
        || diagnostics.localizedCaseInsensitiveContains("no exact matches")
        || diagnostics.contains("CompileContract.swift")
        || diagnostics.contains("store.binding")
        || diagnostics.contains("\\.count")
        || diagnostics.contains("NonBindableFeature")
        || diagnostics.localizedCaseInsensitiveContains("generic parameter")
    )
  }

  @Test("ScopedStore.binding rejects non-bindable child key paths at compile time")
  func scopedBindingRejectsNonBindableKeyPathAtCompileTime() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlow

      struct ParentFeature: Reducer {
          struct Child: Equatable, Sendable {
              var count = 0
          }

          struct State: Sendable, DefaultInitializable {
              var child = Child()
              init() {}
          }

          enum Action: Sendable {
              case child(ChildAction)

              static let childCasePath = CasePath<Self, ChildAction>(
                  embed: Action.child,
                  extract: { action in
                      guard case .child(let childAction) = action else { return nil }
                      return childAction
                  }
              )
          }

          enum ChildAction: Sendable {
              case setCount(Int)
          }

          func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
              .none
          }
      }

      @MainActor
      func compileContract() {
          let store = Store(reducer: ParentFeature(), initialState: .init())
          let scoped = store.scope(state: \\.child, action: ParentFeature.Action.childCasePath)
          _ = scoped.binding(\\.count, send: { .setCount($0) })
      }
      """

    let result = try typecheckSource(
      source,
      moduleDirectory: moduleDirectory
    )

    #expect(result.status != 0)
    let diagnostics = result.normalizedOutput
    #expect(!diagnostics.isEmpty)
    #expect(
      diagnostics.localizedCaseInsensitiveContains("binding")
        || diagnostics.contains("BindableProperty")
        || diagnostics.localizedCaseInsensitiveContains("no exact matches")
        || diagnostics.localizedCaseInsensitiveContains("cannot convert")
        || diagnostics.contains("\\.count")
        || diagnostics.contains("scoped")
    )
  }

  @Test("Store.binding accepts projected key paths from @BindableField authoring")
  func bindingAcceptsBindableFieldProjectedKeyPath() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlow

      struct BindableFeature: Reducer {
          struct State: Sendable, DefaultInitializable {
              @BindableField var step = 1
              init() {}
          }

          enum Action: Sendable {
              case setStep(Int)
          }

          func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
              .none
          }
      }

      @MainActor
      func compileContract() {
          let store = Store(reducer: BindableFeature(), initialState: .init())
          _ = store.binding(\\.$step, send: { .setStep($0) })
      }
      """

    let result = try typecheckSource(
      source,
      moduleDirectory: moduleDirectory
    )

    #expect(
      result.status == 0,
      "expected @BindableField projected key path to typecheck, got: \(result.normalizedOutput)")
  }

  @Test("Store.binding keeps unlabeled trailing-closure source compatibility")
  func bindingAcceptsUnlabeledTrailingClosureAtCompileTime() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlow

      struct BindableFeature: Reducer {
          struct State: Sendable, DefaultInitializable {
              @BindableField var step = 1
              init() {}
          }

          enum Action: Sendable {
              case setStep(Int)
          }

          func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
              .none
          }
      }

      @MainActor
      func compileContract() {
          let store = Store(reducer: BindableFeature(), initialState: .init())
          _ = store.binding(\\.$step) { .setStep($0) }
      }
      """

    let result = try typecheckSource(source, moduleDirectory: moduleDirectory)

    #expect(
      result.status == 0,
      "expected unlabeled trailing-closure binding call to typecheck, got: \(result.normalizedOutput)"
    )
  }

  @Test("Store.binding keeps parenthesized unlabeled source compatibility")
  func bindingAcceptsParenthesizedUnlabeledCallAtCompileTime() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlow

      struct BindableFeature: Reducer {
          struct State: Sendable, DefaultInitializable {
              @BindableField var step = 1
              init() {}
          }

          enum Action: Sendable {
              case setStep(Int)
          }

          func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
              .none
          }
      }

      @MainActor
      func compileContract() {
          let store = Store(reducer: BindableFeature(), initialState: .init())
          _ = store.binding(\\.$step, { .setStep($0) })
      }
      """

    let result = try typecheckSource(source, moduleDirectory: moduleDirectory)

    #expect(
      result.status == 0,
      "expected parenthesized unlabeled binding call to typecheck, got: \(result.normalizedOutput)"
    )
  }

  @Test("ScopedStore.binding keeps unlabeled trailing-closure source compatibility")
  func scopedBindingAcceptsUnlabeledTrailingClosureAtCompileTime() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlow

      struct ParentFeature: Reducer {
          struct Child: Equatable, Sendable {
              @BindableField var step = 1
          }

          struct State: Sendable, DefaultInitializable {
              var child = Child()
              init() {}
          }

          enum Action: Sendable {
              case child(ChildAction)

              static let childCasePath = CasePath<Self, ChildAction>(
                  embed: Action.child,
                  extract: { action in
                      guard case .child(let childAction) = action else { return nil }
                      return childAction
                  }
              )
          }

          enum ChildAction: Sendable {
              case setStep(Int)
          }

          func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
              .none
          }
      }

      @MainActor
      func compileContract() {
          let store = Store(reducer: ParentFeature(), initialState: .init())
          let scoped = store.scope(state: \\.child, action: ParentFeature.Action.childCasePath)
          _ = scoped.binding(\\.$step) { .setStep($0) }
      }
      """

    let result = try typecheckSource(source, moduleDirectory: moduleDirectory)

    #expect(
      result.status == 0,
      "expected scoped unlabeled trailing-closure binding call to typecheck, got: \(result.normalizedOutput)"
    )
  }

  @Test("ScopedStore.binding keeps parenthesized unlabeled source compatibility")
  func scopedBindingAcceptsParenthesizedUnlabeledCallAtCompileTime() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlow

      struct ParentFeature: Reducer {
          struct Child: Equatable, Sendable {
              @BindableField var step = 1
          }

          struct State: Sendable, DefaultInitializable {
              var child = Child()
              init() {}
          }

          enum Action: Sendable {
              case child(ChildAction)

              static let childCasePath = CasePath<Self, ChildAction>(
                  embed: Action.child,
                  extract: { action in
                      guard case .child(let childAction) = action else { return nil }
                      return childAction
                  }
              )
          }

          enum ChildAction: Sendable {
              case setStep(Int)
          }

          func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
              .none
          }
      }

      @MainActor
      func compileContract() {
          let store = Store(reducer: ParentFeature(), initialState: .init())
          let scoped = store.scope(state: \\.child, action: ParentFeature.Action.childCasePath)
          _ = scoped.binding(\\.$step, { .setStep($0) })
      }
      """

    let result = try typecheckSource(source, moduleDirectory: moduleDirectory)

    #expect(
      result.status == 0,
      "expected scoped parenthesized unlabeled binding call to typecheck, got: \(result.normalizedOutput)"
    )
  }

  @Test("Scope/IfLet/IfCaseLet reject public closure-based action lifting at compile time")
  func reducerCompositionRejectsClosureActionLiftingAtCompileTime() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlow

      struct ChildReducer: Reducer {
          struct State: Equatable, Sendable {}
          enum Action: Sendable { case start }
          func reduce(into state: inout State, action: Action) -> EffectTask<Action> { .none }
      }

      struct ParentReducer: Reducer {
          enum Screen: Equatable, Sendable {
              case child(ChildReducer.State)
              case idle
          }

          struct State: Equatable, Sendable {
              var child = ChildReducer.State()
              var optionalChild: ChildReducer.State? = .init()
              var screen: Screen = .child(.init())
          }

          enum Action: Sendable {
              case child(ChildReducer.Action)
          }

          static let childState = CasePath<State.Screen, ChildReducer.State>(
              embed: State.Screen.child,
              extract: { screen in
                  guard case .child(let state) = screen else { return nil }
                  return state
              }
          )

          var body: some Reducer<State, Action> {
              CombineReducers {
                  Scope(
                      state: \\.child,
                      extractAction: { action in
                          guard case .child(let childAction) = action else { return nil }
                          return childAction
                      },
                      embedAction: Action.child,
                      reducer: ChildReducer()
                  )

                  IfLet(
                      state: \\.optionalChild,
                      extractAction: { action in
                          guard case .child(let childAction) = action else { return nil }
                          return childAction
                      },
                      embedAction: Action.child,
                      reducer: ChildReducer()
                  )

                  IfCaseLet(
                      state: Self.childState,
                      extractAction: { action in
                          guard case .child(let childAction) = action else { return nil }
                          return childAction
                      },
                      embedAction: Action.child,
                      reducer: ChildReducer()
                  )
              }
          }
      }
      """

    let result = try typecheckSource(source, moduleDirectory: moduleDirectory)

    #expect(result.status != 0)
    let diagnostics = result.normalizedOutput
    #expect(!diagnostics.isEmpty)
    #expect(
      diagnostics.localizedCaseInsensitiveContains("no exact matches")
        || diagnostics.localizedCaseInsensitiveContains("extra arguments")
        || diagnostics.localizedCaseInsensitiveContains("incorrect argument labels")
        || diagnostics.contains("extractAction")
        || diagnostics.contains("embedAction")
    )
  }

  @Test("Store.scope rejects public closure-based action lifting at compile time")
  func storeScopeRejectsClosureActionLiftingAtCompileTime() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlow

      struct Todo: Equatable, Identifiable, Sendable {
          let id: UUID
          var title: String
      }

      struct ParentReducer: Reducer {
          struct Child: Equatable, Sendable {}

          struct State: Equatable, Sendable, DefaultInitializable {
              var child = Child()
              var todos = [Todo(id: UUID(), title: "One")]
              init() {}
          }

          enum Action: Sendable {
              case child(ChildAction)
              case todo(id: UUID, action: TodoAction)
          }

          enum ChildAction: Sendable { case start }
          enum TodoAction: Sendable { case rename(String) }

          func reduce(into state: inout State, action: Action) -> EffectTask<Action> { .none }
      }

      @MainActor
      func compileContract() {
          let store = Store(reducer: ParentReducer(), initialState: .init())
          _ = store.scope(state: \\.child, action: { ParentReducer.Action.child($0) })
          _ = store.scope(collection: \\.todos, action: { id, action in ParentReducer.Action.todo(id: id, action: action) })
      }
      """

    let result = try typecheckSource(source, moduleDirectory: moduleDirectory)

    #expect(result.status != 0)
    let diagnostics = result.normalizedOutput
    #expect(!diagnostics.isEmpty)
    #expect(
      diagnostics.localizedCaseInsensitiveContains("no exact matches")
        || diagnostics.localizedCaseInsensitiveContains("cannot convert")
        || diagnostics.contains("scope")
        || diagnostics.contains("action:")
    )
  }

  @Test("TestStore.scope keeps only CasePath-based public scoping APIs")
  func testStoreScopeRejectsClosureActionLiftingAtCompileTime() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = packageRoot.appendingPathComponent("Sources/InnoFlowTesting/TestStore.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    let forbiddenSignatures = [
      """
      public func scope<ChildState: Equatable, ChildAction>(
        state: WritableKeyPath<R.State, ChildState>,
        extractAction:
      """,
      """
      public func scope<CollectionState, ChildAction>(
        collection: WritableKeyPath<R.State, CollectionState>,
        id: CollectionState.Element.ID,
        extractAction:
      """,
    ]

    for signature in forbiddenSignatures {
      #expect(source.contains(signature) == false)
    }
  }

}

// MARK: - Store Tests
