import Foundation
import InnoFlowCore
import InnoFlowTesting
import Observation
#if canImport(InnoFlowSwiftUI)
import InnoFlowSwiftUI
#endif

private struct Work: Reducer {
  struct State: Equatable, Sendable {
    var count = 0
    var selected = 17
    @BindableField var bindingValue = 0
    var rows = IdentifiedArray(uniqueElements: (0..<1_000).map { Row(id: $0) })
  }
  struct Row: Identifiable, Equatable, Sendable { let id: Int; var value = 0 }
  enum Action: Equatable, Sendable { case add, chain(Int), output(Int), row(Int), binding(Int) }
  func reduce(into state: inout State, action: Action) -> ReducerEffect<Action, Int> {
    switch action {
    case .add: state.count += 1; return .none
    case .chain(let remaining):
      state.count += 1
      return remaining > 0 ? .send(.chain(remaining - 1)) : .none
    case .output(let value): state.count += 1; return Self.output(value)
    case .row(let id): state.rows[id: id]?.value += 1; return .none
    case .binding(let value): state.bindingValue = value; return .none
    }
  }
}

@main struct Bench {
  @MainActor static func main() async {
    guard CommandLine.arguments.count == 3, let count = Int(CommandLine.arguments[2]), count > 0 else {
      print("Usage: InnoFlowBenchmarks S1|S2|S3|S4|S5|S6|diagnostics|output ITERATIONS")
      exit(64)
    }
    let scenario = CommandLine.arguments[1]
    let clock = ContinuousClock()
    let store = Store(reducer: Work(), initialState: .init())
    var checksum = 0
    var elapsed: Duration = .zero
    switch scenario {
    case "S1":
      let start = clock.now
      for _ in 0..<count { store.send(.add) }
      elapsed = start.duration(to: clock.now)
      checksum = store.state.count; precondition(checksum == count)
    case "S2":
      let start = clock.now
      for _ in 0..<count { store.send(.chain(10)) }
      elapsed = start.duration(to: clock.now)
      checksum = store.state.count; precondition(checksum == count * 11)
    case "S3":
      let path = CollectionActionPath<Work.Action, Int, Void>(embed: { id, _ in .row(id) }, extract: {
        guard case .row(let id) = $0 else { return nil }; return (id, ())
      })
      let rows = store.scope(collection: \.rows, action: path)
      precondition(rows.count == 1_000)
      for row in rows { withObservationTracking { _ = row.state.value } onChange: {} }
      let start = clock.now
      for i in 0..<count {
        let row = rows[i % rows.count]
        withObservationTracking { _ = row.state.value } onChange: {}
        row.send(())
      }
      elapsed = start.duration(to: clock.now)
      checksum = rows.reduce(0) { $0 + $1.state.value }; precondition(checksum == count)
    case "S4":
      let values = (0..<100).map { offset in store.select(dependingOn: \.selected) { $0 + offset } }
      for value in values { withObservationTracking { _ = value.requireAlive() } onChange: {} }
      let start = clock.now
      for _ in 0..<count { store.send(.add) }
      elapsed = start.duration(to: clock.now)
      checksum = store.state.count + values.reduce(0) { $0 + $1.requireAlive() }
      precondition(checksum == count + 6_650)
    case "S5":
      #if canImport(InnoFlowSwiftUI)
      let binding = store.binding(\.$bindingValue, to: Work.Action.binding)
      let start = clock.now
      for i in 0..<count { binding.wrappedValue = i }
      elapsed = start.duration(to: clock.now)
      checksum = binding.wrappedValue; precondition(checksum == count - 1)
      #else
      print("{\"scenario\":\"S5\",\"status\":\"unsupported-platform\",\"reason\":\"SwiftUI binding needs Apple SDK\"}")
      exit(2)
      #endif
    case "S6":
      let test = TestStore(reducer: Work(), initialState: .init()); test.exhaustivity = .off
      let start = clock.now
      for _ in 0..<count { await test.send(.chain(1)); await test.receive(.chain(0)) }
      await test.finish()
      elapsed = start.duration(to: clock.now)
      checksum = test.state.count; precondition(checksum == count * 2)
    case "cancel":
      let start = clock.now
      for _ in 0..<count { await store.cancelEffects(identifiedBy: StaticEffectID("benchmark")) }
      elapsed = start.duration(to: clock.now)
      precondition(store.state.count == 0)
      checksum = count
    case "diagnostics":
      let diagnostics = StoreDiagnostics(capacity: 32)
      let measured = Store(reducer: Work(), initialState: .init(), diagnostics: diagnostics)
      let start = clock.now
      for _ in 0..<count { measured.send(.add) }
      elapsed = start.duration(to: clock.now)
      checksum = measured.state.count
      precondition(checksum == count && diagnostics.snapshot().activeDispatches.isEmpty && diagnostics.snapshot().records.count <= 32)
    case "output":
      let test = TestStore(reducer: Work(), initialState: .init()); test.exhaustivity = .off
      let start = clock.now
      for i in 0..<count { await test.send(.output(i)); await test.receiveOutput(i) }
      await test.finish()
      elapsed = start.duration(to: clock.now)
      checksum = test.state.count; precondition(checksum == count)
    default: fatalError("Unknown benchmark")
    }
    let duration = elapsed.components
    let ns = Double(duration.seconds) * 1e9 + Double(duration.attoseconds) / 1e9
    print("{\"scenario\":\"\(scenario)\",\"iterations\":\(count),\"ns\":\(ns),\"checksum\":\(checksum),\"status\":\"measured\"}")
  }
}
