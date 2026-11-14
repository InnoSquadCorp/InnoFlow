// MARK: - CollectionProjectionRefreshTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import InnoFlowCore
import Observation
import Testing
import os

// A collection scope refreshes the rows a state change can affect, not every
// row of the collection: a value change refreshes that row, a structural
// change refreshes the rows whose element changed or disappeared, and an
// action that never touches the collection refreshes none. Rows that moved
// must still resolve their own element afterwards.

private struct RefreshRow: Equatable, Sendable, Identifiable {
  let id: Int
  var value = 0
}

/// A random-access collection without contiguous storage, so the registry
/// has to take its element-by-element path.
private struct SegmentedRows: RandomAccessCollection, Equatable, Sendable {
  var head: [RefreshRow]
  var tail: [RefreshRow]

  var startIndex: Int { 0 }
  var endIndex: Int { head.count + tail.count }

  subscript(position: Int) -> RefreshRow {
    position < head.count ? head[position] : tail[position - head.count]
  }
}

/// An element whose equality is not reflexive for `Double.nan` and whose
/// equality checks are counted.
private struct Measurement: Equatable, Sendable, Identifiable {
  let id: Int
  var reading: Double

  static func == (lhs: Self, rhs: Self) -> Bool {
    measurementEqualityChecks.withLock { $0 += 1 }
    return lhs.id == rhs.id && lhs.reading == rhs.reading
  }
}

private let measurementEqualityChecks = OSAllocatedUnfairLock(initialState: 0)

/// An element whose equality ignores its identity.
private struct LooseRow: Equatable, Sendable, Identifiable {
  let id: Int
  var value: Int

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.value == rhs.value
  }
}

private struct RefreshFeature: Reducer {
  struct State: Equatable, Sendable {
    var rows: IdentifiedArray<Int, RefreshRow>
    var segmented: SegmentedRows
    var measurements: [Measurement] = []
    var loose: [LooseRow] = []
    var unrelated = 0
  }

  enum RowAction: Sendable {
    case increment
  }

  enum Action: Sendable {
    case row(id: Int, action: RowAction)
    case touchUnrelated
    case remove(Int)
    case removeAll([Int])
    case insertFirst(Int)
    case moveFirstToEnd
    case moveFirstToEndIncrementing
    case replaceMeasurements([Measurement])
    case replaceLoose([LooseRow])
    case segmentedIncrement(Int)
    case segmentedRemoveFirst
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .row(let id, .increment):
      state.rows[id: id]?.value += 1

    case .touchUnrelated:
      state.unrelated += 1

    case .remove(let id):
      _ = state.rows.remove(id: id)

    case .removeAll(let ids):
      state.rows.remove(ids: ids)

    case .insertFirst(let id):
      _ = state.rows.insert(RefreshRow(id: id), at: 0)

    case .moveFirstToEnd:
      let first = state.rows[0]
      _ = state.rows.remove(id: first.id)
      _ = state.rows.append(first)

    case .moveFirstToEndIncrementing:
      var first = state.rows[0]
      _ = state.rows.remove(id: first.id)
      first.value += 1
      _ = state.rows.append(first)

    case .replaceMeasurements(let measurements):
      state.measurements = measurements

    case .replaceLoose(let rows):
      state.loose = rows

    case .segmentedIncrement(let id):
      if let index = state.segmented.head.firstIndex(where: { $0.id == id }) {
        state.segmented.head[index].value += 1
      } else if let index = state.segmented.tail.firstIndex(where: { $0.id == id }) {
        state.segmented.tail[index].value += 1
      }

    case .segmentedRemoveFirst:
      state.segmented.head.removeFirst()
    }
    return .none
  }
}

private let refreshRowPath = CollectionActionPath<
  RefreshFeature.Action, Int, RefreshFeature.RowAction
>(
  embed: { .row(id: $0, action: $1) },
  extract: {
    guard case .row(let id, let action) = $0 else { return nil }
    return (id, action)
  }
)

private let measurementPath = CollectionActionPath<
  RefreshFeature.Action, Int, RefreshFeature.RowAction
>(
  embed: { id, _ in .touchUnrelated },
  extract: { _ in nil }
)

private let looseRowPath = CollectionActionPath<
  RefreshFeature.Action, Int, RefreshFeature.RowAction
>(
  embed: { id, _ in .touchUnrelated },
  extract: { _ in nil }
)

private let segmentedRowPath = CollectionActionPath<
  RefreshFeature.Action, Int, RefreshFeature.RowAction
>(
  embed: { id, _ in .segmentedIncrement(id) },
  extract: { _ in nil }
)

@MainActor
@Suite("Collection projections refresh only the rows a change affects", .timeLimit(.minutes(5)))
struct CollectionProjectionRefreshTests {
  private typealias RowStore = ScopedStore<RefreshFeature, RefreshRow, RefreshFeature.RowAction>

  private func makeStore(rowCount: Int = 6) -> Store<RefreshFeature> {
    let rows = (0..<rowCount).map { RefreshRow(id: $0) }
    return Store(
      reducer: RefreshFeature(),
      initialState: .init(
        rows: IdentifiedArray(uniqueElements: rows),
        segmented: SegmentedRows(
          head: Array(rows.prefix(rowCount / 2)),
          tail: Array(rows.suffix(rowCount - rowCount / 2))
        )
      )
    )
  }

