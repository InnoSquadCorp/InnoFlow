// MARK: - IdentifiedArray.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

/// An ordered collection that keeps an `id → index` map alongside the backing
/// storage so element lookup, membership testing, and `subscript(id:)` are
/// O(1) amortized instead of the O(N) `firstIndex(where:)` scan that a plain
/// `[Element]` requires.
///
/// `IdentifiedArray` is intentionally minimal — it covers the subset of the
/// TCA-style API surface that `ForEachReducer` and identifiable collection
/// routing actually consume. The shape (`init(uniqueElements:)`,
/// `subscript(id:)`, `append`, `insert(_:before:)`, `insert(_:after:)`,
/// `remove(id:)`) is intentionally familiar so migrating call sites do not
/// have to learn a new vocabulary.
///
/// Element identity is enforced on insertion: appending or inserting an
/// element whose `id` already exists is a programmer error and asserts in
/// debug; release builds silently drop the duplicate to preserve the
/// invariant that the `index` map and `elements` array stay in lockstep.
/// Insertion order is preserved across all mutating operations so iteration
/// and `Collection` semantics remain deterministic.
public struct IdentifiedArray<ID: Hashable & Sendable, Element>: Sendable
where Element: Sendable {

  @usableFromInline
  internal var elements: [Element]

  @usableFromInline
  internal var index: [ID: Int]

  @usableFromInline
  internal let idForElement: @Sendable (Element) -> ID

  /// Creates an empty array.
  ///
  /// `id` extracts the identity from each element. The closure is `@Sendable`
  /// so the resulting value can cross actor boundaries with the rest of the
  /// state. For `Identifiable` elements use `IdentifiedArrayOf<Element>`,
  /// which wires `\.id` automatically.
  public init(id: @escaping @Sendable (Element) -> ID) {
    self.elements = []
    self.index = [:]
    self.idForElement = id
  }

  /// Creates an array from a sequence that contains no duplicate identities.
  ///
  /// Duplicates are dropped silently in release and asserted against in
  /// debug. Keeping the post-condition "every stored element has a unique
  /// id" is what lets `subscript(id:)` stay O(1).
  public init<S: Sequence>(
    uniqueElements: S,
    id: @escaping @Sendable (Element) -> ID
  ) where S.Element == Element {
    self.init(id: id)
    for element in uniqueElements {
      let key = id(element)
      if index[key] != nil {
        assertionFailure(
          "IdentifiedArray.init(uniqueElements:) received duplicate id \(key); duplicates dropped."
        )
        continue
      }
      index[key] = elements.count
      elements.append(element)
    }
  }

  /// O(1). The number of elements currently stored.
  public var count: Int { elements.count }

  /// O(1). `true` when the array contains no elements.
  public var isEmpty: Bool { elements.isEmpty }

  /// The contiguous backing storage in insertion order.
  public var values: [Element] { elements }

  /// The list of element identities in insertion order. Useful for
  /// diffing or driving SwiftUI `ForEach` selection state without
  /// touching the elements themselves.
  public var ids: [ID] { elements.map(idForElement) }

  /// O(1). The element with the given id, or `nil` if no such element exists.
  public subscript(id id: ID) -> Element? {
    get {
      guard let position = index[id] else { return nil }
      return elements[position]
    }
    set {
      switch (index[id], newValue) {
      case (let position?, let value?):
        elements[position] = value
      case (let position?, nil):
        elements.remove(at: position)
        index.removeValue(forKey: id)
        rebuildIndex(from: position)
      case (nil, let value?):
        let resolvedID = idForElement(value)
        guard resolvedID == id else {
          assertionFailure(
            "IdentifiedArray subscript: element id \(resolvedID) does not match subscript key \(id); insertion ignored."
          )
          return
        }
        index[id] = elements.count
        elements.append(value)
      case (nil, nil):
        break
      }
    }
  }

  /// O(1). Whether the array contains an element with the given id.
  public func contains(id: ID) -> Bool {
    index[id] != nil
  }

  /// Appends `element`. Duplicate ids are rejected (asserts in debug).
  @discardableResult
  public mutating func append(_ element: Element) -> Bool {
    let key = idForElement(element)
    guard index[key] == nil else {
      assertionFailure("IdentifiedArray.append: duplicate id \(key) rejected.")
      return false
    }
    index[key] = elements.count
    elements.append(element)
    return true
  }

  /// Inserts `element` at `position`. Duplicate ids are rejected.
  @discardableResult
  public mutating func insert(_ element: Element, at position: Int) -> Bool {
    precondition(
      (elements.startIndex...elements.endIndex).contains(position),
      "IdentifiedArray.insert: position \(position) out of bounds (count=\(elements.count))."
    )
    let key = idForElement(element)
    guard index[key] == nil else {
      assertionFailure("IdentifiedArray.insert: duplicate id \(key) rejected.")
      return false
    }
    elements.insert(element, at: position)
    rebuildIndex(from: position)
    return true
  }

  /// Inserts `element` immediately before the element identified by `id`.
  @discardableResult
  public mutating func insert(_ element: Element, before id: ID) -> Bool {
    guard let position = index[id] else { return false }
    return insert(element, at: position)
  }

  /// Inserts `element` immediately after the element identified by `id`.
  @discardableResult
  public mutating func insert(_ element: Element, after id: ID) -> Bool {
    guard let position = index[id] else { return false }
    return insert(element, at: position + 1)
  }

  /// Removes and returns the element identified by `id`, or `nil` if absent.
  @discardableResult
  public mutating func remove(id: ID) -> Element? {
    guard let position = index.removeValue(forKey: id) else { return nil }
    let removed = elements.remove(at: position)
    rebuildIndex(from: position)
    return removed
  }

  /// Removes every element identified by an id in `ids`. Missing ids are
  /// silently skipped — the operation is treated as "ensure these ids are
  /// gone" rather than a strict batch delete.
  public mutating func remove<S: Sequence>(ids: S) where S.Element == ID {
    for id in ids {
      _ = remove(id: id)
    }
  }

  /// Removes every element. Capacity is preserved so reuse during a hot
  /// reducer drain does not reallocate.
  public mutating func removeAll(keepingCapacity: Bool = false) {
    elements.removeAll(keepingCapacity: keepingCapacity)
    index.removeAll(keepingCapacity: keepingCapacity)
  }

  /// Replaces the element with the same id, or appends it when no match exists.
  /// Returns `true` when an in-place update occurred.
  @discardableResult
  public mutating func updateOrAppend(_ element: Element) -> Bool {
    let key = idForElement(element)
    if let position = index[key] {
      elements[position] = element
      return true
    }
    index[key] = elements.count
    elements.append(element)
    return false
  }

  /// Rebuilds the `id → index` map starting at `lowerBound`. After an
  /// in-middle insert or remove every position downstream of the change
  /// shifted by ±1, so the cached indices need to be refreshed before
  /// the next O(1) lookup.
  @usableFromInline
  internal mutating func rebuildIndex(from lowerBound: Int) {
    guard lowerBound < elements.count else { return }
    for position in lowerBound..<elements.count {
      index[idForElement(elements[position])] = position
    }
  }
}

