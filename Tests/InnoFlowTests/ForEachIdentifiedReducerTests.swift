// MARK: - ForEachIdentifiedReducerTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import Testing

@testable import InnoFlow
@testable import InnoFlowCore
@testable import InnoFlowTesting

@InnoFlow
struct IdentifiedCollectionFeature {
  struct Row: Equatable, Hashable, Sendable, Identifiable {
    var id: UUID
    var title: String
    var done: Bool = false
  }

  struct State: Equatable, Sendable, DefaultInitializable {
    var rows: IdentifiedArrayOf<Row> = .init(uniqueElements: [
      Row(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, title: "a"),
      Row(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, title: "b"),
      Row(id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!, title: "c"),
    ])
  }

  enum Action: Equatable, Sendable {
    case row(id: UUID, action: RowAction)
  }

  enum RowAction: Equatable, Sendable {
    case toggleDone
  }

  struct RowFeature: Reducer {
    func reduce(into state: inout Row, action: RowAction) -> EffectTask<RowAction> {
      switch action {
      case .toggleDone:
        state.done.toggle()
        return .none
      }
    }
  }

  var body: some Reducer<State, Action> {
    CombineReducers {
      Reduce { _, action in
        switch action {
        case .row:
          return .none
        }
      }
      ForEachIdentifiedReducer(
        state: \.rows,
        action: Action.rowActionPath,
        reducer: RowFeature()
      )
    }
  }
}

@Suite("ForEachIdentifiedReducer")
@MainActor
struct ForEachIdentifiedReducerTests {

  private static let idA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
  private static let idB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
  private static let idMissing = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!

  @Test("routes child action to the addressed element via id lookup")
  func routesByID() async {
    let store = TestStore(reducer: IdentifiedCollectionFeature(), initialState: .init())
    await store.send(.row(id: Self.idB, action: .toggleDone)) {
      $0.rows[id: Self.idB]?.done = true
    }
    await store.assertNoMoreActions()

    #expect(store.state.rows[id: Self.idA]?.done == false)
    #expect(store.state.rows[id: Self.idB]?.done == true)
    #expect(store.state.rows.count == 3)
    #expect(store.state.rows.ids.first == Self.idA)
  }

  @Test("ignores unknown ids without mutating the collection")
  func ignoresUnknownIDs() async {
    let store = TestStore(reducer: IdentifiedCollectionFeature(), initialState: .init())
    await store.send(.row(id: Self.idMissing, action: .toggleDone))
    await store.assertNoMoreActions()

    #expect(store.state.rows.values.map(\.done) == [false, false, false])
  }
}
