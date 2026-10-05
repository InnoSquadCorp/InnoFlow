import InnoFlowCore
import Observation
import Testing
import os

private struct PerformanceObservationFeature: Reducer {
  struct Row: Identifiable, Equatable, Sendable {
    let id: Int
    var value = 0
  }
  struct State: Equatable, Sendable {
    var rows = IdentifiedArray(uniqueElements: (0..<1_000).map { Row(id: $0) })
    var unrelated = 0
  }
  enum Action: Sendable {
    case row(Int)
    case unrelated
  }
  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .row(let id): state.rows[id: id]?.value += 1
    case .unrelated: state.unrelated += 1
    }
    return .none
  }
}

@MainActor
@Suite("Measured fast path semantic controls")
struct PerformanceSemanticsConsistencyTests {
  @Test func thousandRowScopesNotifyOnlyTheChangedRowIncludingRearmedObservers() {
    let store = Store(reducer: PerformanceObservationFeature(), initialState: .init())
    let path = CollectionActionPath<PerformanceObservationFeature.Action, Int, Void>(
      embed: { id, _ in .row(id) },
      extract: {
        guard case .row(let id) = $0 else { return nil }
        return (id, ())
      })
    let rows = store.scope(collection: \.rows, action: path)
    let notifications = OSAllocatedUnfairLock<[Int: Int]>(initialState: [:])
    #expect(rows.count == 1_000)
    for (id, row) in rows.enumerated() {
      withObservationTracking {
        _ = row.state.value
      } onChange: {
        notifications.withLock { $0[id, default: 0] += 1 }
      }
    }
    store.send(.unrelated)
    #expect(notifications.withLock { $0.isEmpty })
    var visited = Set<Int>()
    for id in [0, 999, 0, 1, 999] {
      let row = rows[id]
      // Exactly the benchmark registration pattern: its initial one-shot
      // observer plus one re-registration before each selected row update.
      withObservationTracking {
        _ = row.state.value
      } onChange: {
        notifications.withLock { $0[id, default: 0] += 1 }
      }
      row.send(())
      let expectedCount = visited.insert(id).inserted ? 2 : 1
      let delivered = notifications.withLock { values in
        let copy = values
        values.removeAll()
        return copy
      }
      #expect(delivered == [id: expectedCount])
    }
    #expect(rows.reduce(0) { $0 + $1.state.value } == 5)
    #expect(store.state.unrelated == 1)
  }

  @Test func mutatingDisabledInstrumentationReenablesItsQueueCallbacks() {
    let drained = OSAllocatedUnfairLock<[Int]>(initialState: [])
    var instrumentation = StoreInstrumentation<PerformanceObservationFeature.Action>.disabled
    #expect(!instrumentation.isEnabled)
    instrumentation.didDrainActionQueue = { event in
      drained.withLock { $0.append(event.processedActionCount) }
    }
    #expect(instrumentation.isEnabled)
    let store = Store(
      reducer: PerformanceObservationFeature(), initialState: .init(),
      instrumentation: .combined(.disabled, instrumentation, .disabled))
    store.send(.unrelated)
    store.send(.unrelated)
    #expect(drained.withLock { $0 } == [1, 1])
    #expect(store.state.unrelated == 2)
    #expect(
      !StoreInstrumentation<PerformanceObservationFeature.Action>.combined(.disabled, .disabled)
        .isEnabled)
  }

  @Test func disabledQueueMetricsStillReleaseOversizedStorageAndResetDrain() {
    let queue = StoreActionQueue<Int>(collectingMetrics: false)
    for _ in 0..<3 {
      for value in 0..<10_000 { queue.enqueue(value, animation: nil) }
      #expect(queue.beginDrain())
      for value in 0..<10_000 { #expect(queue.next()?.action == value) }
      #expect(queue.next() == nil)
      queue.finishDrainDiscardingMetrics()
      #expect(queue.beginDrain())
      let snapshot = queue.finishDrain()
      #expect(snapshot.retainedByteEstimate <= storeActionQueueRetainedStorageBudget)
      #expect(snapshot.processedActionCount == 0)
    }
  }
}
