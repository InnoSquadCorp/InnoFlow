// MARK: - StoreScopeSelectionTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import InnoFlowSwiftUI
import Testing
import os

@testable import InnoFlowCore
@testable import InnoFlowTesting

// MARK: - Store Scope and Selection Tests

@Suite("Store Scope and Selection Tests", .serialized)
@MainActor
struct StoreScopeSelectionTests {
  @Test("Store initializes with explicit state")
  func storeInitialization() {
    let store = Store(reducer: CounterFeature(), initialState: .init(count: 10))
    #expect(store.count == 10)
  }

  @Test("Store processes synchronous actions")
  func storeSyncActions() {
    let store = Store(reducer: CounterFeature(), initialState: .init(count: 0))

    store.send(.increment)
    store.send(.increment)
    store.send(.decrement)

    #expect(store.count == 1)
  }

  @Test("ScopedStore reflects child state and forwards actions")
  func scopedStoreProjectionAndForwarding() {
    let store = Store(reducer: ScopedCounterFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child,
      action: ScopedCounterFeature.Action.selfCasePath
    )

    #expect(scoped.count == 0)
    scoped.send(.childIncrement)
    #expect(scoped.count == 1)
    #expect(store.state.child.count == 1)
  }

  @Test("Store.binding reads and writes bindable field")
  func bindingPositivePath() {
    let store = Store(reducer: BindingFeature(), initialState: .init())
    let binding = store.binding(\.$step, send: { .setStep($0) })

    #expect(binding.wrappedValue == 1)
    binding.wrappedValue = 5
    #expect(store.step == 5)
  }

