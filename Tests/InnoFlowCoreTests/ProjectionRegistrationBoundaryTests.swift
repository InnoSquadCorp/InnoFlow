import InnoFlowCore
import Testing
import os

@MainActor
private final class RegistrationBoundaryObserver: ProjectionObserver {
  var refreshes = 0
  var comparisons: [[Int]] = []

  func refreshFromParentStore() -> Bool {
    refreshes += 1
    return true
  }
}

@MainActor
private final class RegistrationBoundaryHolder {
  var store: Store<Reduce<Int, Bool, Never>>?
  var selection: SelectedStore<Int>?
}

private final class RegistrationBoundaryCounter: Sendable {
  private let storage = OSAllocatedUnfairLock(initialState: 0)
  func next() -> Int {
    storage.withLock {
      $0 += 1
      return $0
    }
  }
  var value: Int { storage.withLock { $0 } }
}

private enum RegistrationBoundaryKind: CaseIterable, Sendable {
  case always
  case dependency
  case dependencies
}

@Suite("Projection registration action boundaries")
@MainActor
struct ProjectionRegistrationBoundaryTests {
  @Test(arguments: RegistrationBoundaryKind.allCases, [false, true])
  fileprivate func latePackageRegistrationPreservesOldAndNewSnapshots(
    kind: RegistrationBoundaryKind, changed: Bool
  ) {
    for registerAfterMutation in [false, true] {
      for animated in [false, true] {
        let observer = RegistrationBoundaryObserver()
        let holder = RegistrationBoundaryHolder()
        let store = Store(
          reducer: Reduce<Int, Bool, Never> { state, changed in
            if changed && registerAfterMutation { state += 1 }
            MainActor.assumeIsolated {
              let hasChanged: (Int, Int) -> Bool = { old, new in
                MainActor.assumeIsolated { observer.comparisons.append([old, new]) }
                return old != new
              }
              let registration: ProjectionObserverRegistration<Int>
              switch kind {
              case .always:
                registration = .alwaysRefresh
              case .dependency:
                registration = .dependency(.keyPath(\Int.self), hasChanged: hasChanged)
              case .dependencies:
                registration = .dependencies([
                  .init(.keyPath(\Int.self), hasChanged: hasChanged),
                  .init(.keyPath(\Int.magnitude), hasChanged: hasChanged),
                ])
              }
              holder.store!.registerProjectionObserver(observer, registration: registration)
            }
            if changed && !registerAfterMutation { state += 1 }
            return .none
          },
          initialState: 0)
        holder.store = store
        if animated {
          store.enqueue(changed, animation: .init(description: "late registration") { $0() })
        } else {
          store.send(changed)
        }
        #expect(store.state == (changed ? 1 : 0))
        #expect(observer.refreshes == (kind == .always || changed ? 1 : 0))
        let comparisonCount = kind == .always ? 0 : (kind == .dependencies ? 2 : 1)
        #expect(
          observer.comparisons == Array(repeating: [0, changed ? 1 : 0], count: comparisonCount))
        #expect(store.scopedObserverRefreshCount == 1)
        holder.store = nil
      }
    }
  }

  @Test(arguments: [false, true], [false, true])
  func emptyDependencyPackCreatedDuringReductionKeepsItsAlwaysRefreshContract(
    changed: Bool, animated: Bool
  ) {
    let holder = RegistrationBoundaryHolder()
    let counter = RegistrationBoundaryCounter()
    let store = Store(
      reducer: Reduce<Int, Bool, Never> { state, changed in
        MainActor.assumeIsolated {
          // The public variadic overload accepts an empty dependency pack.
          // Its initial value does not read the root State getter.
          holder.selection = holder.store!.select { () -> Int in counter.next() }
        }
        if changed { state += 1 }
        return .none
      },
      initialState: 0)
    holder.store = store
    if animated {
      store.enqueue(changed, animation: .init(description: "empty dependency pack") { $0() })
    } else {
      store.send(changed)
    }
    #expect(counter.value == 2)
    #expect(holder.selection?.requireAlive() == 2)
    #expect(store.state == (changed ? 1 : 0))
    #expect(store.scopedObserverRefreshCount == 1)
    holder.store = nil
  }

  @Test(arguments: [0, 1])
  func lateDependencyNeedsThePreMutationValueEvenWhenFinalValuesMatch(initial: Int) {
    let observer = RegistrationBoundaryObserver()
    let holder = RegistrationBoundaryHolder()
    let store = Store(
      reducer: Reduce<Int, Bool, Never> { state, _ in
        state = 0
        MainActor.assumeIsolated {
          holder.store!.registerProjectionObserver(
            observer,
            registration: .dependency(.keyPath(\Int.self)) { old, new in
              MainActor.assumeIsolated { observer.comparisons.append([old, new]) }
              return old != new
            })
        }
        return .none
      },
      initialState: initial)
    holder.store = store
    store.send(false)
    #expect(store.state == 0)
    #expect(observer.comparisons == [[initial, 0]])
    #expect(observer.refreshes == initial)
    holder.store = nil
  }
}
