import InnoFlowCore
import Observation
import Testing
import os

private final class SnapshotBoundaryEvents: Sendable {
  private let storage = OSAllocatedUnfairLock(initialState: [String]())
  func record(_ value: String) { storage.withLock { $0.append(value) } }
  func reset() { storage.withLock { $0.removeAll() } }
  var values: [String] { storage.withLock { $0 } }
}

private struct SnapshotBoundaryFeature: Reducer {
  struct Child: Equatable, Sendable { var count = 0 }
  struct State: Equatable, Sendable {
    var values = [1, 2, 3]
    var child = Child()
    var other = 0
  }
  enum Action: Sendable {
    case append(Int)
    case other, unchanged
  }
  let events: SnapshotBoundaryEvents

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .append(let value):
      events.record("reduce.append")
      state.values.append(value)
      state.child.count += 1
    case .other:
      events.record("reduce.other")
      state.other += 1
    case .unchanged:
      events.record("reduce.unchanged")
    }
    return .none
  }
}

@MainActor
private final class SnapshotBoundaryHandles {
  var selection: SelectedStore<Int>?
  weak var weakSelection: SelectedStore<Int>?
  var child: ScopedStore<SnapshotBoundaryFeature, SnapshotBoundaryFeature.Child, Void>?
}

@MainActor
private func sendSnapshotAction(
  _ action: SnapshotBoundaryFeature.Action,
  to store: Store<SnapshotBoundaryFeature>,
  animated: Bool,
  events: SnapshotBoundaryEvents
) {
  if animated {
    // Exercise the same queued animation boundary used by animated effects.
    store.enqueue(
      action,
      animation: .init(description: "snapshot boundary") { updates in
        events.record("animation.begin")
        updates()
        events.record("animation.end")
      })
  } else {
    store.send(action)
  }
}

@Suite("State snapshot observable contracts")
@MainActor
struct SnapshotBoundaryConsistencyTests {
  @Test(arguments: [false, true])
  func rootObservationPrecedesMutationWithoutProjections(animated: Bool) {
    let events = SnapshotBoundaryEvents()
    let store = Store(reducer: SnapshotBoundaryFeature(events: events), initialState: .init())
    for action in [SnapshotBoundaryFeature.Action.append(4), .other, .unchanged] {
      let previousValues = store.state.values
      withObservationTracking {
        _ = store.state
      } onChange: {
        MainActor.assumeIsolated {
          #expect(store.state.values == previousValues)
          events.record("root")
        }
      }
      sendSnapshotAction(action, to: store, animated: animated, events: events)
    }
    let mutations = ["reduce.append", "reduce.other", "reduce.unchanged"]
    let expected = mutations.flatMap { mutation in
      animated ? ["animation.begin", "root", mutation, "animation.end"] : ["root", mutation]
    }
    #expect(events.values == expected)
    #expect(store.state.values == [1, 2, 3, 4])
    #expect(store.state.child.count == 1 && store.state.other == 1)
  }

  @Test(arguments: [false, true])
  func retainedSelectedAndScopedValuesKeepTheirSnapshots(animated: Bool) {
    let events = SnapshotBoundaryEvents()
    let store = Store(reducer: SnapshotBoundaryFeature(events: events), initialState: .init())
    let selected = store.select(dependingOn: \.values) { $0 }
    let child = store.scope(
      state: \.child,
      action: CasePath<SnapshotBoundaryFeature.Action, Void>(
        embed: { _ in .append(4) }, extract: { if case .append = $0 { () } else { nil } }))
    let selectedBefore = selected.requireAlive()
    let childBefore = child.state
    withObservationTracking {
      _ = selected.requireAlive()
    } onChange: {
      events.record("selected")
    }
    withObservationTracking {
      _ = child.state
    } onChange: {
      events.record("child")
    }
    sendSnapshotAction(.other, to: store, animated: animated, events: events)
    sendSnapshotAction(.unchanged, to: store, animated: animated, events: events)
    #expect(!events.values.contains("selected") && !events.values.contains("child"))
    sendSnapshotAction(.append(4), to: store, animated: animated, events: events)
    #expect(events.values.filter { $0 == "selected" }.count == 1)
    #expect(events.values.filter { $0 == "child" }.count == 1)
    #expect(selectedBefore == [1, 2, 3] && childBefore.count == 0)
    #expect(selected.requireAlive() == [1, 2, 3, 4] && child.state.count == 1)
  }

