// MARK: - CollectionScopeCacheTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Testing

@testable import InnoFlowCore

@Suite("Collection Scope Cache Tests", .serialized)
@MainActor
struct CollectionScopeCacheTests {
  private typealias RowStore =
    ScopedStore<
      CollectionScopeCacheFeature,
      CollectionScopeCacheFeature.Row,
      CollectionScopeCacheFeature.ChildAction
    >

  @Test("Distinct collection action paths never reuse an outdated action transform")
  func separatesDistinctActionPaths() {
    let store = Store(reducer: CollectionScopeCacheFeature(), initialState: .init())
    let callsiteLine: UInt = #line
    let primary = store.scope(
      collection: \.rows,
      action: CollectionScopeCacheFeature.Action.primaryActionPath,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    )
    let secondary = store.scope(
      collection: \.rows,
      action: CollectionScopeCacheFeature.Action.secondaryActionPath,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    )

    #expect(primary[0] !== secondary[0])

    primary[0].send(.increment)
    secondary[0].send(.increment)

    #expect(store.state.rows[0].count == 2)
    #expect(store.state.routes == [.primary, .secondary])
  }

  @Test("A copied collection action path reuses the active row family")
  func copiedActionPathReusesActiveFamily() {
    let store = Store(reducer: CollectionScopeCacheFeature(), initialState: .init())
    let path = CollectionScopeCacheFeature.Action.primaryActionPath
    let copy = path
    let callsiteLine: UInt = #line
    let first = store.scope(
      collection: \.rows,
      action: path,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    )
    let second = store.scope(
      collection: \.rows,
      action: copy,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    )

    #expect(first[0] === second[0])
  }

  @Test("Alternating collection action paths replace only the active row family")
  func alternatingActionPathsReplaceActiveFamily() {
    let store = Store(reducer: CollectionScopeCacheFeature(), initialState: .init())
    let callsiteLine: UInt = #line
    let firstPrimary = store.scope(
      collection: \.rows,
      action: CollectionScopeCacheFeature.Action.primaryActionPath,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    )
    let secondary = store.scope(
      collection: \.rows,
      action: CollectionScopeCacheFeature.Action.secondaryActionPath,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    )
    let secondPrimary = store.scope(
      collection: \.rows,
      action: CollectionScopeCacheFeature.Action.primaryActionPath,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    )

    #expect(firstPrimary[0] !== secondary[0])
    #expect(secondary[0] !== secondPrimary[0])
    #expect(firstPrimary[0] !== secondPrimary[0])

    firstPrimary[0].send(.increment)
    secondary[0].send(.increment)
    secondPrimary[0].send(.increment)

    #expect(store.state.routes == [.primary, .secondary, .primary])
  }

  @Test("A replaced row family applies one action path to existing and appended rows")
  func replacementKeepsOneActionPathForEveryRow() {
    let store = Store(reducer: CollectionScopeCacheFeature(), initialState: .init())
    let callsiteLine: UInt = #line
    _ = store.scope(
      collection: \.rows,
      action: CollectionScopeCacheFeature.Action.primaryActionPath,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    )
    let secondary = store.scope(
      collection: \.rows,
      action: CollectionScopeCacheFeature.Action.secondaryActionPath,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    )

    store.send(.appendRow(id: 1))
    let updatedSecondary = store.scope(
      collection: \.rows,
      action: CollectionScopeCacheFeature.Action.secondaryActionPath,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    )

    #expect(updatedSecondary.count == 2)
    #expect(updatedSecondary[0] === secondary[0])

    updatedSecondary[0].send(.increment)
    updatedSecondary[1].send(.increment)

    #expect(store.state.rows.map(\.count) == [1, 1])
    #expect(store.state.routes == [.secondary, .secondary])
  }

  @Test("Replacing the active signature releases its cached rows and identity")
  func replacementReleasesCachedFamily() {
    let store = Store(reducer: CollectionScopeCacheFeature(), initialState: .init())
    let callsiteLine: UInt = #line
    var path:
      CollectionActionPath<
        CollectionScopeCacheFeature.Action,
        Int,
        CollectionScopeCacheFeature.ChildAction
      >? = CollectionScopeCacheFeature.Action.makePrimaryActionPath()
    weak let weakIdentity = path?.identity
    weak var weakRow: RowStore?

    do {
      let rows = store.scope(
        collection: \.rows,
        action: path!,
        fileID: #fileID,
        line: callsiteLine,
        column: 0
      )
      weakRow = rows[0]
    }

    path = nil
    #expect(weakIdentity != nil)
    #expect(weakRow != nil)

    _ = store.scope(
      collection: \.rows,
      action: CollectionScopeCacheFeature.Action.secondaryActionPath,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    )

    #expect(weakIdentity == nil)
    #expect(weakRow == nil)
  }

