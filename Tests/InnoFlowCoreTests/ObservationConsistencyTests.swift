import Foundation
import InnoFlowCore
import Observation
import Testing
import os

private struct ObservationConsistencyFeature: Reducer {
  struct Child: Equatable, Sendable { var count = 0 }
  struct State: Equatable, Sendable {
    var child = Child()
    var other = 0
  }
  enum Action: Sendable { case child, other, unchanged }
  let events: OSAllocatedUnfairLock<[String]>
  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    events.withLock { $0.append("reduce") }
    switch action {
    case .child: state.child.count += 1
    case .other: state.other += 1
    case .unchanged: break
    }
    return .none
  }
}
@MainActor @Suite("Observation semantics controls")
struct ObservationConsistencyTests {
  @Test func rootInvalidationPrecedesEachReductionExactlyOnce() {
    let events = OSAllocatedUnfairLock<[String]>(initialState: [])
    let store = Store(reducer: ObservationConsistencyFeature(events: events), initialState: .init())
    for action in [ObservationConsistencyFeature.Action.child, .other, .unchanged] {
      withObservationTracking {
        _ = store.state.child.count
      } onChange: {
        events.withLock { $0.append("invalidate") }
      }
      store.send(action)
    }
    #expect(
      events.withLock { $0 } == [
        "invalidate", "reduce", "invalidate", "reduce", "invalidate", "reduce",
      ])
    #expect(store.state.child.count == 1 && store.state.other == 1)
  }
  @Test func childAndSelectedOnlyInvalidateForChangedValues() {
    let events = OSAllocatedUnfairLock<[String]>(initialState: [])
    let store = Store(reducer: ObservationConsistencyFeature(events: events), initialState: .init())
    let child = store.scope(
      state: \.child,
      action: CasePath<ObservationConsistencyFeature.Action, Void>(
        embed: { _ in .child }, extract: { if case .child = $0 { () } else { nil } }
      ))
    let selected = store.select(dependingOn: \.child.count) { $0 * 2 }
    withObservationTracking {
      _ = child.state.count
    } onChange: {
      events.withLock { $0.append("child") }
    }
    withObservationTracking {
      _ = selected.requireAlive()
    } onChange: {
      events.withLock { $0.append("selected") }
    }
    store.send(.other)
    #expect(events.withLock { $0 } == ["reduce"])
    store.send(.child)
    let all = events.withLock { $0 }
    #expect(all.prefix(2) == ["reduce", "reduce"])
    #expect(all.filter { $0 == "child" }.count == 1)
    #expect(all.filter { $0 == "selected" }.count == 1)
    #expect(child.state.count == 1 && selected.requireAlive() == 2)
  }
  @Test func releasingParentInvalidatesProjectedLiveness() {
    let events = OSAllocatedUnfairLock<[String]>(initialState: [])
    var store: Store<ObservationConsistencyFeature>? = Store(
      reducer: ObservationConsistencyFeature(events: events), initialState: .init())
    let child = store!.scope(
      state: \.child,
      action: CasePath<ObservationConsistencyFeature.Action, Void>(
        embed: { _ in .child }, extract: { if case .child = $0 { () } else { nil } }
      ))
    let selected = store!.select(dependingOn: \.child.count) { $0 }
    withObservationTracking {
      _ = child.isAlive
    } onChange: {
      events.withLock { $0.append("child") }
    }
    withObservationTracking {
      _ = selected.isAlive
    } onChange: {
      events.withLock { $0.append("selected") }
    }
    store = nil
    #expect(!child.isAlive && !selected.isAlive)
    #expect(events.withLock { $0 }.sorted() == ["child", "selected"])
  }
}
