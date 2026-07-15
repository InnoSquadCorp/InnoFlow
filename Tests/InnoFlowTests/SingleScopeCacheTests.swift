// MARK: - SingleScopeCacheTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Testing

@testable import InnoFlowCore

@Suite("Single Scope Cache Tests", .serialized)
@MainActor
struct SingleScopeCacheTests {
  private typealias ChildStore =
    ScopedStore<
      SingleScopeCacheFeature, SingleScopeCacheFeature.Child, SingleScopeCacheFeature.ChildAction
    >

  @Test("Repeated single-state scope calls reuse one live projection")
  func reusesLiveScopeFromDefaultCallsite() {
    let store = makeStore()
    let first = scopeFromStableCallsite(store)
    let second = scopeFromStableCallsite(store)

    #expect(first === second)
    #expect(store.projectionObserverStats.registeredObservers == 1)

    let before = store.projectionObserverStats
    first.send(.increment)
    let after = store.projectionObserverStats

    #expect(first.count == 1)
    #expect(after.evaluatedObservers == before.evaluatedObservers + 1)
    #expect(after.refreshedObservers == before.refreshedObservers + 1)
  }

  @Test("Every single-state scope identity dimension separates projections")
  func separatesEveryIdentityDimension() {
    let store = makeStore()
    let line: UInt = 100
    let first = store.scope(
      state: \.child,
      action: SingleScopeCacheFeature.Action.primaryCasePath,
      fileID: #fileID,
      line: line,
      column: 0
    )
    let differentCallsite = store.scope(
      state: \.child,
      action: SingleScopeCacheFeature.Action.primaryCasePath,
      fileID: #fileID,
      line: line,
      column: 1
    )
    let differentStateKeyPath = store.scope(
      state: \.alternate,
      action: SingleScopeCacheFeature.Action.primaryCasePath,
      fileID: #fileID,
      line: line,
      column: 0
    )
    let differentActionPath = store.scope(
      state: \.child,
      action: SingleScopeCacheFeature.Action.makePrimaryCasePath(),
      fileID: #fileID,
      line: line,
      column: 0
    )

    #expect(first !== differentCallsite)
    #expect(first !== differentStateKeyPath)
    #expect(first !== differentActionPath)
  }

  @Test("Alternating action paths preserve every live projection identity")
  func preservesAlternatingActionPaths() {
    let store = makeStore()
    let line: UInt = 200
    let primary = store.scope(
      state: \.child,
      action: SingleScopeCacheFeature.Action.primaryCasePath,
      fileID: #fileID,
      line: line,
      column: 0
    )
    let secondary = store.scope(
      state: \.child,
      action: SingleScopeCacheFeature.Action.secondaryCasePath,
      fileID: #fileID,
      line: line,
      column: 0
    )
    let primaryAgain = store.scope(
      state: \.child,
      action: SingleScopeCacheFeature.Action.primaryCasePath,
      fileID: #fileID,
      line: line,
      column: 0
    )
    let secondaryAgain = store.scope(
      state: \.child,
      action: SingleScopeCacheFeature.Action.secondaryCasePath,
      fileID: #fileID,
      line: line,
      column: 0
    )

    #expect(primaryAgain === primary)
    #expect(secondaryAgain === secondary)

    primary.send(.increment)
    secondary.send(.increment)
    primaryAgain.send(.increment)
    secondaryAgain.send(.increment)

    #expect(store.state.child.count == 4)
    #expect(store.state.routes == [.primary, .secondary, .primary, .secondary])
    #expect(store.projectionObserverStats.registeredObservers == 2)
  }

  @Test("A released projection is recreated from current state")
  func releasesAndRecreatesFromCurrentState() {
    let store = makeStore()
    let line: UInt = 300
    weak var weakScope: ChildStore?

    do {
      let scope = store.scope(
        state: \.child,
        action: SingleScopeCacheFeature.Action.primaryCasePath,
        fileID: #fileID,
        line: line,
        column: 0
      )
      weakScope = scope
      #expect(scope.count == 0)
    }

    #expect(weakScope == nil)

    store.send(.primary(.increment))
    #expect(store.projectionObserverStats.registeredObservers == 0)

    let recreated = store.scope(
      state: \.child,
      action: SingleScopeCacheFeature.Action.primaryCasePath,
      fileID: #fileID,
      line: line,
      column: 0
    )

    #expect(recreated.count == 1)
    #expect(store.projectionObserverStats.registeredObservers == 1)
  }