  /// Counts the Observation notifications each row delivers.
  private func track(_ rows: [RowStore]) -> OSAllocatedUnfairLock<[Int: Int]> {
    let notifications = OSAllocatedUnfairLock(initialState: [Int: Int]())
    for row in rows {
      let id = row.id
      withObservationTracking {
        _ = row.optionalState
      } onChange: {
        notifications.withLock { $0[id, default: 0] += 1 }
      }
    }
    return notifications
  }

  @Test("A value change evaluates and notifies only the row that changed")
  func valueChangeRefreshesOnlyTheChangedRow() {
    let store = makeStore()
    let rows = store.scope(collection: \.rows, action: refreshRowPath)
    let notifications = track(rows)
    let before = store.projectionObserverStats

    rows[2].send(.increment)

    let after = store.projectionObserverStats
    #expect(after.evaluatedObservers == before.evaluatedObservers + 1)
    #expect(after.refreshedObservers == before.refreshedObservers + 1)
    #expect(notifications.withLock { $0 } == [2: 1])
    #expect(rows.map { $0.state.value } == [0, 0, 1, 0, 0, 0])
  }

  @Test("An action that never touches the collection evaluates no row")
  func unrelatedActionEvaluatesNoRow() {
    let store = makeStore()
    let rows = store.scope(collection: \.rows, action: refreshRowPath)
    let notifications = track(rows)
    let before = store.projectionObserverStats

    store.send(.touchUnrelated)

    let after = store.projectionObserverStats
    #expect(after.refreshPassCount == before.refreshPassCount + 1)
    #expect(after.evaluatedObservers == before.evaluatedObservers)
    #expect(notifications.withLock { $0 }.isEmpty)
    withExtendedLifetime(rows) {}
  }

  @Test("Removing an element deactivates its row and leaves the other rows unevaluated")
  func removalRefreshesOnlyTheRemovedRow() {
    let store = makeStore()
    let rows = store.scope(collection: \.rows, action: refreshRowPath)
    let notifications = track(rows)
    let before = store.projectionObserverStats

    store.send(.remove(1))

    let after = store.projectionObserverStats
    #expect(after.evaluatedObservers == before.evaluatedObservers + 1)
    #expect(notifications.withLock { $0 } == [1: 1])
    #expect(rows.map { $0.isAlive } == [true, false, true, true, true, true])
    // Rows after the removed one moved; each still resolves its own element.
    rows[4].send(.increment)
    #expect(rows[4].state == RefreshRow(id: 4, value: 1))
    #expect(rows[5].state == RefreshRow(id: 5, value: 0))
  }

  @Test("Removing many elements at once deactivates exactly those rows")
  func bulkRemovalDeactivatesExactlyTheRemovedRows() {
    let store = makeStore(rowCount: 200)
    let rows = store.scope(collection: \.rows, action: refreshRowPath)
    let removed = Array(stride(from: 0, to: 200, by: 2))
    let before = store.projectionObserverStats

    store.send(.removeAll(removed))

    let after = store.projectionObserverStats
    #expect(after.evaluatedObservers == before.evaluatedObservers + UInt64(removed.count))
    #expect(rows.filter { $0.isAlive }.map { $0.id } == Array(stride(from: 1, to: 200, by: 2)))
    rows[199].send(.increment)
    #expect(rows[199].state == RefreshRow(id: 199, value: 1))
  }

  @Test("Rows that only moved are not notified and resolve their element at its new position")
  func movedRowsKeepResolvingTheirElement() {
    let store = makeStore()
    let rows = store.scope(collection: \.rows, action: refreshRowPath)
    let notifications = track(rows)

    store.send(.insertFirst(100))
    store.send(.moveFirstToEnd)
    #expect(notifications.withLock { $0 }.isEmpty)
    #expect(Array(store.state.rows.ids) == [0, 1, 2, 3, 4, 5, 100])

    // Every original row shifted twice; a change must still reach the right one.
    rows[3].send(.increment)
    #expect(notifications.withLock { $0 } == [3: 1])
    #expect(rows.map { $0.state.value } == [0, 0, 0, 1, 0, 0])
    #expect(store.state.rows[id: 3]?.value == 1)
  }

  @Test("A value change that coincides with a structural change still reaches its row")
  func valueChangeDuringStructuralChangeReachesItsRow() {
    let store = makeStore()
    let rows = store.scope(collection: \.rows, action: refreshRowPath)
    let notifications = track(rows)

    // One reduction removes the first element and re-adds the same id with
    // another value: a structural change and a value change at once.
    store.send(.moveFirstToEndIncrementing)
    #expect(notifications.withLock { $0 } == [0: 1])
    #expect(rows[0].state == RefreshRow(id: 0, value: 1))
    #expect(rows.allSatisfy { $0.isAlive })
    #expect(store.state.rows.map(\.id) == [1, 2, 3, 4, 5, 0])
  }

