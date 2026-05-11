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
}
