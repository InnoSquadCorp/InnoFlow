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
  struct Row: Identifiable, Equatable, Sendable {
    let id: Int
    var value = 0
  }
  enum Action: Equatable, Sendable {
    case add
    case chain(Int)
    case output(Int)
    case row(Int)
    case binding(Int)
  }
  func reduce(into state: inout State, action: Action) -> ReducerEffect<Action, Int> {
    switch action {
    case .add:
      state.count += 1
      return .none
    case .chain(let remaining):
      state.count += 1
      return remaining > 0 ? .send(.chain(remaining - 1)) : .none
    case .output(let value):
      state.count += 1
      return Self.output(value)
    case .row(let id):
      state.rows[id: id]?.value += 1
      return .none
    case .binding(let value):
      state.bindingValue = value
      return .none
    }
  }
}

/// Workloads for the effect runtime and projection scaling. They use their
/// own reducer so the S1-S6 state layout, and therefore those baselines, stay
/// unchanged.
private struct Lab: Reducer {
  static let workID = EffectID<String>("lab-work")
  struct Row: Identifiable, Equatable, Sendable {
    let id: Int
    var value = 0
  }
  struct State: Equatable, Sendable {
    var count = 0
    var values = Array(repeating: 0, count: 1_000)
    var rows = IdentifiedArray(uniqueElements: (0..<1_000).map { Row(id: $0) })
    var nextRowID = 1_000
  }
  enum Action: Sendable {
    case add, run, restart, rotateRows
    case row(Int)
  }
  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .add:
      state.count += 1
      return .none
    case .run: return .run { send in await send(.add) }
    case .restart:
      return EffectTask<Action>.run { send in await send(.add) }
        .cancellable(Self.workID, cancelInFlight: true)
    case .rotateRows:
      // A structural change: every retained row shifts by one offset.
      _ = state.rows.remove(id: state.nextRowID - 1_000)
      _ = state.rows.append(Row(id: state.nextRowID))
      state.nextRowID += 1
      return .none
    case .row(let id):
      state.rows[id: id]?.value += 1
      return .none
    }
  }
}

@main struct Bench {
  @MainActor static func main() async {
    guard CommandLine.arguments.count == 3, let count = Int(CommandLine.arguments[2]), count > 0
    else {
      print(
        "Usage: InnoFlowBenchmarks S1|S2|S3|S4|S5|S6|S7|S8|R1|R2|cancel|diagnostics|output ITERATIONS"
      )
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
      checksum = store.state.count
      precondition(checksum == count)
    case "S2":
      let start = clock.now
      for _ in 0..<count { store.send(.chain(10)) }
      elapsed = start.duration(to: clock.now)
      checksum = store.state.count
      precondition(checksum == count * 11)
    case "S3":
      let path = CollectionActionPath<Work.Action, Int, Void>(
        embed: { id, _ in .row(id) },
        extract: {
          guard case .row(let id) = $0 else { return nil }
          return (id, ())
        })
      let rows = store.scope(collection: \.rows, action: path)
      precondition(rows.count == 1_000)
      for row in rows {
        withObservationTracking {
          _ = row.state.value
        } onChange: {
        }
      }
      let start = clock.now
      for i in 0..<count {
        let row = rows[i % rows.count]
        withObservationTracking {
          _ = row.state.value
        } onChange: {
        }
        row.send(())
      }
      elapsed = start.duration(to: clock.now)
      checksum = rows.reduce(0) { $0 + $1.state.value }
      precondition(checksum == count)
    case "S4":
      let values = (0..<100).map { offset in store.select(dependingOn: \.selected) { $0 + offset } }
      for value in values {
        withObservationTracking {
          _ = value.requireAlive()
        } onChange: {
        }
      }
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
        checksum = binding.wrappedValue
        precondition(checksum == count - 1)
      #else
        print(
          "{\"scenario\":\"S5\",\"status\":\"unsupported-platform\",\"reason\":\"SwiftUI binding needs Apple SDK\"}"
        )
        exit(2)
      #endif
    case "S6":
      let test = TestStore(reducer: Work(), initialState: .init())
      test.exhaustivity = .off
      let start = clock.now
      for _ in 0..<count {
        await test.send(.chain(1))
        await test.receive(.chain(0))
      }
      await test.finish()
      elapsed = start.duration(to: clock.now)
      checksum = test.state.count
      precondition(checksum == count * 2)
    case "S7":
      // 1,000 retained key-path selections with distinct dependencies and an
      // update none of them depends on: the cost of an action as a function
      // of how many selections exist.
      let lab = Store(reducer: Lab(), initialState: .init())
      let selections = (0..<1_000).map { lab.select(\Lab.State.values[$0]) }
      for selection in selections {
        withObservationTracking {
          _ = selection.requireAlive()
        } onChange: {
        }
      }
      let start = clock.now
      for _ in 0..<count { lab.send(.add) }
      elapsed = start.duration(to: clock.now)
      checksum = lab.state.count + selections.reduce(0) { $0 + $1.requireAlive() }
      precondition(checksum == count)
    case "S8":
      // 1,000 retained collection projections and a structural change that
      // shifts every row's offset.
      let lab = Store(reducer: Lab(), initialState: .init())
      let path = CollectionActionPath<Lab.Action, Int, Void>(
        embed: { id, _ in .row(id) },
        extract: {
          guard case .row(let id) = $0 else { return nil }
          return (id, ())
        })
      let rows = lab.scope(collection: \.rows, action: path)
      precondition(rows.count == 1_000)
      for row in rows {
        withObservationTracking {
          _ = row.optionalState
        } onChange: {
        }
      }
      let start = clock.now
      for _ in 0..<count { lab.send(.rotateRows) }
      elapsed = start.duration(to: clock.now)
      checksum = lab.state.rows.count
      precondition(checksum == 1_000 && lab.state.nextRowID == 1_000 + count)
      withExtendedLifetime(rows) {}
    case "R1":
      // One run effect that emits one action, awaited to completion.
      let lab = Store(reducer: Lab(), initialState: .init())
      let start = clock.now
      for _ in 0..<count { await lab.send(.run).finish() }
      elapsed = start.duration(to: clock.now)
      checksum = lab.state.count
      precondition(checksum == count)
    case "R2":
      // A cancelInFlight replacement per iteration, awaited to completion.
      let lab = Store(reducer: Lab(), initialState: .init())
      let start = clock.now
      for _ in 0..<count { await lab.send(.restart).finish() }
      elapsed = start.duration(to: clock.now)
      checksum = lab.state.count
      precondition(checksum == count)
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
      precondition(
        checksum == count && diagnostics.snapshot().activeDispatches.isEmpty
          && diagnostics.snapshot().records.count <= 32)
    case "output":
      let test = TestStore(reducer: Work(), initialState: .init())
      test.exhaustivity = .off
      let start = clock.now
      for i in 0..<count {
        await test.send(.output(i))
        await test.receiveOutput(i)
      }
      await test.finish()
      elapsed = start.duration(to: clock.now)
      checksum = test.state.count
      precondition(checksum == count)
    default: fatalError("Unknown benchmark")
    }
    let duration = elapsed.components
    let ns = Double(duration.seconds) * 1e9 + Double(duration.attoseconds) / 1e9
    print(
      "{\"scenario\":\"\(scenario)\",\"iterations\":\(count),\"ns\":\(ns),\"checksum\":\(checksum),\"status\":\"measured\"}"
    )
  }
}