  @Test("A selected value does not pin a weakly cached scope")
  func selectedValueDoesNotPinWeaklyCachedScope() {
    let store = makeStore()
    let scopeLine: UInt = 400
    let selectionLine: UInt = 401
    var scope: ChildStore? = store.scope(
      state: \.child,
      action: SingleScopeCacheFeature.Action.primaryCasePath,
      fileID: #fileID,
      line: scopeLine,
      column: 0
    )
    let selected = scope!.select(
      \.count,
      fileID: #fileID,
      line: selectionLine,
      column: 0
    )
    let selectedAgain = scope!.select(
      \.count,
      fileID: #fileID,
      line: selectionLine,
      column: 0
    )
    weak let weakScope = scope

    #expect(selectedAgain === selected)
    scope = nil

    #expect(weakScope == nil)
    #expect(selected.isAlive == false)
    #expect(selected.optionalValue == nil)

    store.send(.primary(.increment))
    let recreatedScope = store.scope(
      state: \.child,
      action: SingleScopeCacheFeature.Action.primaryCasePath,
      fileID: #fileID,
      line: scopeLine,
      column: 0
    )
    let recreatedSelected = recreatedScope.select(
      \.count,
      fileID: #fileID,
      line: selectionLine,
      column: 0
    )

    #expect(recreatedSelected !== selected)
    #expect(recreatedSelected.isAlive == true)
    #expect(recreatedSelected.requireAlive() == 1)
  }

  @Test("Dead computed-path entries release their retained identity token")
  func prunesDeadComputedPathIdentityTokens() {
    let store = makeStore()
    let line: UInt = 500
    var path: CasePath<SingleScopeCacheFeature.Action, SingleScopeCacheFeature.ChildAction>? =
      SingleScopeCacheFeature.Action.makePrimaryCasePath()
    weak let weakIdentity = path?.identity
    var scope: ChildStore? = store.scope(
      state: \.child,
      action: path!,
      fileID: #fileID,
      line: line,
      column: 0
    )

    #expect(scope?.count == 0)
    path = nil
    #expect(weakIdentity != nil)

    scope = nil
    let replacementPath = SingleScopeCacheFeature.Action.makePrimaryCasePath()
    let replacementScope = store.scope(
      state: \.child,
      action: replacementPath,
      fileID: #fileID,
      line: line,
      column: 0
    )

    #expect(weakIdentity == nil)
    #expect(replacementScope.count == 0)
  }

  @Test("Periodic maintenance prunes dead entries from other signatures")
  func periodicallyPrunesDeadEntriesFromOtherSignatures() {
    let store = makeStore()
    var firstPath:
      CasePath<
        SingleScopeCacheFeature.Action,
        SingleScopeCacheFeature.ChildAction
      >? = SingleScopeCacheFeature.Action.makePrimaryCasePath()
    weak let firstIdentity = firstPath?.identity
    weak var firstScope: ChildStore?

    do {
      let scope = store.scope(
        state: \.child,
        action: firstPath!,
        fileID: #fileID,
        line: 0,
        column: 0
      )
      firstScope = scope
    }

    firstPath = nil
    #expect(firstScope == nil)
    #expect(firstIdentity != nil)

    for index in 1..<64 {
      weak var weakScope: ChildStore?
      do {
        let path = SingleScopeCacheFeature.Action.makePrimaryCasePath()
        let scope = store.scope(
          state: \.child,
          action: path,
          fileID: #fileID,
          line: UInt(index),
          column: 0
        )
        weakScope = scope
      }
      #expect(weakScope == nil)
    }

    #expect(firstIdentity == nil)
  }

  @Test("Action-path identity hashing follows reference identity")
  func actionPathIdentityHashing() {
    let first = SingleScopeCacheFeature.Action.makePrimaryCasePath()
    let firstCopy = first
    let second = SingleScopeCacheFeature.Action.makePrimaryCasePath()

    #expect(Set([first.identity, firstCopy.identity]).count == 1)
    #expect(Set([first.identity, second.identity]).count == 2)
  }

  private func makeStore() -> Store<SingleScopeCacheFeature> {
    Store(reducer: SingleScopeCacheFeature(), initialState: .init())
  }

  private func scopeFromStableCallsite(
    _ store: Store<SingleScopeCacheFeature>
  ) -> ChildStore {
    store.scope(
      state: \.child,
      action: SingleScopeCacheFeature.Action.primaryCasePath
    )
  }
}

private struct SingleScopeCacheFeature: Reducer {
  struct Child: Equatable, Sendable {
    var count = 0
  }

  struct State: Equatable, Sendable {
    var child = Child()
    var alternate = Child()
    var routes: [Route] = []
  }

  enum Route: Equatable, Sendable {
    case primary
    case secondary
  }

  enum ChildAction: Equatable, Sendable {
    case increment
  }

  enum Action: Equatable, Sendable {
    case primary(ChildAction)
    case secondary(ChildAction)

    static let primaryCasePath = makePrimaryCasePath()

    static let secondaryCasePath = CasePath<Self, ChildAction>(
      embed: Action.secondary,
      extract: { action in
        guard case .secondary(let childAction) = action else { return nil }
        return childAction
      }
    )

    static func makePrimaryCasePath() -> CasePath<Self, ChildAction> {
      CasePath(
        embed: Action.primary,
        extract: { action in
          guard case .primary(let childAction) = action else { return nil }
          return childAction
        }
      )
    }
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .primary(.increment):
      state.child.count += 1
      state.routes.append(.primary)
      return .none

    case .secondary(.increment):
      state.child.count += 1
      state.routes.append(.secondary)
      return .none
    }
  }
}
