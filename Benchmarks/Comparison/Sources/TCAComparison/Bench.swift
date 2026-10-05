import Combine
import ComposableArchitecture
import Foundation
import Observation
import SwiftUI

@Reducer
private struct Row {
  @ObservableState struct State: Equatable, Identifiable { let id: Int; var value = 0 }
  enum Action: Equatable { case increment }
  var body: some ReducerOf<Self> {
    Reduce { state, _ in state.value += 1; return .none }
  }
}
@Reducer
private struct Work {
  @ObservableState struct State: Equatable {
    var count = 0
    var selected = 17
    var bindingValue = 0
    var rows = IdentifiedArrayOf<Row.State>(uniqueElements: (0..<1_000).map { Row.State(id: $0) })
  }
  enum Action: Equatable {
    case add, chain(Int), binding(Int), rows(IdentifiedActionOf<Row>)
  }
  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .add: state.count += 1; return .none
      case .chain(let remaining):
        state.count += 1
        return remaining > 0 ? .send(.chain(remaining - 1)) : .none
      case .binding(let value): state.bindingValue = value; return .none
      case .rows: return .none
      }
    }.forEach(\.rows, action: \.rows) { Row() }
  }
}
@main struct Bench {
  @MainActor static func main() async {
    guard CommandLine.arguments.count == 3, let count = Int(CommandLine.arguments[2]), count > 0 else { exit(64) }
    let scenario = CommandLine.arguments[1]
    let clock = ContinuousClock()
    let store = Store(initialState: Work.State()) { Work() }
    var elapsed: Duration = .zero
    var checksum = 0
    switch scenario {
    case "S1":
      let start = clock.now
      for _ in 0..<count { store.send(.add) }
      elapsed = start.duration(to: clock.now)
      checksum = store.count; precondition(checksum == count)
    case "S2":
      let start = clock.now
      for _ in 0..<count { store.send(.chain(10)) }
      elapsed = start.duration(to: clock.now)
      checksum = store.count; precondition(checksum == count * 11)
    case "S3":
      let rows = Array(store.scope(\.rows, action: \.rows))
      precondition(rows.count == 1_000)
      for row in rows { withObservationTracking { _ = row.value } onChange: {} }
      let start = clock.now
      for i in 0..<count {
        let row = rows[i % rows.count]
        withObservationTracking { _ = row.value } onChange: {}
        row.send(.increment)
      }
      elapsed = start.duration(to: clock.now)
      checksum = rows.reduce(0) { $0 + $1.value }; precondition(checksum == count)
    case "S4":
      // TCA's retained derived read-model surface is ViewStore. This is a
      // semantic counterpart, not an assertion that its internals match select.
      let values = (0..<100).map { offset in ViewStore(store, observe: { $0.selected + offset }) }
      let observations = values.map { $0.publisher.sink { _ in } }
      let start = clock.now
      for _ in 0..<count { store.send(.add) }
      elapsed = start.duration(to: clock.now)
      checksum = store.count + values.reduce(0) { $0 + $1.state }
      precondition(checksum == count + 6_650)
      withExtendedLifetime(observations) {}
    case "S5":
      let binding = Binding(get: { store.bindingValue }, set: { store.send(.binding($0)) })
      let start = clock.now
      for i in 0..<count { binding.wrappedValue = i }
      elapsed = start.duration(to: clock.now)
      checksum = binding.wrappedValue; precondition(checksum == count - 1)
    case "S6":
      let test = TestStore(initialState: Work.State()) { Work() }; test.exhaustivity = .off
      let start = clock.now
      for _ in 0..<count { await test.send(.chain(1)); await test.receive(.chain(0)) }
      await test.finish()
      elapsed = start.duration(to: clock.now)
      checksum = test.state.count; precondition(checksum == count * 2)
    default: fatalError("Unknown scenario")
    }
    let d = elapsed.components
    let ns = Double(d.seconds) * 1e9 + Double(d.attoseconds) / 1e9
    print("{\"scenario\":\"\(scenario)\",\"iterations\":\(count),\"ns\":\(ns),\"checksum\":\(checksum),\"status\":\"measured\"}")
  }
}