  @Test("A stored collection action path shares its row family across call sites")
  func storedPathSharesFamilyAcrossCallsites() {
    let store = Store(reducer: CollectionScopeCacheFeature(), initialState: .init())
    let first = store.scope(
      collection: \.rows,
      action: CollectionScopeCacheFeature.Action.primaryActionPath,
      fileID: #fileID,
      line: 100,
      column: 0
    )
    let second = store.scope(
      collection: \.rows,
      action: CollectionScopeCacheFeature.Action.primaryActionPath,
      fileID: #fileID,
      line: 101,
      column: 0
    )
    let firstAgain = store.scope(
      collection: \.rows,
      action: CollectionScopeCacheFeature.Action.primaryActionPath,
      fileID: #fileID,
      line: 100,
      column: 0
    )

    #expect(first[0] === second[0])
    #expect(second[0] === firstAgain[0])

    first[0].send(.increment)
    second[0].send(.increment)
    firstAgain[0].send(.increment)

    #expect(store.state.routes == [.primary, .primary, .primary])
  }

  @Test("Rows from a replaced family still resolve state by stable id")
  func replacedRowsKeepStableIDFallback() {
    let store = Store(reducer: CollectionScopeCacheFeature(), initialState: .init())
    let callsiteLine: UInt = #line
    let primary = store.scope(
      collection: \.rows,
      action: CollectionScopeCacheFeature.Action.primaryActionPath,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    )
    _ = store.scope(
      collection: \.rows,
      action: CollectionScopeCacheFeature.Action.secondaryActionPath,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    )

    store.send(.appendRow(id: 1))
    store.send(.reverseRows)

    #expect(store.state.rows.map(\.id) == [1, 0])
    #expect(primary[0].id == 0)
    #expect(primary[0].count == 0)

    primary[0].send(.increment)

    #expect(store.state.rows[1].id == 0)
    #expect(store.state.rows[1].count == 1)
    #expect(store.state.routes == [.primary])
  }

  @Test("A reinserted id replaces its inactive cached row")
  func reinsertedIDReplacesInactiveRow() {
    let store = Store(reducer: CollectionScopeCacheFeature(), initialState: .init())
    let callsiteLine: UInt = #line
    let initial = store.scope(
      collection: \.rows,
      action: CollectionScopeCacheFeature.Action.primaryActionPath,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    )
    let removedRow = initial[0]

    store.send(.removeRow(id: 0))
    #expect(removedRow.isAlive == false)

    store.send(.appendRow(id: 0))
    let reinserted = store.scope(
      collection: \.rows,
      action: CollectionScopeCacheFeature.Action.primaryActionPath,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    )

    #expect(reinserted.count == 1)
    #expect(reinserted[0] !== removedRow)
    #expect(reinserted[0].isAlive)

    reinserted[0].send(.increment)

    #expect(store.state.rows[0].count == 1)
    #expect(store.state.routes == [.primary])
  }
}

private struct CollectionScopeCacheFeature: Reducer {
  struct Row: Equatable, Identifiable, Sendable {
    let id: Int
    var count = 0
  }

  struct State: Equatable, Sendable {
    var rows = [Row(id: 0)]
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
    case primary(id: Int, action: ChildAction)
    case secondary(id: Int, action: ChildAction)
    case appendRow(id: Int)
    case removeRow(id: Int)
    case reverseRows

    static let primaryActionPath = makePrimaryActionPath()

    static let secondaryActionPath = CollectionActionPath<Self, Int, ChildAction>(
      embed: Action.secondary,
      extract: { action in
        guard case .secondary(let id, let childAction) = action else { return nil }
        return (id, childAction)
      }
    )

    static func makePrimaryActionPath() -> CollectionActionPath<Self, Int, ChildAction> {
      CollectionActionPath(
        embed: Action.primary,
        extract: { action in
          guard case .primary(let id, let childAction) = action else { return nil }
          return (id, childAction)
        }
      )
    }
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .primary(let id, .increment):
      guard let index = state.rows.firstIndex(where: { $0.id == id }) else { return .none }
      state.rows[index].count += 1
      state.routes.append(.primary)
      return .none

    case .secondary(let id, .increment):
      guard let index = state.rows.firstIndex(where: { $0.id == id }) else { return .none }
      state.rows[index].count += 1
      state.routes.append(.secondary)
      return .none

    case .appendRow(let id):
      state.rows.append(.init(id: id))
      return .none

    case .removeRow(let id):
      state.rows.removeAll(where: { $0.id == id })
      return .none

    case .reverseRows:
      state.rows.reverse()
      return .none
    }
  }
}