  @Test("Control: a removed row is deactivated")
  func removedRowIsDeactivated() {
    let store = makeStore()
    let rows = store.scope(collection: \.rows, action: refreshRowPath)

    store.send(.remove(1))

    #expect(rows[1].isAlive == false)
    #expect(rows[1].optionalState == nil)
  }

  @Test("Scoping the collection again inside the refresh pass still deactivates a removed row")
  func scopingInsideTheRefreshPassStillDeactivatesTheRemovedRow() {
    let store = makeStore()
    let rows = store.scope(collection: \.rows, action: refreshRowPath)
    let count = store.select(dependingOn: \.rows) { $0.count }
    withObservationTracking {
      _ = count.optionalValue
    } onChange: {
      // The selection is notified before the collection rows are
      // classified: the state is reduced, the rows are not refreshed yet.
      MainActor.assumeIsolated {
        _ = store.scope(collection: \.rows, action: refreshRowPath)
      }
    }

    store.send(.remove(1))

    #expect(rows[1].isAlive == false)
    #expect(rows[1].optionalState == nil)
    #expect(rows.filter(\.isAlive).map { $0.state.id } == [0, 2, 3, 4, 5])
    withExtendedLifetime(count) {}
  }

  @Test("Scoping inside the refresh pass does not compare a moved row with another element")
  func scopingInsideTheRefreshPassComparesEachRowWithItsOwnElement() {
    let store = makeStore()
    store.send(.replaceLoose([LooseRow(id: 0, value: 5), LooseRow(id: 1, value: 7)]))
    let rows = store.scope(collection: \.loose, action: looseRowPath)
    let count = store.select(dependingOn: \.loose) { $0.count + $0.reduce(0) { $0 + $1.value } }
    withObservationTracking {
      _ = count.optionalValue
    } onChange: {
      MainActor.assumeIsolated {
        _ = store.scope(collection: \.loose, action: looseRowPath)
      }
    }

    // The rows swap places and row 1 takes the value row 0 had. Indexed
    // against the new collection, row 1's offset points at row 0's old
    // element, which this element type considers equal.
    store.send(.replaceLoose([LooseRow(id: 1, value: 5), LooseRow(id: 0, value: 8)]))

    #expect(rows.first { $0.id == 1 }?.optionalState?.value == 5)
    #expect(rows.first { $0.id == 0 }?.optionalState?.value == 8)
    withExtendedLifetime(count) {}
  }

  @Test("Selecting on a removed row at the same call site reports absence instead of trapping")
  func reselectingOnARemovedRowReportsAbsence() {
    let store = makeStore()
    let row = store.scope(collection: \.rows, action: refreshRowPath)[1]
    // One call site, as a view body that is evaluated again.
    func read() -> Int? { row.select(\RefreshRow.value).optionalValue }

    #expect(read() == 0)
    store.send(.remove(1))

    #expect(row.optionalState == nil)
    #expect(read() == nil)
  }

  @Test("Elements with identical bytes are unchanged without consulting their equality")
  func bitwiseIdenticalElementsSkipEquality() {
    let store = makeStore()
    let measurements = (0..<4).map { Measurement(id: $0, reading: $0 == 2 ? .nan : 1) }
    store.send(.replaceMeasurements(measurements))
    let rows = store.scope(collection: \.measurements, action: measurementPath)
    let notified = OSAllocatedUnfairLock(initialState: false)
    withObservationTracking {
      _ = rows[2].optionalState
    } onChange: {
      notified.withLock { $0 = true }
    }

    // A fresh array with the same bytes. `nan != nan`, so equality alone
    // would report the third row as changed on every such replacement.
    measurementEqualityChecks.withLock { $0 = 0 }
    store.send(.replaceMeasurements(Array(measurements)))

    #expect(measurementEqualityChecks.withLock { $0 } == 0)
    #expect(notified.withLock { $0 } == false)
    #expect(rows.allSatisfy { $0.isAlive })
  }

  @Test("IdentifiedArray exposes its elements as contiguous storage")
  func identifiedArrayExposesContiguousStorage() {
    let rows = IdentifiedArray(uniqueElements: (0..<3).map { RefreshRow(id: $0, value: $0) })

    let values = rows.withContiguousStorageIfAvailable { buffer in buffer.map(\.value) }

    #expect(values == [0, 1, 2])
  }

  @Test("A collection without contiguous storage refreshes and deactivates rows correctly")
  func nonContiguousCollectionKeepsRowsCorrect() {
    let store = makeStore()
    let rows = store.scope(collection: \.segmented, action: segmentedRowPath)
    let notifications = track(rows)

    store.send(.segmentedIncrement(4))
    #expect(notifications.withLock { $0 } == [4: 1])
    #expect(rows[4].state == RefreshRow(id: 4, value: 1))

    store.send(.segmentedRemoveFirst)
    #expect(rows.map { $0.isAlive } == [false, true, true, true, true, true])
    store.send(.segmentedIncrement(5))
    #expect(rows[5].state == RefreshRow(id: 5, value: 1))
    #expect(rows[4].state == RefreshRow(id: 4, value: 1))
  }
}