extension IdentifiedArray: RandomAccessCollection {
  public typealias Index = Int

  public var startIndex: Int { elements.startIndex }
  public var endIndex: Int { elements.endIndex }

  /// Positional read access. Mutation must go through `subscript(id:)` (or
  /// the id-keyed mutating methods) so the cached `id → index` map stays
  /// consistent — replacing an element by position would let the caller
  /// swap in a new id and silently break the O(1) lookup invariant.
  public subscript(position: Int) -> Element {
    elements[position]
  }
}

extension IdentifiedArray: Equatable where Element: Equatable {
  public static func == (lhs: IdentifiedArray<ID, Element>, rhs: IdentifiedArray<ID, Element>) -> Bool {
    lhs.elements == rhs.elements
  }
}

extension IdentifiedArray: Hashable where Element: Hashable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(elements)
  }
}

extension IdentifiedArray where Element: Identifiable, ID == Element.ID {
  /// Creates an empty array of `Identifiable` elements. The element's `\.id`
  /// is used as the identity projection automatically.
  public init() {
    self.init(id: { $0.id })
  }

  /// Creates an array of `Identifiable` elements with no duplicate ids.
  public init<S: Sequence>(uniqueElements: S) where S.Element == Element {
    self.init(uniqueElements: uniqueElements, id: { $0.id })
  }
}

/// Convenience alias mirroring the public TCA-style name.
public typealias IdentifiedArrayOf<Element: Identifiable & Sendable> =
  IdentifiedArray<Element.ID, Element> where Element.ID: Sendable
