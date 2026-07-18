// MARK: - ReducerCompositionTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import InnoFlowCore
import InnoFlowTesting
import Testing

/// Direct behavioral coverage for the composition primitives.
///
/// These tests pin the documented semantics — declaration-order cumulative
/// mutation, effect merging, action routing, and the missing-child policies —
/// at the reducer level, independent of any specific feature fixture.
@Suite("Reducer Composition")
struct ReducerCompositionTests {

  // MARK: - Fixtures

  struct ChildFeature: Reducer {
    struct State: Equatable, Sendable, Identifiable {
      var id: Int = 0
      var value: Int = 0
    }

    enum Action: Equatable, Sendable {
      case add(Int)
      case addThenFollowUp(Int)
      case followUp
    }

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
      switch action {
      case .add(let amount):
        state.value += amount
        return .none
      case .addThenFollowUp(let amount):
        state.value += amount
        return .send(.followUp)
      case .followUp:
        state.value += 1000
        return .none
      }
    }
  }

  struct ParentState: Equatable, Sendable, DefaultInitializable {
    var child = ChildFeature.State()
    var optionalChild: ChildFeature.State?
    var log: [String] = []
  }

  enum ParentAction: Equatable, Sendable {
    case child(ChildFeature.Action)
    case optionalChild(ChildFeature.Action)
    case unrelated
  }

  static let childCasePath = CasePath<ParentAction, ChildFeature.Action>(
    embed: ParentAction.child,
    extract: { action in
      guard case .child(let childAction) = action else { return nil }
      return childAction
    }
  )

  static let optionalChildCasePath = CasePath<ParentAction, ChildFeature.Action>(
    embed: ParentAction.optionalChild,
    extract: { action in
      guard case .optionalChild(let childAction) = action else { return nil }
      return childAction
    }
  )

  // MARK: - CombineReducers / ReducerBuilder

  @Test("CombineReducers runs children in declaration order on the same state")
  func combineReducersCumulativeMutation() {
    let reducer = CombineReducers<ChildFeature.State, ChildFeature.Action> {
      Reduce { state, action in
        if case .add(let amount) = action {
          state.value += amount
        }
        return .none
      }
      Reduce { state, _ in
        // Observes the mutation of the previous sibling: cumulative, not
        // isolated snapshots.
        state.value *= 10
        return .none
      }
    }

    var state = ChildFeature.State()
    let effect = reducer.reduce(into: &state, action: .add(3))
    #expect(state.value == 30)
    #expect(effect.isNone)
  }

  @Test("ReducerBuilder merges effects from every child in declaration order")
  @MainActor
  func builderMergesChildEffects() async {
    struct MergingFeature: Reducer {
      typealias State = ParentState
      typealias Action = ParentAction

      func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
        CombineReducers<State, Action> {
          Reduce { state, action in
            guard case .unrelated = action else { return .none }
            state.log.append("first")
            return .send(.child(.add(1)))
          }
          Reduce { state, action in
            guard case .unrelated = action else { return .none }
            state.log.append("second")
            return .send(.optionalChild(.add(2)))
          }
          Reduce { state, action in
            if case .child(let childAction) = action {
              _ = ChildFeature().reduce(into: &state.child, action: childAction)
            }
            if case .optionalChild(.add(let amount)) = action {
              state.log.append("optional+\(amount)")
            }
            return .none
          }
        }
        .reduce(into: &state, action: action)
      }
    }

    let store = TestStore(reducer: MergingFeature())

    await store.send(.unrelated) {
      $0.log = ["first", "second"]
    }
    await store.receive(.child(.add(1))) {
      $0.child.value = 1
    }
    await store.receive(.optionalChild(.add(2))) {
      $0.log = ["first", "second", "optional+2"]
    }
    await store.finish()
  }

  @Test("ReducerBuilder buildEither evaluates only the selected branch")
  func builderEitherBranches() {
    func makeReducer(flag: Bool) -> CombineReducers<ChildFeature.State, ChildFeature.Action> {
      CombineReducers {
        if flag {
          Reduce<ChildFeature.State, ChildFeature.Action> { state, _ in
            state.value += 1
            return .none
          }
        } else {
          Reduce<ChildFeature.State, ChildFeature.Action> { state, _ in
            state.value += 100
            return .none
          }
        }
      }
    }

    var state = ChildFeature.State()
    _ = makeReducer(flag: true).reduce(into: &state, action: .followUp)
    #expect(state.value == 1)

    _ = makeReducer(flag: false).reduce(into: &state, action: .followUp)
    #expect(state.value == 101)
  }

  @Test("ReducerBuilder buildOptional treats an absent branch as a no-op")
  func builderOptionalNil() {
    func makeReducer(enabled: Bool) -> CombineReducers<ChildFeature.State, ChildFeature.Action> {
      CombineReducers {
        if enabled {
          Reduce<ChildFeature.State, ChildFeature.Action> { state, _ in
            state.value += 1
            return .none
          }
        }
      }
    }

    var state = ChildFeature.State()
    let effect = makeReducer(enabled: false).reduce(into: &state, action: .add(5))
    #expect(state == ChildFeature.State())
    #expect(effect.isNone)

    _ = makeReducer(enabled: true).reduce(into: &state, action: .add(5))
    #expect(state.value == 1)
  }

  // MARK: - Scope

  @Test("Scope routes matching actions into child state and ignores the rest")
  func scopeRoutesMatchingActions() {
    let scope = Scope(
      state: \ParentState.child,
      action: Self.childCasePath,
      reducer: ChildFeature()
    )

    var state = ParentState()
    let matched = scope.reduce(into: &state, action: .child(.add(7)))
    #expect(state.child.value == 7)
    #expect(matched.isNone)

    let unmatched = scope.reduce(into: &state, action: .unrelated)
    #expect(state.child.value == 7)
    #expect(unmatched.isNone)
  }

  @Test("Scope lifts child follow-up effects back into the parent action space")
  @MainActor
  func scopeLiftsChildEffects() async {
    struct ScopedFeature: Reducer {
      typealias State = ParentState
      typealias Action = ParentAction

      func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
        Scope(
          state: \State.child,
          action: ReducerCompositionTests.childCasePath,
          reducer: ChildFeature()
        )
        .reduce(into: &state, action: action)
      }
    }

    let store = TestStore(reducer: ScopedFeature())

    await store.send(.child(.addThenFollowUp(5))) {
      $0.child.value = 5
    }
    await store.receive(.child(.followUp)) {
      $0.child.value = 1005
    }
    await store.finish()
  }

  // MARK: - IfLet / IfCaseLet

  @Test("IfLet runs the child while state is present and writes it back")
  func ifLetRunsWhilePresent() {
    let ifLet = IfLet(
      state: \ParentState.optionalChild,
      action: Self.optionalChildCasePath,
      reducer: ChildFeature(),
      onMissing: .ignore
    )

    var state = ParentState()
    state.optionalChild = ChildFeature.State()

    _ = ifLet.reduce(into: &state, action: .optionalChild(.add(9)))
    #expect(state.optionalChild?.value == 9)
  }

  @Test("IfLet with .ignore drops child actions arriving while state is nil")
  func ifLetIgnorePolicyDropsWhileNil() {
    let ifLet = IfLet(
      state: \ParentState.optionalChild,
      action: Self.optionalChildCasePath,
      reducer: ChildFeature(),
      onMissing: .ignore
    )

    var state = ParentState()
    let effect = ifLet.reduce(into: &state, action: .optionalChild(.add(9)))
    #expect(state.optionalChild == nil)
    #expect(effect.isNone)
  }

  enum EnumParentState: Equatable, Sendable {
    case active(ChildFeature.State)
    case inactive
  }

  static let activeCasePath = CasePath<EnumParentState, ChildFeature.State>(
    embed: EnumParentState.active,
    extract: { state in
      guard case .active(let child) = state else { return nil }
      return child
    }
  )

  @Test("IfCaseLet runs the child while the parent case matches")
  func ifCaseLetRunsWhileMatching() {
    let ifCaseLet = IfCaseLet(
      state: Self.activeCasePath,
      action: Self.childCasePath,
      reducer: ChildFeature(),
      onMissing: .ignore
    )

    var state = EnumParentState.active(ChildFeature.State())
    _ = ifCaseLet.reduce(into: &state, action: .child(.add(4)))
    #expect(state == .active(ChildFeature.State(id: 0, value: 4)))
  }

  @Test("IfCaseLet with .ignore drops child actions in a different case")
  func ifCaseLetIgnorePolicyDropsOtherCase() {
    let ifCaseLet = IfCaseLet(
      state: Self.activeCasePath,
      action: Self.childCasePath,
      reducer: ChildFeature(),
      onMissing: .ignore
    )

    var state = EnumParentState.inactive
    let effect = ifCaseLet.reduce(into: &state, action: .child(.add(4)))
    #expect(state == .inactive)
    #expect(effect.isNone)
  }

  // MARK: - ForEachReducer / ForEachIdentifiedReducer

  struct RowsState: Equatable, Sendable {
    var rows: [ChildFeature.State] = []
    var identifiedRows = IdentifiedArrayOf<ChildFeature.State>()
  }

  enum RowsAction: Equatable, Sendable {
    case row(id: Int, action: ChildFeature.Action)
  }

  static let rowActionPath = CollectionActionPath<RowsAction, Int, ChildFeature.Action>(
    embed: RowsAction.row,
    extract: { action in
      guard case .row(let id, let childAction) = action else { return nil }
      return (id, childAction)
    }
  )

  @Test("ForEachReducer routes by element id and skips missing ids")
  func forEachRoutesByID() {
    let forEach = ForEachReducer(
      state: \RowsState.rows,
      action: Self.rowActionPath,
      reducer: ChildFeature()
    )

    var state = RowsState()
    state.rows = [
      ChildFeature.State(id: 1, value: 0),
      ChildFeature.State(id: 2, value: 0),
    ]

    _ = forEach.reduce(into: &state, action: .row(id: 2, action: .add(8)))
    #expect(state.rows[0].value == 0)
    #expect(state.rows[1].value == 8)

    let missing = forEach.reduce(into: &state, action: .row(id: 99, action: .add(8)))
    #expect(missing.isNone)
    #expect(state.rows.map(\.value) == [0, 8])
  }

  @Test("ForEachIdentifiedReducer routes through the id map and embeds follow-ups")
  @MainActor
  func forEachIdentifiedRoutesAndEmbeds() async {
    struct RowsFeature: Reducer {
      struct State: Equatable, Sendable, DefaultInitializable {
        var identifiedRows = IdentifiedArrayOf<ChildFeature.State>(uniqueElements: [
          ChildFeature.State(id: 1, value: 0),
          ChildFeature.State(id: 2, value: 0),
        ])
      }
      typealias Action = RowsAction

      func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
        ForEachIdentifiedReducer(
          state: \State.identifiedRows,
          action: ReducerCompositionTests.rowActionPath,
          reducer: ChildFeature()
        )
        .reduce(into: &state, action: action)
      }
    }

    let store = TestStore(reducer: RowsFeature())

    await store.send(.row(id: 2, action: .addThenFollowUp(6))) {
      $0.identifiedRows[id: 2]?.value = 6
    }
    // The follow-up must come back embedded with the originating row id.
    await store.receive(.row(id: 2, action: .followUp)) {
      $0.identifiedRows[id: 2]?.value = 1006
    }
    await store.finish()
  }
}