  @Test(arguments: [false, true], [false, true])
  func willSetRegistrationPreservesChangedAndUnchangedDependencies(
    animated: Bool, changedDependency: Bool
  ) {
    let events = SnapshotBoundaryEvents()
    let store = Store(reducer: SnapshotBoundaryFeature(events: events), initialState: .init())
    let handles = SnapshotBoundaryHandles()
    withObservationTracking {
      _ = store.state
    } onChange: {
      MainActor.assumeIsolated {
        if changedDependency {
          handles.selection = store.select(dependingOn: \.values.count) {
            events.record("select.\($0)")
            return $0
          }
        } else {
          handles.selection = store.select(dependingOn: \.other) {
            events.record("select.\($0)")
            return $0
          }
        }
        handles.child = store.scope(
          state: \.child,
          action: CasePath<SnapshotBoundaryFeature.Action, Void>(
            embed: { _ in .append(4) }, extract: { if case .append = $0 { () } else { nil } }))
        #expect(handles.selection?.requireAlive() == (changedDependency ? 3 : 0))
        #expect(handles.child?.state.count == 0)
      }
    }
    sendSnapshotAction(.append(4), to: store, animated: animated, events: events)
    #expect(
      events.values.filter { $0.hasPrefix("select.") }
        == (changedDependency ? ["select.3", "select.4"] : ["select.0"]))
    #expect(handles.selection?.requireAlive() == (changedDependency ? 4 : 0))
    #expect(handles.child?.state.count == 1)
  }

  @Test(arguments: [false, true])
  func reentrantObservationQueuesAfterTheCurrentProjectionRefresh(animated: Bool) {
    let events = SnapshotBoundaryEvents()
    let store = Store(reducer: SnapshotBoundaryFeature(events: events), initialState: .init())
    let selected = store.select(dependingOn: \.values.count) { $0 }
    let handles = SnapshotBoundaryHandles()
    withObservationTracking {
      _ = store.state
    } onChange: {
      MainActor.assumeIsolated {
        events.record("root.\(store.state.values.count)")
      }
    }
    withObservationTracking {
      _ = selected.requireAlive()
    } onChange: {
      MainActor.assumeIsolated {
        events.record("selected.\(selected.requireAlive()).root.\(store.state.values.count)")
        // Register into the bucket whose callback is currently running.
        handles.selection = store.select(dependingOn: \.values.count) { $0 }
        store.send(.other)
      }
    }
    sendSnapshotAction(.append(4), to: store, animated: animated, events: events)
    let first = ["root.3", "reduce.append", "selected.3.root.4"]
    #expect(
      events.values
        == (animated
          ? ["animation.begin"] + first + ["animation.end", "reduce.other"]
          : first + ["reduce.other"]))
    #expect(store.state.other == 1)
    #expect(selected.requireAlive() == 4 && handles.selection?.requireAlive() == 4)
    store.send(.append(5))
    #expect(selected.requireAlive() == 5 && handles.selection?.requireAlive() == 5)
  }

  @Test(arguments: [false, true])
  func releasedAndLaterRegisteredSelectionsSeeCurrentValues(animated: Bool) {
    let events = SnapshotBoundaryEvents()
    let store = Store(reducer: SnapshotBoundaryFeature(events: events), initialState: .init())
    var released: SelectedStore<Int>? = store.select(dependingOn: \.values.count) { $0 }
    let handles = SnapshotBoundaryHandles()
    handles.weakSelection = released
    #expect(released?.requireAlive() == 3)
    released = nil
    #expect(handles.weakSelection == nil)
    sendSnapshotAction(.append(4), to: store, animated: animated, events: events)
    let later = store.select(dependingOn: \.values.count) { $0 }
    #expect(later.requireAlive() == 4)
    sendSnapshotAction(.append(5), to: store, animated: animated, events: events)
    #expect(later.requireAlive() == 5)
  }

  @Test(arguments: [false, true])
  func optionalNilIsARealSnapshotForDependencyComparison(animated: Bool) {
    let events = SnapshotBoundaryEvents()
    let reducer = Reduce<Int?, Int?, Never> { state, value in
      state = value
      return .none
    }
    let store = Store(reducer: reducer, initialState: nil)
    let selected = store.select(dependingOn: \.self) { value in
      events.record(value.map(String.init) ?? "nil")
      return value
    }
    func send(_ value: Int?) {
      if animated {
        store.enqueue(value, animation: .init(description: "optional snapshot") { $0() })
      } else {
        store.send(value)
      }
    }
    send(7)
    #expect(selected.requireAlive() == 7)
    send(nil)
    #expect(selected.requireAlive() == nil)
    send(nil)
    #expect(events.values == ["nil", "7", "nil"])
  }

  #if compiler(>=6.4)
    @available(macOS 27.0, iOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
    @Test(arguments: [false, true], [false, true])
    func didSetPrecedesProjectionRefresh(animated: Bool, observed: Bool) {
      let events = SnapshotBoundaryEvents()
      let store = Store(reducer: SnapshotBoundaryFeature(events: events), initialState: .init())
      let selected = observed ? store.select(dependingOn: \.values.count) { $0 } : nil
      if let selected {
        withObservationTracking {
          _ = selected.requireAlive()
        } onChange: {
          events.record("selected")
        }
      }
      withObservationTracking(options: [.willSet, .didSet]) {
        _ = store.state
      } onChange: { event in
        if event.kind == .willSet {
          MainActor.assumeIsolated { events.record("will.\(store.state.values.count)") }
        } else if event.kind == .didSet {
          MainActor.assumeIsolated { events.record("did.\(store.state.values.count)") }
          event.cancel()
        }
      }
      sendSnapshotAction(.append(4), to: store, animated: animated, events: events)
      let expected = ["will.3", "reduce.append", "did.4"] + (observed ? ["selected"] : [])
      #expect(
        events.values
          == (animated
            ? ["animation.begin"] + expected + ["animation.end"] : expected))
      #expect(selected?.requireAlive() == (observed ? 4 : nil))
    }

    @available(macOS 27.0, iOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
    @Test func didSetRegistrationDoesNotRecomputeAnUnchangedMemoizedSelection() {
      let events = SnapshotBoundaryEvents()
      let store = Store(reducer: SnapshotBoundaryFeature(events: events), initialState: .init())
      let handles = SnapshotBoundaryHandles()
      withObservationTracking(options: [.didSet]) {
        _ = store.state
      } onChange: { event in
        guard event.kind == .didSet else { return }
        MainActor.assumeIsolated {
          handles.selection = store.select(memoize: true) {
            events.record("select")
            return $0.values.count
          }
        }
        event.cancel()
      }
      store.send(.unchanged)
      #expect(handles.selection?.requireAlive() == 3)
      #expect(events.values == ["reduce.unchanged", "select"])
      store.send(.append(4))
      #expect(handles.selection?.requireAlive() == 4)
    }

    @available(macOS 27.0, iOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
    @Test(arguments: [false, true], [false, true])
    func didSetRegistrationPreservesSelectorCallsAndReturnedValues(
      memoize: Bool, changed: Bool
    ) {
      let events = SnapshotBoundaryEvents()
      let store = Store(reducer: SnapshotBoundaryFeature(events: events), initialState: .init())
      let handles = SnapshotBoundaryHandles()
      withObservationTracking(options: [.didSet]) {
        _ = store.state
      } onChange: { event in
        guard event.kind == .didSet else { return }
        MainActor.assumeIsolated {
          handles.selection = store.select(memoize: memoize) { _ in
            events.record("select")
            return events.values.filter { $0 == "select" }.count
          }
        }
        event.cancel()
      }
      store.send(changed ? .append(4) : .unchanged)
      let expected = memoize && !changed ? 1 : 2
      #expect(events.values.filter { $0 == "select" }.count == expected)
      #expect(handles.selection?.requireAlive() == expected)
    }
  #endif
}