  @Test("ScopedStore.binding reads and writes bindable child field")
  func scopedBindingPositivePath() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child,
      action: ScopedBindableChildFeature.Action.childCasePath
    )
    let binding = scoped.binding(\.$step, send: { .setStep($0) })

    #expect(scoped.step == 1)
    #expect(binding.wrappedValue == 1)

    binding.wrappedValue = 4

    #expect(scoped.step == 4)
    #expect(store.state.child.step == 4)
  }

  @Test("Plain dependency bundles inject reducer-side services without a bridge target")
  @MainActor
  func dependencyBundleFeatureLoadsService() async {
    let store = TestStore(
      reducer: DependencyBundleFeature(service: DependencyBundleService(value: "from-bundle"))
    )

    await store.send(.load)
    await store.receive(._loaded("from-bundle")) {
      $0.output = "from-bundle"
      $0.log = ["loaded from-bundle"]
    }
  }

  @Test("Store.preview creates preview stores with explicit and default state")
  @MainActor
  func storePreviewHelpers() {
    let explicit: Store<CounterFeature> = .preview(
      reducer: CounterFeature(),
      initialState: .init(count: 42)
    )
    let defaulted: Store<CounterFeature> = .preview(reducer: CounterFeature())

    #expect(explicit.count == 42)
    #expect(defaulted.count == 0)
  }

  @Test("Store collection scoping preserves order and routes child actions by id")
  func collectionScopingPreservesOrderAndRoutesActions() {
    let store = Store(reducer: ScopedCollectionFeature(), initialState: .init())
    let scopedTodos = store.scope(
      collection: \.todos,
      action: ScopedCollectionFeature.Action.todoActionPath
    )

    #expect(scopedTodos.map(\.title) == ["One", "Two", "Three"])
    #expect(scopedTodos.map(\.id) == store.state.todos.map(\.id))
    #expect(scopedTodos[1].isDone == false)

    let binding = scopedTodos[1].binding(\.$isDone, send: { .setDone($0) })
    binding.wrappedValue = true

    #expect(scopedTodos[1].isDone == true)
    #expect(store.state.todos[0].isDone == false)
    #expect(store.state.todos[1].isDone == true)
    #expect(store.state.todos[2].isDone == false)
  }

  @Test("Store scope(state:action:) accepts CasePath overload")
  func scopeStateCasePathOverload() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)

    #expect(scoped.step == 1)
    scoped.send(.setStep(6))
    #expect(store.state.child.step == 6)
  }

  @Test("ScopedStore ignores unrelated parent mutations when observing child state")
  func scopedStoreIgnoresUnrelatedParentMutations() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = scoped.step
      },
      onChange: {
        probe.recordChange()
      })

    store.send(.setUnrelated(1))
    try? await Task.sleep(for: .milliseconds(20))

    #expect(probe.count == 0)
    #expect(scoped.step == 1)
  }

  @Test("ScopedStore ignores repeated unrelated parent mutations when observing child state")
  func scopedStoreIgnoresRepeatedUnrelatedParentMutations() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = scoped.step
      },
      onChange: {
        probe.recordChange()
      })

    store.send(.setUnrelated(1))
    store.send(.setUnrelated(2))
    store.send(.setUnrelated(3))
    try? await Task.sleep(for: .milliseconds(20))

    #expect(probe.count == 0)
    #expect(scoped.step == 1)
  }

  @Test("ScopedStore invalidates when child snapshot changes")
  func scopedStoreInvalidatesOnChildMutation() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = scoped.step
      },
      onChange: {
        probe.recordChange()
      })

    store.send(.child(.setStep(7)))
    try? await Task.sleep(for: .milliseconds(20))

    #expect(probe.count == 1)
    #expect(scoped.step == 7)
  }

  @Test("ScopedStore.isAlive and optionalState are true/non-nil while parent is alive")
  func scopedStoreLifecycleAccessorsWhileAlive() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)

    #expect(scoped.isAlive == true)
    #expect(scoped.optionalState != nil)
    #expect(scoped.optionalState?.step == 1)
  }

  @Test("ScopedStore.optionalState surfaces released parent as nil without asserting")
  func scopedStoreOptionalStateAfterParentRelease() {
    let scoped:
      ScopedStore<
        ScopedBindableChildFeature,
        ScopedBindableChildFeature.Child,
        ScopedBindableChildFeature.ChildAction
      > = {
        let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
        return store.scope(
          state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)
      }()

    #expect(scoped.isAlive == false)
    #expect(scoped.optionalState == nil)
  }

  @Test("ScopedStore does not retain its parent Store")
  func scopedStoreDoesNotRetainParentStore() async {
    typealias ChildStore =
      ScopedStore<
        ScopedBindableChildFeature,
        ScopedBindableChildFeature.Child,
        ScopedBindableChildFeature.ChildAction
      >

    var scoped: ChildStore?
    weak var weakScoped: ChildStore?
    weak var weakStore: Store<ScopedBindableChildFeature>?

    do {
      var store: Store<ScopedBindableChildFeature>? = Store(
        reducer: ScopedBindableChildFeature(),
        initialState: .init()
      )
      weakStore = store
      scoped = store?.scope(
        state: \.child,
        action: ScopedBindableChildFeature.Action.childCasePath
      )
      weakScoped = scoped
      store = nil
    }

    await waitUntil {
      weakStore == nil
    }

    #expect(weakStore == nil)
    #expect(scoped?.optionalState == nil)

    scoped = nil
    await waitUntil {
      weakScoped == nil
    }

    #expect(weakScoped == nil)
  }

  @Test("SelectedStore.isAlive and optionalValue are true/non-nil while parent is alive")
  func selectedStoreLifecycleAccessorsWhileAlive() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let selected = store.select(\.child.step)

    #expect(selected.isAlive == true)
    #expect(selected.optionalValue == 1)
  }

  @Test("SelectedStore.optionalValue surfaces released parent as nil without asserting")
  func selectedStoreOptionalValueAfterParentRelease() {
    let selected: SelectedStore<Int> = {
      let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
      return store.select(\.child.step)
    }()

    #expect(selected.isAlive == false)
    #expect(selected.optionalValue == nil)
  }

  @Test("SelectedStore does not retain its parent Store")
  func selectedStoreDoesNotRetainParentStore() async {
    var selected: SelectedStore<Int>?
    weak var weakSelected: SelectedStore<Int>?
    weak var weakStore: Store<ScopedBindableChildFeature>?

    do {
      var store: Store<ScopedBindableChildFeature>? = Store(
        reducer: ScopedBindableChildFeature(),
        initialState: .init()
      )
      weakStore = store
      selected = store?.select(\.child.step)
      weakSelected = selected
      store = nil
    }

    await waitUntil {
      weakStore == nil
    }

    #expect(weakStore == nil)
    #expect(selected?.optionalValue == nil)

    selected = nil
    await waitUntil {
      weakSelected == nil
    }

    #expect(weakSelected == nil)
  }

  @Test("Store.select(dependingOnAll:) tracks an arbitrary number of explicit dependency slices")
  func selectedStoreDependingOnAllVariadic() {
    struct VariadicState: Equatable, Sendable, DefaultInitializable {
      var a: Int = 1
      var b: Int = 2
      var c: Int = 3
      var d: Int = 4
      var e: Int = 5
      var f: Int = 6
      var g: Int = 7
      var h: Int = 8
      var untracked: Int = 0
    }

    enum VariadicAction: Equatable, Sendable {
      case bumpG
      case bumpUntracked
    }

    struct VariadicReducer: Reducer {
      typealias State = VariadicState
      typealias Action = VariadicAction

      func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
        switch action {
        case .bumpG:
          state.g &+= 1
          return .none
        case .bumpUntracked:
          state.untracked &+= 1
          return .none
        }
      }
    }

    let store = Store(reducer: VariadicReducer(), initialState: .init())
    let selected = store.select(
      dependingOnAll:
        \VariadicState.a,
      \VariadicState.b,
      \VariadicState.c,
      \VariadicState.d,
      \VariadicState.e,
      \VariadicState.f,
      \VariadicState.g,
      \VariadicState.h
    ) { (a: Int, b: Int, c: Int, d: Int, e: Int, f: Int, g: Int, h: Int) -> Int in
      a + b + c + d + e + f + g + h
    }

    let baselineSum = 36
    #expect(selected.requireAlive() == baselineSum)

    let initialStats = store.projectionObserverStats

    store.send(.bumpUntracked)
    let afterUntrackedStats = store.projectionObserverStats

    #expect(afterUntrackedStats.refreshedObservers == initialStats.refreshedObservers)
    #expect(afterUntrackedStats.evaluatedObservers == initialStats.evaluatedObservers)
    #expect(selected.requireAlive() == baselineSum)

    store.send(.bumpG)
    #expect(selected.requireAlive() == baselineSum + 1)
  }

  @Test("Store.select(dependingOnAll:) preserves cached identity without eager recomputation")
  func selectedStoreDependingOnAllPreservesIdentityWithoutEagerInitialValue() {
    struct VariadicState: Equatable, Sendable, DefaultInitializable {
      var a: Int = 1
      var b: Int = 2
      var c: Int = 3
      var d: Int = 4
      var e: Int = 5
      var f: Int = 6
      var g: Int = 7
    }

    enum VariadicAction: Equatable, Sendable {
      case noop
    }

    struct VariadicReducer: Reducer {
      typealias State = VariadicState
      typealias Action = VariadicAction

      func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
        .none
      }
    }

    let store = Store(reducer: VariadicReducer(), initialState: .init())
    let probe = SelectionTransformProbe()
    let callsiteLine: UInt = #line
    let first = store.select(
      dependingOnAll:
        \VariadicState.a,
      \VariadicState.b,
      \VariadicState.c,
      \VariadicState.d,
      \VariadicState.e,
      \VariadicState.f,
      \VariadicState.g,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    ) { (a: Int, b: Int, c: Int, d: Int, e: Int, f: Int, g: Int) -> Int in
      probe.record()
      return a + b + c + d + e + f + g
    }
    let second = store.select(
      dependingOnAll:
        \VariadicState.a,
      \VariadicState.b,
      \VariadicState.c,
      \VariadicState.d,
      \VariadicState.e,
      \VariadicState.f,
      \VariadicState.g,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    ) { (a: Int, b: Int, c: Int, d: Int, e: Int, f: Int, g: Int) -> Int in
      probe.record()
      return a + b + c + d + e + f + g
    }

    #expect(first === second)
    #expect(first.requireAlive() == 28)
    #expect(probe.count == 1)
  }

  @Test(
    "Store.select(memoize: true) skips selector invocation when parent state is unchanged"
  )
  func selectedStoreClosureMemoizeSkipsSelectorOnUnchangedState() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let probe = SelectionTransformProbe()

    let memoized = store.select(memoize: true) { state -> Int in
      probe.record()
      return state.child.step + state.unrelated
    }

    #expect(memoized.requireAlive() == 1)
    let baseline = probe.count

    store.send(.setUnrelated(0))
    #expect(probe.count == baseline)

    store.send(.setUnrelated(7))
    #expect(probe.count > baseline)
    #expect(memoized.requireAlive() == 8)
  }

  @Test(
    "Store.select(memoize: false) preserves always-refresh selector semantics"
  )
  func selectedStoreClosureMemoizeFalseAlwaysRefreshes() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let probe = SelectionTransformProbe()

    let alwaysRefresh = store.select(memoize: false) { state -> Int in
      probe.record()
      return state.child.step
    }

    #expect(alwaysRefresh.requireAlive() == 1)
    let baseline = probe.count

    store.send(.setUnrelated(0))
    #expect(probe.count > baseline)
  }

  @Test("Store.select preserves SelectedStore identity across repeated calls")
  func selectedStoreCachingPreservesIdentity() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let callsiteLine: UInt = #line
    let first = store.select(\.child, fileID: #fileID, line: callsiteLine, column: 0)
    let second = store.select(\.child, fileID: #fileID, line: callsiteLine, column: 0)

    #expect(first === second)
    #expect(first.step == 1)
  }

  @Test("Store.select cache identity includes the selected key path")
  func selectedStoreCacheIdentityIncludesSelectedKeyPath() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let callsiteLine: UInt = #line
    let first = store.select(
      \.child.step,
      fileID: #fileID,
      line: callsiteLine,
      column: 1
    )
    let second = store.select(
      \.unrelated,
      fileID: #fileID,
      line: callsiteLine,
      column: 1
    )

    #expect(first.requireAlive() == 1)
    #expect(second.requireAlive() == 0)
  }

  @Test("Store.select cache identity includes the callsite column")
  func selectedStoreCacheIdentityIncludesColumn() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let callsiteLine: UInt = #line
    let first = store.select(
      \.child.step,
      fileID: #fileID,
      line: callsiteLine,
      column: 1
    )
    let second = store.select(
      \.child.step,
      fileID: #fileID,
      line: callsiteLine,
      column: 2
    )

    #expect(first !== second)
    #expect(first.requireAlive() == second.requireAlive())
  }

  @Test("Store.select(dependingOn:) preserves SelectedStore identity across repeated calls")
  func selectedStoreDependingOnPreservesIdentity() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let callsiteLine: UInt = #line
    let first = store.select(
      dependingOn: \.child.title,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    ) { title in
      title.uppercased()
    }
    let second = store.select(
      dependingOn: \.child.title,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    ) { title in
      title.uppercased()
    }

    #expect(first === second)
    #expect(first.requireAlive() == "CHILD")
  }

  @Test("Store.select(dependingOn:) cache identity includes dependency key paths")
  func selectedStoreDependingOnCacheIdentityIncludesDependencies() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let callsiteLine: UInt = #line
    let first = store.select(
      dependingOn: \.child.step,
      fileID: #fileID,
      line: callsiteLine,
      column: 1
    ) { $0 }
    let second = store.select(
      dependingOn: \.unrelated,
      fileID: #fileID,
      line: callsiteLine,
      column: 1
    ) { $0 }

    #expect(first.requireAlive() == 1)
    #expect(second.requireAlive() == 0)
  }

  @Test(
    "Store.select(dependingOnAll: ..., ...) preserves SelectedStore identity across repeated calls")
  func selectedStoreTwoFieldDependingOnPreservesIdentity() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let callsiteLine: UInt = #line
    let first = store.select(
      dependingOnAll: \.child.step, \.child.title,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    ) { step, title in
      "\(title)-\(step)"
    }
    let second = store.select(
      dependingOnAll: \.child.step, \.child.title,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    ) { step, title in
      "\(title)-\(step)"
    }

    #expect(first === second)
    #expect(first.requireAlive() == "Child-1")
  }

  @Test("Store.select(dependingOnAll: ..., ...) invalidates when either dependency changes")
  func selectedStoreTwoFieldDependingOnInvalidatesForAnyDependencyMutation() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let selected = store.select(dependingOnAll: \.child.step, \.child.title) { step, title in
      "\(title)-\(step)"
    }
    let initial = store.projectionObserverStats

    store.send(.setUnrelated(1))
    try? await Task.sleep(for: .milliseconds(20))
    let afterUnrelated = store.projectionObserverStats
    #expect(afterUnrelated.evaluatedObservers == initial.evaluatedObservers)
    #expect(afterUnrelated.refreshedObservers == initial.refreshedObservers)
    #expect(selected.requireAlive() == "Child-1")

    store.send(.child(.setStep(4)))
    try? await Task.sleep(for: .milliseconds(20))
    let afterStep = store.projectionObserverStats
    #expect(afterStep.evaluatedObservers == afterUnrelated.evaluatedObservers + 1)
    #expect(afterStep.refreshedObservers == afterUnrelated.refreshedObservers + 1)
    #expect(selected.requireAlive() == "Child-4")

    store.send(.child(.setTitle("Updated")))
    try? await Task.sleep(for: .milliseconds(20))
    let afterTitle = store.projectionObserverStats
    #expect(afterTitle.evaluatedObservers == afterStep.evaluatedObservers + 1)
    #expect(afterTitle.refreshedObservers == afterStep.refreshedObservers + 1)
    #expect(selected.requireAlive() == "Updated-4")
  }

  @Test("Store.select(dependingOnAll: ..., ..., ...) tracks three explicit dependency slices")
  func selectedStoreThreeFieldDependingOnTracksExplicitSlices() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let selected = store.select(
      dependingOnAll: \.child.step, \.child.title, \.unrelated
    ) { step, title, unrelated in
      "\(title)-\(step)-\(unrelated)"
    }
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = selected.requireAlive()
      },
      onChange: {
        probe.recordChange()
      })

    store.send(.child(.setNote("Still ignored")))
    try? await Task.sleep(for: .milliseconds(20))
    #expect(probe.count == 0)
    #expect(selected.requireAlive() == "Child-1-0")

    store.send(.setUnrelated(2))
    try? await Task.sleep(for: .milliseconds(20))
    #expect(probe.count == 1)
    #expect(selected.requireAlive() == "Child-1-2")
  }

  @Test(
    "Store.select(dependingOnAll: ..., ..., ..., ...) preserves SelectedStore identity across repeated calls"
  )
  func selectedStoreFourFieldDependingOnPreservesIdentity() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let callsiteLine: UInt = #line
    let first = store.select(
      dependingOnAll: \.child.step, \.child.title, \.child.note, \.child.priority,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    ) { step, title, note, priority in
      "\(title)-\(step)-\(note)-\(priority)"
    }
    let second = store.select(
      dependingOnAll: \.child.step, \.child.title, \.child.note, \.child.priority,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    ) { step, title, note, priority in
      "\(title)-\(step)-\(note)-\(priority)"
    }

    #expect(first === second)
    #expect(first.requireAlive() == "Child-1-Ready-0")
  }

  @Test(
    "Store.select(dependingOnAll: ..., ..., ..., ..., ...) invalidates only for tracked mutations"
  )
  func selectedStoreFiveFieldDependingOnInvalidatesForTrackedMutations() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let selected = store.select(
      dependingOnAll: \.child.step, \.child.title, \.child.note, \.child.priority, \.child.isEnabled
    ) { step, title, note, priority, isEnabled in
      "\(title)-\(step)-\(note)-\(priority)-\(isEnabled)"
    }
    let initial = store.projectionObserverStats

    store.send(.setUnrelated(1))
    await waitForProjectionRefreshPass(store, after: initial)
    let afterUnrelated = store.projectionObserverStats
    #expect(afterUnrelated.evaluatedObservers == initial.evaluatedObservers)
    #expect(afterUnrelated.refreshedObservers == initial.refreshedObservers)
    #expect(selected.requireAlive() == "Child-1-Ready-0-true")

    store.send(.child(.setPriority(2)))
    await waitForProjectionObserverStats(store) { stats in
      stats.refreshPassCount > afterUnrelated.refreshPassCount
        && stats.evaluatedObservers >= afterUnrelated.evaluatedObservers + 1
        && stats.refreshedObservers >= afterUnrelated.refreshedObservers + 1
    }
    let afterPriority = store.projectionObserverStats
    #expect(afterPriority.evaluatedObservers == afterUnrelated.evaluatedObservers + 1)
    #expect(afterPriority.refreshedObservers == afterUnrelated.refreshedObservers + 1)
    #expect(selected.requireAlive() == "Child-1-Ready-2-true")

    store.send(.child(.setEnabled(false)))
    await waitForProjectionObserverStats(store) { stats in
      stats.refreshPassCount > afterPriority.refreshPassCount
        && stats.evaluatedObservers >= afterPriority.evaluatedObservers + 1
        && stats.refreshedObservers >= afterPriority.refreshedObservers + 1
    }
    let afterEnabled = store.projectionObserverStats
    #expect(afterEnabled.evaluatedObservers == afterPriority.evaluatedObservers + 1)
    #expect(afterEnabled.refreshedObservers == afterPriority.refreshedObservers + 1)
    #expect(selected.requireAlive() == "Child-1-Ready-2-false")
  }

  @Test("Store.select(dependingOnAll: ..., ..., ..., ..., ..., ...) tracks six explicit slices")
  func selectedStoreSixFieldDependingOnTracksExplicitSlices() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let selected = store.select(
      dependingOnAll:
        \.child.step,
      \.child.title,
      \.child.note,
      \.child.priority,
      \.child.isEnabled,
      \.child.version

    ) { step, title, note, priority, isEnabled, version in
      "\(title)-\(step)-\(note)-\(priority)-\(isEnabled)-\(version)"
    }
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = selected.requireAlive()
      },
      onChange: {
        probe.recordChange()
      })

    let initial = store.projectionObserverStats
    store.send(.setUnrelated(2))
    await waitForProjectionRefreshPass(store, after: initial)
    #expect(probe.count == 0)
    #expect(selected.requireAlive() == "Child-1-Ready-0-true-1")

    store.send(.child(.setVersion(5)))
    await waitUntil {
      probe.count == 1 && selected.requireAlive() == "Child-1-Ready-0-true-5"
    }
    #expect(probe.count == 1)
    #expect(selected.requireAlive() == "Child-1-Ready-0-true-5")
  }

  @Test("Store.select ignores parent mutations when the selected value is unchanged")
  func selectedStoreIgnoresUnchangedParentSelection() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let selected = store.select(\.child)
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = selected.step
      },
      onChange: {
        probe.recordChange()
      })

    store.send(.setUnrelated(1))
    try? await Task.sleep(for: .milliseconds(20))

    #expect(probe.count == 0)
    #expect(selected.step == 1)
  }

  @Test("Store.select invalidates when the selected value changes")
  func selectedStoreInvalidatesOnSelectedMutation() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let selected = store.select(\.child)
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = selected.step
      },
      onChange: {
        probe.recordChange()
      })

    store.send(.child(.setStep(9)))
    try? await Task.sleep(for: .milliseconds(20))

    #expect(probe.count == 1)
    #expect(selected.step == 9)
  }

  @Test("Store.select(dependingOn:) ignores mutations outside the dependency slice")
  func selectedStoreDependingOnIgnoresMutationsOutsideDependency() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let selected = store.select(dependingOn: \.child.title) { title in
      title.uppercased()
    }
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = selected.requireAlive()
      },
      onChange: {
        probe.recordChange()
      })

    store.send(.setUnrelated(1))
    try? await Task.sleep(for: .milliseconds(20))
    store.send(.child(.setStep(8)))
    try? await Task.sleep(for: .milliseconds(20))

    #expect(probe.count == 0)
    #expect(selected.requireAlive() == "CHILD")
  }

  @Test("Store.select(dependingOn:) invalidates when the dependency slice changes")
  func selectedStoreDependingOnInvalidatesOnDependencyMutation() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let selected = store.select(dependingOn: \.child.title) { title in
      title.uppercased()
    }
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = selected.requireAlive()
      },
      onChange: {
        probe.recordChange()
      })

    store.send(.child(.setTitle("Updated")))
    try? await Task.sleep(for: .milliseconds(20))

    #expect(probe.count == 1)
    #expect(selected.requireAlive() == "UPDATED")
  }

  @Test("ScopedStore.select preserves SelectedStore identity across repeated calls")
  func scopedSelectedStoreCachingPreservesIdentity() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)
    let callsiteLine: UInt = #line
    let first = scoped.select(\.title, fileID: #fileID, line: callsiteLine, column: 0)
    let second = scoped.select(\.title, fileID: #fileID, line: callsiteLine, column: 0)

    #expect(first === second)
    #expect(first.requireAlive() == "Child")
  }

  @Test("ScopedStore.select cache identity includes the selected key path")
  func scopedSelectedStoreCacheIdentityIncludesSelectedKeyPath() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)
    let callsiteLine: UInt = #line
    let first = scoped.select(
      \.step,
      fileID: #fileID,
      line: callsiteLine,
      column: 1
    )
    let second = scoped.select(
      \.priority,
      fileID: #fileID,
      line: callsiteLine,
      column: 1
    )

    #expect(first.requireAlive() == 1)
    #expect(second.requireAlive() == 0)
  }

  @Test("ScopedStore.select(dependingOn:) preserves SelectedStore identity across repeated calls")
  func scopedSelectedStoreDependingOnPreservesIdentity() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)
    let callsiteLine: UInt = #line
    let first = scoped.select(
      dependingOn: \.title,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    ) { title in
      title.uppercased()
    }
    let second = scoped.select(
      dependingOn: \.title,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    ) { title in
      title.uppercased()
    }

    #expect(first === second)
    #expect(first.requireAlive() == "CHILD")
  }

  @Test("ScopedStore.select(dependingOn:) cache identity includes dependency key paths")
  func scopedSelectedStoreDependingOnCacheIdentityIncludesDependencies() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)
    let callsiteLine: UInt = #line
    let first = scoped.select(
      dependingOn: \.step,
      fileID: #fileID,
      line: callsiteLine,
      column: 1
    ) { $0 }
    let second = scoped.select(
      dependingOn: \.priority,
      fileID: #fileID,
      line: callsiteLine,
      column: 1
    ) { $0 }

    #expect(first.requireAlive() == 1)
    #expect(second.requireAlive() == 0)
  }

  @Test(
    "ScopedStore.select(dependingOnAll: ..., ...) preserves SelectedStore identity across repeated calls"
  )
  func scopedSelectedStoreTwoFieldDependingOnPreservesIdentity() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)
    let callsiteLine: UInt = #line
    let first = scoped.select(
      dependingOnAll: \.step, \.title,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    ) { step, title in
      "\(title)-\(step)"
    }
    let second = scoped.select(
      dependingOnAll: \.step, \.title,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    ) { step, title in
      "\(title)-\(step)"
    }

    #expect(first === second)
    #expect(first.requireAlive() == "Child-1")
  }

  @Test("ScopedStore.select ignores child mutations when the derived value is unchanged")
  func scopedSelectedStoreIgnoresUnchangedDerivedValue() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)
    let selected = scoped.select(\.title)
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = selected.requireAlive()
      },
      onChange: {
        probe.recordChange()
      })

    store.send(.child(.setStep(6)))
    try? await Task.sleep(for: .milliseconds(20))

    #expect(probe.count == 0)
    #expect(selected.requireAlive() == "Child")
  }

  @Test("ScopedStore.select(dependingOn:) ignores mutations outside the dependency slice")
  func scopedSelectedStoreDependingOnIgnoresMutationsOutsideDependency() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)
    let selected = scoped.select(dependingOn: \.title) { title in
      title.uppercased()
    }
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = selected.requireAlive()
      },
      onChange: {
        probe.recordChange()
      })

    store.send(.setUnrelated(1))
    try? await Task.sleep(for: .milliseconds(20))
    store.send(.child(.setStep(6)))
    try? await Task.sleep(for: .milliseconds(20))

    #expect(probe.count == 0)
    #expect(selected.requireAlive() == "CHILD")
  }

  @Test("ScopedStore.select(dependingOn:) invalidates when the dependency slice changes")
  func scopedSelectedStoreDependingOnInvalidatesOnDependencyMutation() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)
    let selected = scoped.select(dependingOn: \.title) { title in
      title.uppercased()
    }
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = selected.requireAlive()
      },
      onChange: {
        probe.recordChange()
      })

    store.send(.child(.setTitle("Ready")))
    try? await Task.sleep(for: .milliseconds(20))

    #expect(probe.count == 1)
    #expect(selected.requireAlive() == "READY")
  }

  @Test("ScopedStore.select(dependingOnAll: ..., ..., ...) tracks three explicit dependency slices")
  func scopedSelectedStoreThreeFieldDependingOnTracksExplicitSlices() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)
    let selected = scoped.select(dependingOnAll: \.step, \.title, \.note) { step, title, note in
      "\(title)-\(step)-\(note)"
    }
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = selected.requireAlive()
      },
      onChange: {
        probe.recordChange()
      })

    store.send(.setUnrelated(1))
    try? await Task.sleep(for: .milliseconds(20))
    #expect(probe.count == 0)
    #expect(selected.requireAlive() == "Child-1-Ready")

    store.send(.child(.setNote("Updated")))
    try? await Task.sleep(for: .milliseconds(20))
    #expect(probe.count == 1)
    #expect(selected.requireAlive() == "Child-1-Updated")
  }

  @Test(
    "ScopedStore.select(dependingOnAll: ..., ..., ..., ...) preserves SelectedStore identity across repeated calls"
  )
  func scopedSelectedStoreFourFieldDependingOnPreservesIdentity() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)
    let callsiteLine: UInt = #line
    let first = scoped.select(
      dependingOnAll: \.step, \.title, \.note, \.priority,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    ) { step, title, note, priority in
      "\(title)-\(step)-\(note)-\(priority)"
    }
    let second = scoped.select(
      dependingOnAll: \.step, \.title, \.note, \.priority,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    ) { step, title, note, priority in
      "\(title)-\(step)-\(note)-\(priority)"
    }

    #expect(first === second)
    #expect(first.requireAlive() == "Child-1-Ready-0")
  }

  @Test(
    "ScopedStore.select(dependingOnAll: ..., ..., ..., ..., ...) ignores parent mutations outside tracked slices"
  )
  func scopedSelectedStoreFiveFieldDependingOnIgnoresNonDependencies() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)
    let selected = scoped.select(
      dependingOnAll: \.step, \.title, \.note, \.priority, \.isEnabled
    ) { step, title, note, priority, isEnabled in
      "\(title)-\(step)-\(note)-\(priority)-\(isEnabled)"
    }
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = selected.requireAlive()
      },
      onChange: {
        probe.recordChange()
      })

    let initial = store.projectionObserverStats
    store.send(.setUnrelated(1))
    await waitForProjectionRefreshPass(store, after: initial)
    #expect(probe.count == 0)
    #expect(selected.requireAlive() == "Child-1-Ready-0-true")

    store.send(.child(.setEnabled(false)))
    await waitUntil {
      probe.count == 1 && selected.requireAlive() == "Child-1-Ready-0-false"
    }
    #expect(probe.count == 1)
    #expect(selected.requireAlive() == "Child-1-Ready-0-false")
  }

  @Test(
    "ScopedStore.select(dependingOnAll: ..., ..., ..., ..., ..., ...) tracks six explicit slices"
  )
  func scopedSelectedStoreSixFieldDependingOnTracksExplicitSlices() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)
    let selected = scoped.select(
      dependingOnAll: \.step, \.title, \.note, \.priority, \.isEnabled, \.version
    ) { step, title, note, priority, isEnabled, version in
      "\(title)-\(step)-\(note)-\(priority)-\(isEnabled)-\(version)"
    }
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = selected.requireAlive()
      },
      onChange: {
        probe.recordChange()
      })

    store.send(.child(.setNote("Updated")))
    await waitUntil {
      probe.count == 1 && selected.requireAlive() == "Child-1-Updated-0-true-1"
    }
    #expect(probe.count == 1)
    #expect(selected.requireAlive() == "Child-1-Updated-0-true-1")

    let afterTrackedMutation = store.projectionObserverStats
    store.send(.setUnrelated(9))
    await waitForProjectionRefreshPass(store, after: afterTrackedMutation)
    #expect(probe.count == 1)
  }

  @Test("ScopedStore.select(dependingOnAll:) tracks an arbitrary number of child slices")
  func scopedSelectedStoreDependingOnAllVariadic() async {
    struct VariadicParentFeature: Reducer {
      struct Child: Equatable, Sendable {
        var a = 1
        var b = 2
        var c = 3
        var d = 4
        var e = 5
        var f = 6
        var g = 7
        var h = 8
      }

      struct State: Equatable, Sendable, DefaultInitializable {
        var child = Child()
        var unrelated = 0
      }

      enum Action: Equatable, Sendable {
        case child(ChildAction)
        case bumpUnrelated

        static let childCasePath = CasePath<Self, ChildAction>(
          embed: { .child($0) },
          extract: {
            guard case .child(let action) = $0 else { return nil }
            return action
          }
        )
      }

      enum ChildAction: Equatable, Sendable {
        case bumpG
      }

      func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
        switch action {
        case .child(.bumpG):
          state.child.g &+= 1
          return .none
        case .bumpUnrelated:
          state.unrelated &+= 1
          return .none
        }
      }
    }

    let store = Store(reducer: VariadicParentFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child,
      action: VariadicParentFeature.Action.childCasePath
    )
    let selected = scoped.select(
      dependingOnAll:
        \VariadicParentFeature.Child.a,
      \VariadicParentFeature.Child.b,
      \VariadicParentFeature.Child.c,
      \VariadicParentFeature.Child.d,
      \VariadicParentFeature.Child.e,
      \VariadicParentFeature.Child.f,
      \VariadicParentFeature.Child.g,
      \VariadicParentFeature.Child.h
    ) { (a: Int, b: Int, c: Int, d: Int, e: Int, f: Int, g: Int, h: Int) -> Int in
      a + b + c + d + e + f + g + h
    }
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = selected.requireAlive()
      },
      onChange: {
        probe.recordChange()
      })

    let baselineSum = 36
    #expect(selected.requireAlive() == baselineSum)

    let initialStats = store.projectionObserverStats
    store.send(.bumpUnrelated)
    await waitForProjectionRefreshPass(store, after: initialStats)
    #expect(probe.count == 0)
    #expect(selected.requireAlive() == baselineSum)

    scoped.send(.bumpG)
    await waitUntil {
      probe.count == 1 && selected.requireAlive() == baselineSum + 1
    }
    #expect(probe.count == 1)
    #expect(selected.requireAlive() == baselineSum + 1)
  }

  @Test("ScopedStore.select(dependingOnAll:) preserves cached identity without eager recomputation")
  func scopedSelectedStoreDependingOnAllPreservesIdentityWithoutEagerInitialValue() {
    struct VariadicParentFeature: Reducer {
      struct Child: Equatable, Sendable {
        var a = 1
        var b = 2
        var c = 3
        var d = 4
        var e = 5
        var f = 6
        var g = 7
      }

      struct State: Equatable, Sendable, DefaultInitializable {
        var child = Child()
      }

      enum Action: Equatable, Sendable {
        case child(ChildAction)

        static let childCasePath = CasePath<Self, ChildAction>(
          embed: { .child($0) },
          extract: {
            guard case .child(let action) = $0 else { return nil }
            return action
          }
        )
      }

      enum ChildAction: Equatable, Sendable {
        case noop
      }

      func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
        .none
      }
    }

    let store = Store(reducer: VariadicParentFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child,
      action: VariadicParentFeature.Action.childCasePath
    )
    let probe = SelectionTransformProbe()
    let callsiteLine: UInt = #line
    let first = scoped.select(
      dependingOnAll:
        \VariadicParentFeature.Child.a,
      \VariadicParentFeature.Child.b,
      \VariadicParentFeature.Child.c,
      \VariadicParentFeature.Child.d,
      \VariadicParentFeature.Child.e,
      \VariadicParentFeature.Child.f,
      \VariadicParentFeature.Child.g,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    ) { (a: Int, b: Int, c: Int, d: Int, e: Int, f: Int, g: Int) -> Int in
      probe.record()
      return a + b + c + d + e + f + g
    }
    let second = scoped.select(
      dependingOnAll:
        \VariadicParentFeature.Child.a,
      \VariadicParentFeature.Child.b,
      \VariadicParentFeature.Child.c,
      \VariadicParentFeature.Child.d,
      \VariadicParentFeature.Child.e,
      \VariadicParentFeature.Child.f,
      \VariadicParentFeature.Child.g,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    ) { (a: Int, b: Int, c: Int, d: Int, e: Int, f: Int, g: Int) -> Int in
      probe.record()
      return a + b + c + d + e + f + g
    }

    #expect(first === second)
    #expect(first.requireAlive() == 28)
    #expect(probe.count == 1)
  }

  @Test("Collection-scoped stores preserve identity across repeated calls")
  func collectionScopeCachingPreservesIdentity() {
    let store = Store(reducer: ScopedCollectionFeature(), initialState: .init())
    let callsiteLine: UInt = #line
    let first = store.scope(
      collection: \.todos,
      action: ScopedCollectionFeature.Action.todoActionPath,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    )
    let second = store.scope(
      collection: \.todos,
      action: ScopedCollectionFeature.Action.todoActionPath,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    )

    #expect(first.count == second.count)
    for index in first.indices {
      #expect(first[index] === second[index])
    }
  }

  @Test("Collection-scoped stores do not retain their parent Store")
  func collectionScopeCachingDoesNotRetainParentStore() async {
    typealias RowStore =
      ScopedStore<
        ScopedCollectionFeature,
        ScopedCollectionFeature.Todo,
        ScopedCollectionFeature.TodoAction
      >

    var row: RowStore?
    weak var weakRow: RowStore?
    weak var weakStore: Store<ScopedCollectionFeature>?

    do {
      var store: Store<ScopedCollectionFeature>? = Store(
        reducer: ScopedCollectionFeature(),
        initialState: .init()
      )
      weakStore = store
      row =
        store?.scope(
          collection: \.todos,
          action: ScopedCollectionFeature.Action.todoActionPath
        )[0]
      weakRow = row
      store = nil
    }

    await waitUntil {
      weakStore == nil
    }

    #expect(weakStore == nil)
    #expect(row?.optionalState == nil)

    row = nil
    await waitUntil {
      weakRow == nil
    }

    #expect(weakRow == nil)
  }

  @Test("Collection-scoped stores preserve identity across reorder and prune removed ids")
  func collectionScopeCachingTracksElementsByID() throws {
    let store = Store(reducer: ScopedCollectionFeature(), initialState: .init())
    let callsiteLine: UInt = #line
    let initial = store.scope(
      collection: \.todos,
      action: ScopedCollectionFeature.Action.todoActionPath,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    )
    let initialByID = Dictionary(uniqueKeysWithValues: initial.map { ($0.id, $0) })

    store.send(.moveLastToFront)
    let reordered = store.scope(
      collection: \.todos,
      action: ScopedCollectionFeature.Action.todoActionPath,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    )

    #expect(reordered.map(\.id) == store.state.todos.map(\.id))
    for scoped in reordered {
      #expect(scoped === initialByID[scoped.id])
    }

    let newID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    store.send(.appendTodo(.init(id: newID, title: "Four")))
    let appended = store.scope(
      collection: \.todos,
      action: ScopedCollectionFeature.Action.todoActionPath,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    )
    let appendedNewStore = try #require(appended.first(where: { $0.id == newID }))
    for scoped in appended where scoped.id != newID {
      #expect(scoped === initialByID[scoped.id])
    }
    #expect(!initial.contains(where: { $0 === appendedNewStore }))

    let removedID = reordered[0].id
    store.send(.removeTodo(removedID))
    let removed = store.scope(
      collection: \.todos,
      action: ScopedCollectionFeature.Action.todoActionPath,
      fileID: #fileID,
      line: callsiteLine,
      column: 0
    )

    #expect(removed.contains(where: { $0.id == removedID }) == false)
    for scoped in removed where scoped.id != newID {
      #expect(scoped === initialByID[scoped.id])
    }
    #expect(removed.first(where: { $0.id == newID }) === appendedNewStore)
  }

  @Test("Store scope(collection:action:) accepts CollectionActionPath overload")
  func scopeCollectionActionPathOverload() {
    let store = Store(reducer: ScopedCollectionFeature(), initialState: .init())
    let scopedTodos = store.scope(
      collection: \.todos,
      action: ScopedCollectionFeature.Action.todoActionPath
    )

    scopedTodos[1].send(.setDone(true))

    #expect(store.state.todos[0].isDone == false)
    #expect(store.state.todos[1].isDone == true)
    #expect(store.state.todos[2].isDone == false)
  }

  @Test("ForEachReducer ignores unknown collection ids")
  func forEachReducerIgnoresUnknownIDs() {
    let store = Store(reducer: ScopedCollectionFeature(), initialState: .init())
    let missingID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!

    store.send(.todo(id: missingID, action: .setDone(true)))

    #expect(store.state.todos.map(\.isDone) == [false, false, false])
  }

  @Test("IfLet lifts child actions and effects while optional state is present")
  func ifLetScopesOptionalChildState() {
    let store = Store(reducer: IfLetFeature(), initialState: .init())

    store.send(.child(.increment))

    #expect(store.state.child?.count == 1)
    #expect(store.state.log == ["optional-finished"])

    store.send(.dismiss)
    #expect(store.state.child == nil)

    store.send(.present)
    #expect(store.state.child == .init())
  }

  @Test("IfCaseLet lifts child actions and effects while the parent enum case matches")
  func ifCaseLetScopesEnumChildState() {
    let store = Store(reducer: IfCaseLetFeature(), initialState: .init())

    store.send(.activate)
    store.send(.child(.increment))

    #expect(store.state == .child(.init(count: 1, completions: 1)))

    store.send(.deactivate)
    #expect(store.state == .idle)
  }

  @Test("IfLet with onMissing: .ignore drops child actions silently without firing assertion")
  func ifLetIgnorePolicyDropsActionWithoutAssertion() {
    let store = Store(reducer: IfLetIgnoreFeature(), initialState: .init(child: nil))

    store.send(.child(.increment))

    #expect(store.state.child == nil)
    #expect(store.state.untouched == 7)
  }

  @Test("IfCaseLet with onMissing: .ignore drops child actions silently without firing assertion")
  func ifCaseLetIgnorePolicyDropsActionWithoutAssertion() {
    let store = Store(reducer: IfCaseLetIgnoreFeature(), initialState: .idle)

    store.send(.child(.increment))

    #expect(store.state == .idle)
  }

  @Test("Collection-scoped stores ignore sibling element mutations when observing a row")
  func collectionScopedStoreIgnoresSiblingMutation() async {
    let store = Store(reducer: ScopedCollectionFeature(), initialState: .init())
    let callsiteLine: UInt = #line
    let scopedTodos = store.scope(
      collection: \.todos,
      action: ScopedCollectionFeature.Action.todoActionPath,
      fileID: #fileID,
      line: callsiteLine
    )
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = scopedTodos[0].isDone
      },
      onChange: {
        probe.recordChange()
      })

    store.send(.todo(id: scopedTodos[1].id, action: .setDone(true)))
    try? await Task.sleep(for: .milliseconds(20))

    #expect(probe.count == 0)
    #expect(scopedTodos[0].isDone == false)
    #expect(scopedTodos[1].isDone == true)
  }

  @Test("Collection-scoped stores invalidate when their own element changes")
  func collectionScopedStoreInvalidatesOnOwnMutation() async {
    let store = Store(reducer: ScopedCollectionFeature(), initialState: .init())
    let callsiteLine: UInt = #line
    let scopedTodos = store.scope(
      collection: \.todos,
      action: ScopedCollectionFeature.Action.todoActionPath,
      fileID: #fileID,
      line: callsiteLine
    )
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = scopedTodos[0].isDone
      },
      onChange: {
        probe.recordChange()
      })

    store.send(.todo(id: scopedTodos[0].id, action: .setDone(true)))
    try? await Task.sleep(for: .milliseconds(20))

    #expect(probe.count == 1)
    #expect(scopedTodos[0].isDone == true)
  }

  @Test("ScopedStore stale message formatter includes types, ids, and remediation")
  func scopedStoreFailureMessageFormatter() {
    let elementID = AnyHashable(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)

    let parentReleased = scopedStoreFailureMessage(
      parentType: ScopedBindableChildFeature.self,
      childType: ScopedBindableChildFeature.Child.self,
      stableID: nil,
      kind: .parentReleased
    )
    #expect(parentReleased.contains("ScopedStore<"))
    #expect(parentReleased.contains("ScopedBindableChildFeature"))
    #expect(parentReleased.contains("Child"))
    #expect(parentReleased.contains("regenerate the scoped store from parent state") == true)

    let collectionRemoved = scopedStoreFailureMessage(
      parentType: ScopedCollectionFeature.self,
      childType: ScopedCollectionFeature.Todo.self,
      stableID: elementID,
      kind: .collectionEntryRemoved
    )
    #expect(collectionRemoved.contains("ScopedCollectionFeature"))
    #expect(collectionRemoved.contains("Todo"))
    #expect(collectionRemoved.contains(String(describing: elementID)) == true)
    #expect(collectionRemoved.contains("source collection entry") == true)

    let identityRequired = scopedStoreFailureMessage(
      parentType: ScopedCollectionFeature.self,
      childType: ScopedCollectionFeature.Todo.self,
      stableID: nil,
      kind: .collectionIdentityRequired
    )
    #expect(identityRequired.contains("Identifiable") == true)
    #expect(identityRequired.contains("store.scope(collection:action:)") == true)
  }

  @Test("ScopedTestStore collection failure helpers include stable ids")
  func scopedTestStoreFailureHelpers() {
    let stableID = AnyHashable(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    #expect(scopedTestStoreFailureContext(stableID: nil) == nil)
    #expect(scopedTestStoreStateMismatchLabel(stableID: nil) == "Scoped state")

    let failureContext = scopedTestStoreFailureContext(stableID: stableID)
    #expect(failureContext?.contains(String(describing: stableID)) == true)
    #expect(
      scopedTestStoreStateMismatchLabel(stableID: stableID).contains("state mismatch") != true)
    #expect(
      scopedTestStoreStateMismatchLabel(stableID: stableID).contains(String(describing: stableID))
        == true)
  }

  @Test("ScopedStore debugDescription reports lifecycle and stable id context")
  func scopedStoreDebugDescription() {
    let store = Store(reducer: ScopedCollectionFeature(), initialState: .init())
    let scopedTodos = store.scope(
      collection: \.todos,
      action: ScopedCollectionFeature.Action.todoActionPath
    )
    let description = scopedTodos[0].debugDescription

    #expect(description.contains("ScopedStore(") == true)
    #expect(description.contains(String(reflecting: ScopedCollectionFeature.self)) == true)
    #expect(description.contains(String(reflecting: ScopedCollectionFeature.Todo.self)) == true)
    #expect(description.contains("parentAlive: true") == true)
    #expect(description.contains("active: true") == true)
    #expect(description.contains(String(describing: scopedTodos[0].id)) == true)
  }
}
