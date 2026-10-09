// MARK: - IdentifiedArrayTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import Testing

@testable import InnoFlowCore

@Suite("IdentifiedArray")
struct IdentifiedArrayTests {

  private struct Row: Identifiable, Hashable, Sendable {
    var id: Int
    var title: String
  }

  private struct ProjectedRow: Hashable, Sendable {
    var primary: Int
    var alternate: Int
    var title: String
  }

  // Core-only fixture: the regression exercises runtime identity, not macros.
  private struct IdentityFeature: Reducer {
    struct State: Equatable, Sendable {
      var rows: IdentifiedArray<Int, ProjectedRow>
      var revision = 0
    }
    enum Action: Sendable {
      case replace(IdentifiedArray<Int, ProjectedRow>)
    }
    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
      switch action {
      case .replace(let rows): state.rows = rows
      }
      return .none
    }
  }

  @Test("Equal element values with different identities remain distinct collection keys")
  func equalityIncludesCustomIdentity() {
    let rows = [ProjectedRow(primary: 1, alternate: 101, title: "same")]
    let primary = IdentifiedArray(uniqueElements: rows, id: { $0.primary })
    let alternate = IdentifiedArray(uniqueElements: rows, id: { $0.alternate })

    #expect(primary.values == alternate.values)
    #expect(primary[id: 101] == nil)
    #expect(alternate[id: 101] == rows[0])
    #expect(primary != alternate)
    #expect(Set([primary, alternate]).count == 2)
    var labels = [primary: "primary"]
    labels[alternate] = "alternate"
    #expect(labels[primary] == "primary")
    #expect(labels[alternate] == "alternate")
  }

  @Test("Identity equality includes positions, not just the set of IDs")
  func equalityIncludesIdentityPositions() {
    let rows = [
      ProjectedRow(primary: 1, alternate: 2, title: "a"),
      ProjectedRow(primary: 2, alternate: 1, title: "b"),
    ]
    let primary = IdentifiedArray(uniqueElements: rows, id: { $0.primary })
    let alternate = IdentifiedArray(uniqueElements: rows, id: { $0.alternate })

    #expect(Set(primary.ids) == Set(alternate.ids))
    #expect(primary.values == alternate.values)
    #expect(primary[id: 1]?.title == "a")
    #expect(alternate[id: 1]?.title == "b")
    #expect(primary != alternate)
  }

  @Test("Equivalent projections and mutation histories preserve equality and hashing")
  func equivalentIdentityProjectionsAndMutations() {
    let rows = [
      ProjectedRow(primary: 1, alternate: 1, title: "a"),
      ProjectedRow(primary: 2, alternate: 2, title: "b"),
    ]
    let original = IdentifiedArray(uniqueElements: rows, id: { $0.primary })
    var rebuilt = IdentifiedArray(uniqueElements: rows.reversed(), id: { $0.alternate })
    rebuilt.remove(id: 1)
    rebuilt.insert(rows[0], at: 0)
    #expect(original == rebuilt)
    #expect(original.hashValue == rebuilt.hashValue)
    #expect(Set([original, rebuilt]).count == 1)

    rebuilt[id: 1]?.title = "changed"
    #expect(original != rebuilt)
    #expect(original[id: 1]?.title == "a")
    rebuilt.removeAll()
    let empty = IdentifiedArray<Int, ProjectedRow>(id: { $0.primary })
    #expect(rebuilt == empty)
    #expect(rebuilt.hashValue == empty.hashValue)
  }

  @Test("ID-only replacement refreshes root and scoped selections")
  @MainActor
  func identityReplacementRefreshesSelections() {
    let rows = [ProjectedRow(primary: 1, alternate: 101, title: "same")]
    let original = IdentifiedArray(uniqueElements: rows, id: { $0.primary })
    let replacement = IdentifiedArray(uniqueElements: rows, id: { $0.alternate })
    let store = Store(reducer: IdentityFeature(), initialState: .init(rows: original))
    let scoped = store.scope(
      state: \.self,
      action: CasePath<IdentityFeature.Action, IdentityFeature.Action>(
        embed: { $0 }, extract: { $0 })
    )
    let keyPath = store.select(\.rows)
    let scopedKeyPath = scoped.select(\.rows)
    let selections = [
      store.select { $0.rows.ids },
      store.select(memoize: true) { $0.rows.ids },
      store.select(dependingOn: \.rows) { $0.ids },
      store.select(dependingOnAll: \.rows, \.revision) { rows, _ in rows.ids },
      scoped.select { $0.rows.ids },
      scoped.select(memoize: true) { $0.rows.ids },
      scoped.select(dependingOn: \.rows) { $0.ids },
      scoped.select(dependingOnAll: \.rows, \.revision) { rows, _ in rows.ids },
    ]
    for selection in selections { #expect(selection.requireAlive() == [1]) }

    // Also exercise a normal value change and restoration of the original IDs.
    let changed = IdentifiedArray(
      uniqueElements: [ProjectedRow(primary: 2, alternate: 102, title: "changed")],
      id: { $0.primary })
    for next in [replacement, changed, original, original] {
      scoped.send(.replace(next))
      #expect(store.state.rows.ids == next.ids)
      #expect(scoped.requireAlive().rows.ids == next.ids)
      #expect(keyPath.requireAlive().ids == next.ids)
      #expect(scopedKeyPath.requireAlive().ids == next.ids)
      for selection in selections { #expect(selection.requireAlive() == next.ids) }
    }
  }

  @Test("uniqueElements preserves insertion order and rejects duplicates in debug")
  func uniqueElementsOrderAndDuplicates() {
    let array = IdentifiedArrayOf<Row>(uniqueElements: [
      Row(id: 1, title: "a"),
      Row(id: 2, title: "b"),
      Row(id: 3, title: "c"),
    ])

    #expect(array.count == 3)
    #expect(array.ids == [1, 2, 3])
    #expect(array.values.map(\.title) == ["a", "b", "c"])
  }

  @Test("subscript(id:) reads and writes are O(1) lookups")
  func subscriptByID() {
    var array = IdentifiedArrayOf<Row>(uniqueElements: [
      Row(id: 1, title: "a"),
      Row(id: 2, title: "b"),
    ])

    #expect(array[id: 1] == Row(id: 1, title: "a"))
    array[id: 1] = Row(id: 1, title: "A")
    #expect(array[id: 1]?.title == "A")
    #expect(array[id: 99] == nil)
  }

  @Test("subscript(id:) = nil removes and shifts indices")
  func subscriptRemoveByID() {
    var array = IdentifiedArrayOf<Row>(uniqueElements: [
      Row(id: 1, title: "a"),
      Row(id: 2, title: "b"),
      Row(id: 3, title: "c"),
    ])

    array[id: 2] = nil

    #expect(array.ids == [1, 3])
    #expect(array[id: 3]?.title == "c")
  }

  // Note: duplicate-id rejection is a debug `assertionFailure` (programmer
  // error contract), exercised in release-mode subprocess harnesses rather
  // than the in-process debug test suite, which would crash on the same
  // assertion. The non-asserting paths (single append, mixed updateOrAppend)
  // remain covered here.

  @Test("insert(_:at:) preserves order and refreshes id->index map")
  func insertAt() {
    var array = IdentifiedArrayOf<Row>(uniqueElements: [
      Row(id: 1, title: "a"),
      Row(id: 3, title: "c"),
    ])
    let inserted = array.insert(Row(id: 2, title: "b"), at: 1)
    #expect(inserted)
    #expect(array.ids == [1, 2, 3])
    #expect(array[id: 3]?.title == "c")
  }

  @Test("insert before/after positions relative to existing id")
  func insertBeforeAndAfter() {
    var array = IdentifiedArrayOf<Row>(uniqueElements: [
      Row(id: 1, title: "a"),
      Row(id: 3, title: "c"),
    ])
    let insertedBefore = array.insert(Row(id: 0, title: "before"), before: 1)
    let insertedAfter = array.insert(Row(id: 2, title: "b"), after: 1)
    #expect(insertedBefore)
    #expect(insertedAfter)
    #expect(array.ids == [0, 1, 2, 3])
  }

  @Test("remove(id:) returns removed element and updates index")
  func removeByID() {
    var array = IdentifiedArrayOf<Row>(uniqueElements: [
      Row(id: 1, title: "a"),
      Row(id: 2, title: "b"),
      Row(id: 3, title: "c"),
    ])
    let removed = array.remove(id: 2)
    #expect(removed == Row(id: 2, title: "b"))
    #expect(array.ids == [1, 3])
    #expect(array[id: 3] != nil)
    #expect(array.remove(id: 999) == nil)
  }

  @Test("updateOrAppend mutates in place when id exists, otherwise appends")
  func updateOrAppendSemantics() {
    var array = IdentifiedArrayOf<Row>(uniqueElements: [
      Row(id: 1, title: "a")
    ])

    let updated = array.updateOrAppend(Row(id: 1, title: "A"))
    #expect(updated)
    #expect(array[id: 1]?.title == "A")
    #expect(array.count == 1)

    let appended = array.updateOrAppend(Row(id: 2, title: "b"))
    #expect(appended == false)
    #expect(array.count == 2)
    #expect(array.ids == [1, 2])
  }

  @Test("RandomAccessCollection conformance iterates in insertion order")
  func collectionIteration() {
    let array = IdentifiedArrayOf<Row>(uniqueElements: [
      Row(id: 10, title: "x"),
      Row(id: 20, title: "y"),
    ])

    var seen: [Int] = []
    for row in array {
      seen.append(row.id)
    }
    #expect(seen == [10, 20])
    #expect(array.first?.id == 10)
    #expect(array.last?.id == 20)
  }

  @Test("Equatable and Hashable compare element sequence by order")
  func equatableHashable() {
    let a = IdentifiedArrayOf<Row>(uniqueElements: [
      Row(id: 1, title: "a"),
      Row(id: 2, title: "b"),
    ])
    let b = IdentifiedArrayOf<Row>(uniqueElements: [
      Row(id: 1, title: "a"),
      Row(id: 2, title: "b"),
    ])
    let c = IdentifiedArrayOf<Row>(uniqueElements: [
      Row(id: 2, title: "b"),
      Row(id: 1, title: "a"),
    ])
    #expect(a == b)
    #expect(a != c)
    #expect(a.hashValue == b.hashValue)
  }

  @Test("contains(id:) is constant time")
  func containsByID() {
    let array = IdentifiedArrayOf<Row>(uniqueElements: [
      Row(id: 1, title: "a"),
      Row(id: 2, title: "b"),
    ])
    #expect(array.contains(id: 1))
    #expect(array.contains(id: 99) == false)
  }

  @Test("remove(ids:) drops every matching id and ignores missing ones")
  func removeIdsBatch() {
    var array = IdentifiedArrayOf<Row>(uniqueElements: [
      Row(id: 1, title: "a"),
      Row(id: 2, title: "b"),
      Row(id: 3, title: "c"),
    ])
    array.remove(ids: [1, 99, 3])
    #expect(array.ids == [2])
  }

  @Test("remove(ids:) tolerates duplicate ids and keeps the index consistent")
  func removeIdsBatchDuplicatesAndIndexConsistency() {
    var array = IdentifiedArrayOf<Row>(uniqueElements: [
      Row(id: 1, title: "a"),
      Row(id: 2, title: "b"),
      Row(id: 3, title: "c"),
      Row(id: 4, title: "d"),
      Row(id: 5, title: "e"),
    ])
    array.remove(ids: [2, 4, 2, 4, 99])

    #expect(array.ids == [1, 3, 5])
    #expect(array[id: 1]?.title == "a")
    #expect(array[id: 3]?.title == "c")
    #expect(array[id: 5]?.title == "e")
    #expect(array[id: 2] == nil)
    #expect(array[id: 4] == nil)

    // Downstream positions shifted by the batch removal must remain
    // addressable through the id → index map.
    array.insert(Row(id: 6, title: "f"), after: 3)
    #expect(array.ids == [1, 3, 6, 5])
    #expect(array[id: 6]?.title == "f")
  }

  @Test("remove(ids:) removing every element leaves an empty, reusable array")
  func removeIdsBatchAll() {
    var array = IdentifiedArrayOf<Row>(uniqueElements: [
      Row(id: 1, title: "a"),
      Row(id: 2, title: "b"),
    ])
    array.remove(ids: [2, 1])
    #expect(array.isEmpty)

    let appended = array.append(Row(id: 1, title: "again"))
    #expect(appended)
    #expect(array.ids == [1])
  }

  @Test("remove(ids:) with no matching ids is a no-op")
  func removeIdsBatchNoMatches() {
    var array = IdentifiedArrayOf<Row>(uniqueElements: [
      Row(id: 1, title: "a"),
      Row(id: 2, title: "b"),
    ])
    array.remove(ids: [98, 99])
    #expect(array.ids == [1, 2])
  }
}
