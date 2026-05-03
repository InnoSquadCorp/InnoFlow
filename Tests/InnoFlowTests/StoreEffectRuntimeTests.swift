// MARK: - StoreEffectRuntimeTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import SwiftUI
import Testing
import os

@testable import InnoFlow
@testable import InnoFlowTesting

// MARK: - Store Effect Runtime Tests

@Suite("Store Effect Runtime Tests", .serialized)
@MainActor
struct StoreEffectRuntimeTests {
  @Test("Store processes immediate follow-up actions through a FIFO queue")
  func storeQueuedFollowUpActions() {
    let probe = ReducerDepthProbe()
    let store = Store(
      reducer: QueueDispatchFeature(probe: probe),
      initialState: .init()
    )

    store.send(.start)

    #expect(store.logs == ["start", "first", "second"])
    #expect(probe.actions == ["start", "first", "second"])
  }

  @Test("Store queue removes reducer reentrancy for immediate sends")
  func storeQueuePreventsReducerReentrancy() {
    let probe = ReducerDepthProbe()
    let store = Store(
      reducer: QueueDispatchFeature(probe: probe),
      initialState: .init()
    )

    store.send(.start)

    #expect(probe.maxDepth == 1)
  }

  @Test("Store queues async effect emissions back through the same dispatch loop")
  func storeAsyncEffectUsesQueueDispatch() async {
    let probe = ReducerDepthProbe()
    let store = Store(
      reducer: QueueDispatchFeature(probe: probe),
      initialState: .init()
    )

    store.send(.loadAsync)
    #expect(store.logs == ["loadAsync"])

    for _ in 0..<40 {
      if store.logs == ["loadAsync", "loadedAsync"] {
        break
      }
      try? await Task.sleep(for: .milliseconds(20))
    }

    #expect(store.logs == ["loadAsync", "loadedAsync"])
    #expect(probe.maxDepth == 1)
  }

  @Test("Store cancelEffects waits for cancellation bookkeeping")
  func storeCancelEffects() async {
    let store = Store(reducer: CancellableFeature(), initialState: .init())

    store.send(.start(1))
    await store.cancelEffects(identifiedBy: "load")

    try? await Task.sleep(for: .milliseconds(300))
    #expect(store.completed.isEmpty)
  }

  @Test("Store cancelAllEffects cancels pending effects")
  func storeCancelAllEffects() async {
    let store = Store(reducer: CancellableFeature(), initialState: .init())

    store.send(.start(1))
    await store.cancelAllEffects()

    try? await Task.sleep(for: .milliseconds(300))
    #expect(store.completed.isEmpty)
  }

  @Test("Store cancellation is idempotent and does not poison future effects")
  func storeCancellationIsReusable() async {
    let store = Store(reducer: CancellableFeature(), initialState: .init())

    store.send(.start(1))
    await store.cancelEffects(identifiedBy: "load")
    await store.cancelEffects(identifiedBy: "load")

    store.send(.start(2))

    for _ in 0..<40 {
      if store.completed == [2] {
        break
      }
      try? await Task.sleep(for: .milliseconds(20))
    }

    #expect(store.completed == [2])
    #expect(store.requested == 2)
  }

  @Test("Store .run drops post-cancellation emissions but keeps earlier values")
  func storeRunDropsPostCancellationEmissions() async {
    let clock = ManualTestClock()
    let store = Store(
      reducer: RunEmissionBoundaryFeature(),
      initialState: .init(),
      clock: .manual(clock)
    )

    store.send(.start("first"))

    for _ in 0..<128 {
      if store.events.contains("first-1") {
        break
      }
      await drainAsyncWork(iterations: 1)
    }

    #expect(store.events.contains("first-1"))
    store.send(.cancel)
    await drainAsyncWork()
    await clock.advance(by: .milliseconds(140))
    await drainAsyncWork()

    #expect(store.events == ["first-1"])
  }

  @Test("Store drops direct .send actions after a cancellation boundary")
  func storeDirectSendDropsAfterCancellationBoundary() async {
    let probe = InstrumentationProbe()
    let store = Store(
      reducer: DirectSendCancellationBoundaryFeature(),
      initialState: .init(),
      instrumentation: .init(
        didEmitAction: { event in
          if case ._record(let value) = event.action {
            probe.record("emit:\(value)")
          }
        },
        didDropAction: { event in
          if case ._record(let value)? = event.action {
            probe.record("drop:\(value):\(event.reason)")
          }
        }
      )
    )

    store.send(.start)
    await waitUntil {
      probe.events.isEmpty == false || store.events.isEmpty == false
    }

    #expect(store.events.isEmpty)
    #expect(probe.events == ["drop:late:cancellationBoundary"])
  }

  @Test("Store .run keeps FIFO ordering for multiple emitted actions")
  func storeRunEmissionOrderingRemainsFIFO() async {
    let clock = ManualTestClock()
    let store = Store(
      reducer: RunEmissionBoundaryFeature(),
      initialState: .init(),
      clock: .manual(clock)
    )

    store.send(.start("ordered"))

    for _ in 0..<128 {
      if store.events == ["ordered-1"] {
        break
      }
      await drainAsyncWork(iterations: 1)
    }

    #expect(store.events == ["ordered-1"])
    await clock.advance(by: .milliseconds(100))

    // Two more emissions (ordered-2, ordered-3) land as queued follow-up
    // actions after the sleep resumes. `drainAsyncWork`'s fixed yield budget
    // is sufficient on fast hardware but not on saturated CI executors —
    // poll the observable outcome with a wall-clock bounded wait instead.
    await waitUntil(timeout: .seconds(5)) {
      store.events.count >= 3
    }

    #expect(store.events == ["ordered-1", "ordered-2", "ordered-3"])
  }

  @Test("Store .run remains reusable after cancel and restart")
  func storeRunEmissionRecoversAfterRestart() async {
    let clock = ManualTestClock()
    let store = Store(
      reducer: RunEmissionBoundaryFeature(),
      initialState: .init(),
      clock: .manual(clock)
    )

    store.send(.start("first"))
    for _ in 0..<128 {
      if store.events.contains("first-1") {
        break
      }
      await drainAsyncWork(iterations: 1)
    }
    #expect(store.events.contains("first-1"))

    store.send(.cancel)
    await drainAsyncWork()
    await clock.advance(by: .milliseconds(100))
    await drainAsyncWork()

    store.send(.start("second"))

    for _ in 0..<128 {
      if store.events == ["first-1", "second-1"] {
        break
      }
      await drainAsyncWork(iterations: 1)
    }

    #expect(store.events == ["first-1", "second-1"])
    await clock.advance(by: .milliseconds(100))

    // Same CI-executor-saturation risk as `storeRunEmissionOrderingRemainsFIFO`
    // above: after the advance, the two remaining emissions arrive as queued
    // follow-up actions. Poll observable state with a wall-clock bounded wait.
    await waitUntil(timeout: .seconds(5)) {
      store.events.count >= 4
    }

    #expect(store.events == ["first-1", "second-1", "second-2", "second-3"])
  }

  @Test("Lazy-mapped structured effects preserve ordering")
  func lazyMappedStructuredEffectsPreserveOrdering() async {
    let clock = ManualTestClock()
    let store = Store(
      reducer: LazyMappedEffectFeature(),
      initialState: .init(),
      clock: .manual(clock)
    )

    store.send(.start)

    await waitUntil(timeout: .seconds(5), pollInterval: .milliseconds(10)) {
      store.values == ["first"]
    }

    #expect(store.values == ["first"])
    await drainAsyncWork(iterations: 128)
    await clock.advance(by: .milliseconds(80))

    await waitUntil(timeout: .seconds(5), pollInterval: .milliseconds(10)) {
      store.values == ["first", "second"]
    }

    #expect(store.values == ["first", "second"])
  }

  @Test("Lazy-mapped structured effects honor cancellation")
  func lazyMappedStructuredEffectsHonorCancellation() async {
    let clock = ManualTestClock()
    let store = Store(
      reducer: LazyMappedEffectFeature(),
      initialState: .init(),
      clock: .manual(clock)
    )

    store.send(.start)

    for _ in 0..<128 {
      if store.values.contains("first") {
        break
      }
      await drainAsyncWork(iterations: 1)
    }

    #expect(store.values == ["first"])
    store.send(.cancel)
    await drainAsyncWork()
    await clock.advance(by: .milliseconds(120))
    await drainAsyncWork()

    #expect(store.values == ["first"])
  }

  @Test("Heavy stress: deep lazy map chains preserve ordering")
  func heavyStressLazyMapDeepChain() async {
    guard isHeavyStressEnabled else { return }

    let store = Store(
      reducer: DeepLazyMapStressFeature(chainDepth: 256),
      initialState: .init()
    )

    store.send(.start(0))

    for _ in 0..<50 {
      if store.values == [256, 257] {
        break
      }
      try? await Task.sleep(for: .milliseconds(10))
    }

    #expect(store.values == [256, 257])
  }

  @Test("Heavy stress: repeated lazy map materialization stays stable")
  func heavyStressLazyMapRepeatedMaterialization() async {
    guard isHeavyStressEnabled else { return }

    let store = Store(
      reducer: DeepLazyMapStressFeature(
        chainDepth: 128, cancellationID: "deep-lazy-map-repeat", includesAsyncTail: false),
      initialState: .init()
    )

    for seed in 0..<40 {
      store.send(.start(seed * 10))
    }

    #expect(store.values.count == 80)
    #expect(store.values.first == 128)
    #expect(store.values.last == 519)
  }

  @Test("Heavy stress: lazy map cancellation mix preserves semantics")
  func heavyStressLazyMapCancellationMix() async {
    guard isHeavyStressEnabled else { return }

    let store = Store(
      reducer: DeepLazyMapStressFeature(chainDepth: 64, cancellationID: "deep-lazy-map-cancel"),
      initialState: .init()
    )

    for seed in 0..<20 {
      store.send(.start(seed * 100))
      for _ in 0..<20 {
        if store.values.count == seed + 1 {
          break
        }
        try? await Task.sleep(for: .milliseconds(2))
      }
      store.send(.cancel)
      try? await Task.sleep(for: .milliseconds(5))
    }

    try? await Task.sleep(for: .milliseconds(80))

    #expect(store.values.count == 20)
    #expect(store.values.first == 64)
    #expect(store.values.last == 1964)
  }

  @Test("Deep lazy-map chains materialize without recursive lazy wrapper growth")
  func deepLazyMapChainStaysStable() async {
    let store = Store(
      reducer: DeepLazyMapStressFeature(chainDepth: 2048, includesAsyncTail: false),
      initialState: .init()
    )

    store.send(.start(0))

    for _ in 0..<40 {
      if store.values == [2048, 2049] {
        break
      }
      await Task.yield()
    }

    #expect(store.values == [2048, 2049])
  }

  @Test("Store drops emissions from cancelled uncooperative effects")
  func storeDropsCancelledEffectEmission() async {
    let store = Store(
      reducer: UncooperativeCancellableFeature(),
      initialState: .init()
    )

    store.send(.start)
    await store.cancelEffects(identifiedBy: "uncooperative")

    try? await Task.sleep(for: .milliseconds(150))
    #expect(store.completed.isEmpty)
  }

  @Test("Store repeatedly drops late emissions after cancelEffects")
  func storeCancellationStress() async {
    let store = Store(
      reducer: UncooperativeCancellableFeature(),
      initialState: .init()
    )
    let iterations = isHeavyStressEnabled ? 1_000 : 200

    for _ in 0..<iterations {
      store.send(.start)
      await store.cancelEffects(identifiedBy: "uncooperative")
    }

    try? await Task.sleep(for: .milliseconds(250))
    #expect(store.completed.isEmpty)
  }

  @Test("Store applies cancellation boundaries to merge and concatenate")
  func storeCancellationBoundaryOnComposedEffects() async {
    let store = Store(
      reducer: CompositeUncooperativeFeature(),
      initialState: .init()
    )

    for value in 0..<120 {
      store.send(.start(value))
      await store.cancelEffects(identifiedBy: "composite-uncooperative")
    }

    try? await Task.sleep(for: .milliseconds(300))
    #expect(store.completed.isEmpty)
  }

  @Test("Store combinator composition keeps debounce and throttle semantics")
  func storeCombinatorComposition() async {
    let clock = ManualTestClock()
    let store = Store(
      reducer: CombinatorCompositionFeature(),
      initialState: .init(),
      clock: .manual(clock)
    )

    store.send(.start(1))
    // Wait for the first merge to fully dispatch: throttle emits its leading
    // value and debounce registers its sleeper. Under release optimization a
    // fixed yield count is fragile — poll for the observable outcome.
    for _ in 0..<200 {
      let count = await clock.sleeperCount
      if store.throttled == [1] && count >= 1 { break }
      await Task.yield()
    }

    store.send(.start(2))
    // The second merge's throttle must run and see the still-open window BEFORE
    // we advance the clock. If we advance first, the window is treated as
    // expired and the throttle emits the second value as a new leading emission.
    // Neither throttle_2's suppression nor debounce_2's replacement registration
    // produces a distinct observable state change (sleeperCount stays at 1
    // across the cancel+re-register), so we can only wait for the merge's
    // MainActor walker work to drain. A small wall-clock sleep on the system
    // ContinuousClock gives the cooperative executor a real chance to run
    // other tasks — more reliable than a fixed yield count on saturated CI.
    try? await Task.sleep(for: .milliseconds(100))

    await clock.advance(by: .milliseconds(50))
    await waitUntil(timeout: .seconds(5), pollInterval: .milliseconds(10)) {
      store.debounced == [2]
    }

    #expect(store.debounced == [2])
    #expect(store.throttled == [1])
  }

  @Test("CombineReducers runs parent reducers in declaration order and Scope lifts child effects")
  func composedReducersLiftChildEffects() async {
    let store = Store(
      reducer: ComposedReducerFeature(),
      initialState: .init()
    )

    store.send(.start)

    for _ in 0..<40 {
      if store.events == ["start", "parent saw child increment", "parent saw child report"] {
        break
      }
      try? await Task.sleep(for: .milliseconds(20))
    }

    #expect(store.child.value == 1)
    #expect(store.events == ["start", "parent saw child increment", "parent saw child report"])
  }

  @Test("Empty CombineReducers behaves like .none")
  func emptyCombineReducers() {
    let reducer = CombineReducers<BuilderCompositionFeature.State, BuilderCompositionFeature.Action>
    {
    }
    var state = BuilderCompositionFeature.State()

    let effect = reducer.reduce(into: &state, action: .run)

    #expect(state.log.isEmpty)
    #expect(effect.isNone)
  }

  @Test("CombineReducers if-only builder paths keep semantics without exposing builder internals")
  func combineReducersOptionalBuilderPath() {
    let reducer = BuilderCompositionFeature.optionalBuilder(includeReducer: true)
    var state = BuilderCompositionFeature.State()

    let effect = reducer.reduce(into: &state, action: .run)

    #expect(state.log == ["optional"])
    #expect(effect.isNone)
    #expect(String(reflecting: type(of: reducer)).contains("_OptionalReducer<"))
    #expect(!String(reflecting: type(of: reducer)).contains("_ReducerBuilder"))
  }

  @Test("CombineReducers if/else builder paths keep semantics without exposing builder internals")
  func combineReducersEitherBuilderPath() {
    let reducer = BuilderCompositionFeature.eitherBuilder(chooseFirst: false)
    var state = BuilderCompositionFeature.State()

    let effect = reducer.reduce(into: &state, action: .run)

    #expect(state.log == ["second"])
    #expect(effect.isNone)
    #expect(String(reflecting: type(of: reducer)).contains("_ConditionalReducer<"))
    #expect(!String(reflecting: type(of: reducer)).contains("_ReducerBuilder"))
  }

  @Test("CombineReducers for-loops keep semantics without exposing builder internals")
  func combineReducersArrayBuilderPath() {
    let labels = ["first", "second", "third"]
    let reducer = BuilderCompositionFeature.arrayBuilder(labels: labels)
    var state = BuilderCompositionFeature.State()

    let effect = reducer.reduce(into: &state, action: .run)

    #expect(state.log == labels)
    #expect(effect.isNone)
    #expect(String(reflecting: type(of: reducer)).contains("_ArrayReducer<"))
    #expect(!String(reflecting: type(of: reducer)).contains("_ReducerBuilder"))
  }

  @Test("ReducerBuilder returns a stable public concrete type without builder wrappers")
  func combineReducersConcreteWrapperChain() {
    let reducer = BuilderCompositionFeature.straightLineBuilder()
    var state = BuilderCompositionFeature.State()

    let effect = reducer.reduce(into: &state, action: .run)
    let typeDescription = String(reflecting: type(of: reducer))

    #expect(state.log == ["first", "second"])
    #expect(effect.isNone)
    #expect(typeDescription.contains("_ReducerSequence<"))
    #expect(!typeDescription.contains("_ReducerBuilder"))
    #expect(!typeDescription.contains("[any Reducer"))
  }

  @Test("Builder preserves declaration order across mixed if/for/if-else/straight-line blocks")
  func combineReducersMixedBuilderBlock() {
    let reducer = CombineReducers<BuilderCompositionFeature.State, BuilderCompositionFeature.Action>
    {
      BuilderCompositionFeature.append("a")
      if true {
        BuilderCompositionFeature.append("b")
      }
      for label in ["c", "d"] {
        BuilderCompositionFeature.append(label)
      }
      if false {
        BuilderCompositionFeature.append("skipped-first")
      } else {
        BuilderCompositionFeature.append("else")
      }
      BuilderCompositionFeature.append("z")
    }
    var state = BuilderCompositionFeature.State()

    let effect = reducer.reduce(into: &state, action: .run)

    // Declaration order must be preserved across heterogeneous builder
    // constructs (expression, if-without-else, for, if/else, expression).
    #expect(state.log == ["a", "b", "c", "d", "else", "z"])
    #expect(effect.isNone)
  }

  @Test("Builder compiles and preserves order for N=32 straight-line block")
  func combineReducersN32StressPreservesOrder() {
    let reducer = CombineReducers<BuilderCompositionFeature.State, BuilderCompositionFeature.Action>
    {
      BuilderCompositionFeature.append("01")
      BuilderCompositionFeature.append("02")
      BuilderCompositionFeature.append("03")
      BuilderCompositionFeature.append("04")
      BuilderCompositionFeature.append("05")
      BuilderCompositionFeature.append("06")
      BuilderCompositionFeature.append("07")
      BuilderCompositionFeature.append("08")
      BuilderCompositionFeature.append("09")
      BuilderCompositionFeature.append("10")
      BuilderCompositionFeature.append("11")
      BuilderCompositionFeature.append("12")
      BuilderCompositionFeature.append("13")
      BuilderCompositionFeature.append("14")
      BuilderCompositionFeature.append("15")
      BuilderCompositionFeature.append("16")
      BuilderCompositionFeature.append("17")
      BuilderCompositionFeature.append("18")
      BuilderCompositionFeature.append("19")
      BuilderCompositionFeature.append("20")
      BuilderCompositionFeature.append("21")
      BuilderCompositionFeature.append("22")
      BuilderCompositionFeature.append("23")
      BuilderCompositionFeature.append("24")
      BuilderCompositionFeature.append("25")
      BuilderCompositionFeature.append("26")
      BuilderCompositionFeature.append("27")
      BuilderCompositionFeature.append("28")
      BuilderCompositionFeature.append("29")
      BuilderCompositionFeature.append("30")
      BuilderCompositionFeature.append("31")
      BuilderCompositionFeature.append("32")
    }
    var state = BuilderCompositionFeature.State()

    let effect = reducer.reduce(into: &state, action: .run)
    let expectedLog = (1...32).map { String(format: "%02d", $0) }

    #expect(state.log == expectedLog)
    #expect(effect.isNone)
  }

  @Test("Builder optional path with false condition yields .none effect and no state change")
  func combineReducersEmptyOptional() {
    let reducer = BuilderCompositionFeature.optionalBuilder(includeReducer: false)
    var state = BuilderCompositionFeature.State()

    let effect = reducer.reduce(into: &state, action: .run)

    #expect(state.log.isEmpty)
    #expect(effect.isNone)
    #expect(String(reflecting: type(of: reducer)).contains("_OptionalReducer<"))
  }

  @Test("Phase validation decorator allows same-phase actions and legal transitions")
  func phaseValidationDecorator() async {
    let store = Store(
      reducer: ValidatedPhaseReducer(),
      initialState: .init()
    )

    store.send(.noop)
    #expect(store.phase == .idle)

    store.send(.load)
    #expect(store.phase == .loading)

    store.send(.finish)
    #expect(store.phase == .loaded)
  }

  @Test("Store throttle trailing-only emits latest value at window end")
  func storeThrottleTrailingOnly() async {
    let clock = ManualTestClock()
    let store = Store(
      reducer: ThrottleTrailingFeature(),
      initialState: .init(),
      clock: .manual(clock)
    )

    store.send(.trigger(1))
    store.send(.trigger(2))
    for _ in 0..<10 {
      await Task.yield()
    }
    #expect(store.emitted.isEmpty)

    await clock.advance(by: .milliseconds(79))
    #expect(store.emitted.isEmpty)

    await clock.advance(by: .milliseconds(1))
    for _ in 0..<10 {
      if store.emitted == [2] {
        break
      }
      await Task.yield()
    }
    #expect(store.emitted == [2])
  }

  @Test("StoreClock deterministically drives debounce effects")
  func storeClockControlsDebounce() async {
    let clock = ManualTestClock()
    let store = Store(
      reducer: DebounceFeature(),
      initialState: .init(),
      clock: .manual(clock)
    )

    store.send(.trigger(1))
    store.send(.trigger(2))
    for _ in 0..<10 {
      await Task.yield()
    }
    #expect(store.emitted.isEmpty)

    await clock.advance(by: .milliseconds(59))
    #expect(store.emitted.isEmpty)

    await clock.advance(by: .milliseconds(1))
    for _ in 0..<10 {
      if store.emitted == [2] {
        break
      }
      await Task.yield()
    }

    #expect(store.emitted == [2])
  }

  @Test("Store debounce cancels stale sleeper tasks by id")
  func storeDebounceCancelsStaleSleeperTasks() async throws {
    let clock = ManualTestClock()
    let store = Store(
      reducer: DebounceFeature(),
      initialState: .init(),
      clock: .manual(clock)
    )

    func waitForSingleDebounceSleeper() async -> Bool {
      await drainAsyncWork(iterations: 64)
      return await waitUntilAsync(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
        await clock.sleeperCount == 1
      }
    }

    store.send(.trigger(1))
    try #require(await waitForSingleDebounceSleeper())

    for value in 2...5 {
      store.send(.trigger(value))
      try #require(await waitForSingleDebounceSleeper())
    }

    try #require(await waitForSingleDebounceSleeper())

    await clock.advance(by: .milliseconds(60))
    await waitUntil {
      store.emitted == [5]
    }

    #expect(store.emitted == [5])
  }

  @Test("ManualTestClock resumes all same-deadline sleepers")
  func manualTestClockResumesAllSameDeadlineSleepers() async throws {
    let clock = ManualTestClock()
    let probe = OrderedIntProbe()

    // Spawn two sleepers that hit the same deadline. The sleepers must be
    // registered with the clock before we advance — under release optimization
    // and parallel test load, a single `Task.yield()` between spawn and advance
    // is not reliable. Require each Task to register before proceeding.
    let firstSleeper = Task {
      try? await clock.sleep(for: .milliseconds(50))
      await probe.append(1)
    }
    try #require(
      await waitUntilAsync(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
        await clock.sleeperCount == 1
      }
    )

    let secondSleeper = Task {
      try? await clock.sleep(for: .milliseconds(50))
      await probe.append(2)
    }
    try #require(
      await waitUntilAsync(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
        await clock.sleeperCount == 2
      }
    )

    await clock.advance(by: .milliseconds(50))
    _ = await firstSleeper.result
    _ = await secondSleeper.result

    let snapshot = await probe.snapshot()
    #expect(snapshot.count == 2)
    #expect(snapshot.sorted() == [1, 2])
  }

  @Test("ManualTestClock cancels pending sleepers without late resume")
  func manualTestClockCancelsPendingSleepersWithoutLateResume() async {
    let clock = ManualTestClock()
    let probe = OrderedIntProbe()

    let task = Task {
      do {
        try await clock.sleep(for: .milliseconds(50))
        await probe.append(1)
      } catch is CancellationError {
        await probe.append(-1)
      } catch {
        Issue.record("Expected CancellationError, got \(error)")
      }
    }

    await Task.yield()
    task.cancel()
    _ = await task.result

    await clock.advance(by: .milliseconds(50))
    #expect(
      await waitUntilAsync(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
        await probe.snapshot() == [-1]
      }
    )

    #expect(await probe.snapshot() == [-1])
  }

  @Test("StoreClock deterministically drives trailing throttle effects")
  func storeClockControlsThrottleTrailing() async {
    let clock = ManualTestClock()
    let store = Store(
      reducer: ThrottleTrailingFeature(),
      initialState: .init(),
      clock: .manual(clock)
    )

    store.send(.trigger(1))
    store.send(.trigger(2))
    for _ in 0..<10 {
      await Task.yield()
    }
    #expect(store.emitted.isEmpty)

    await clock.advance(by: .milliseconds(79))
    #expect(store.emitted.isEmpty)

    await clock.advance(by: .milliseconds(1))
    for _ in 0..<10 {
      if store.emitted == [2] {
        break
      }
      await Task.yield()
    }

    #expect(store.emitted == [2])
  }

  @Test("StoreClock respects cancellation boundaries for debounced effects")
  func storeClockCancellationBoundary() async {
    let clock = ManualTestClock()
    let store = Store(
      reducer: DebounceFeature(),
      initialState: .init(),
      clock: .manual(clock)
    )

    store.send(.trigger(1))
    await store.cancelEffects(identifiedBy: "debounce-effect")
    await clock.advance(by: .milliseconds(60))
    for _ in 0..<10 {
      await Task.yield()
    }

    #expect(store.emitted.isEmpty)
  }

  @Test("EffectContext uses StoreClock for deterministic run timing")
  func effectContextUsesStoreClock() async {
    let clock = ManualTestClock()
    let store = Store(
      reducer: ContextClockFeature(),
      initialState: .init(),
      clock: .manual(clock)
    )

    store.send(.start)
    // `store.send` only guarantees the reducer has run; async effects dispatched
    // via `Task { ... }` still need scheduler turns to reach their first await.
    // Release optimization eliminates some scheduling boundaries, so a fixed
    // yield count is fragile — poll for the observable condition instead.
    await waitUntil(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
      store.state.log == ["started"]
    }

    #expect(store.state.log == ["started"])
    #expect(
      await waitUntilAsync(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
        await clock.sleeperCount == 1
      }
    )

    await clock.advance(by: .milliseconds(50))
    await waitUntil(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
      store.state.log == ["started", "finished"]
    }

    #expect(store.state.log == ["started", "finished"])
  }

  @Test("EffectContext.checkCancellation stays clear while a run remains active")
  func effectContextCheckCancellationPassesWhileActive() async {
    let clock = ManualTestClock()
    let probe = CancellationCheckProbe()
    let store = Store(
      reducer: CancellationCheckFeature(probe: probe),
      initialState: .init(),
      clock: .manual(clock)
    )

    store.send(.start)
    // Wait for the effect operation to reach its `context.sleep(...)`
    // suspension point before advancing the clock. `store.send` only guarantees
    // reducer completion; the `.run` body runs through several actor hops before
    // registering the sleeper, and release optimization eliminates some of the
    // scheduling boundaries that a fixed yield count relied on — poll instead.
    for _ in 0..<200 {
      if await probe.started == 1 { break }
      await Task.yield()
    }

    await clock.advance(by: .milliseconds(10))

    for _ in 0..<200 {
      if await probe.passed == 1 { break }
      await Task.yield()
    }

    #expect(await probe.started == 1)
    #expect(await probe.ready == 1)
    #expect(await probe.passed == 1)
    #expect(await probe.cancelled == 0)

    await store.cancelEffects(identifiedBy: "context-check")
  }

  @Test("EffectContext.checkCancellation throws after cancelEffects")
  func effectContextCheckCancellationThrowsAfterCancelEffects() async {
    let clock = ManualTestClock()
    let probe = CancellationCheckProbe()
    let store = Store(
      reducer: CancellationCheckFeature(probe: probe),
      initialState: .init(),
      clock: .manual(clock)
    )

    store.send(.start)
    for _ in 0..<200 {
      if await probe.started == 1 { break }
      await Task.yield()
    }

    await clock.advance(by: .milliseconds(10))
    for _ in 0..<200 {
      if await probe.passed == 1 { break }
      await Task.yield()
    }

    await store.cancelEffects(identifiedBy: "context-check")
    for _ in 0..<200 {
      if await probe.cancelled == 1 { break }
      await Task.yield()
    }

    #expect(await probe.cancelled == 1)
  }

  @Test("TestStore preserves first emission from merge-wrapped sequential effects")
  @MainActor
  func testStorePreservesMergeWrappedSequentialEffects() async {
    let store = TestStore(reducer: SequentialMergeFeature())

    await store.send(.start)
    await store.receive(._first) {
      $0.received = ["first"]
    }
    await store.receive(._second) {
      $0.received = ["first", "second"]
    }
    await store.assertNoMoreActions()
  }

  @Test("Store throttle leading+trailing skips trailing when no extra event")
  func storeThrottleLeadingTrailingSingleEvent() async {
    let store = Store(
      reducer: ThrottleLeadingTrailingFeature(),
      initialState: .init()
    )

    store.send(.trigger(1))
    try? await Task.sleep(for: .milliseconds(160))
    #expect(store.emitted == [1])
  }

  @Test("Store cancelEffects drops pending throttle trailing emission")
  func storeThrottleTrailingCancelledByID() async {
    let store = Store(
      reducer: ThrottleTrailingFeature(),
      initialState: .init()
    )

    store.send(.trigger(1))
    store.send(.trigger(2))
    await store.cancelEffects(identifiedBy: "throttle-trailing")

    try? await Task.sleep(for: .milliseconds(120))
    #expect(store.emitted.isEmpty)
  }

  @Test("Store cancelAllEffects drops pending throttle trailing emission")
  func storeThrottleTrailingCancelledByAll() async {
    let store = Store(
      reducer: ThrottleTrailingFeature(),
      initialState: .init()
    )

    store.send(.trigger(1))
    store.send(.trigger(2))
    await store.cancelAllEffects()

    try? await Task.sleep(for: .milliseconds(120))
    #expect(store.emitted.isEmpty)
  }

  @Test("Store release cancels pending debounce without retaining Store")
  func storeReleaseCancelsPendingDebounceWithoutRetainingStore() async throws {
    let clock = ManualTestClock()
    weak var weakStore: Store<DebounceFeature>?

    do {
      var store: Store<DebounceFeature>? = Store(
        reducer: DebounceFeature(),
        initialState: .init(),
        clock: .manual(clock)
      )
      weakStore = store
      store?.send(.trigger(1))
      try #require(
        await waitUntilAsync(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
          await clock.sleeperCount == 1
        }
      )
      store = nil
    }

    await waitUntil {
      weakStore == nil
    }
    try #require(
      await waitUntilAsync(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
        await clock.sleeperCount == 0
      }
    )

    await clock.advance(by: .seconds(5))
    #expect(weakStore == nil)
    #expect(await clock.sleeperCount == 0)
  }

  @Test("Store release cancels pending trailing throttle without retaining Store")
  func storeReleaseCancelsPendingTrailingThrottleWithoutRetainingStore() async throws {
    let clock = ManualTestClock()
    weak var weakStore: Store<ThrottleTrailingFeature>?

    do {
      var store: Store<ThrottleTrailingFeature>? = Store(
        reducer: ThrottleTrailingFeature(),
        initialState: .init(),
        clock: .manual(clock)
      )
      weakStore = store
      store?.send(.trigger(1))
      store?.send(.trigger(2))
      try #require(
        await waitUntilAsync(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
          await clock.sleeperCount == 1
        }
      )
      store = nil
    }

    await waitUntil {
      weakStore == nil
    }
    try #require(
      await waitUntilAsync(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
        await clock.sleeperCount == 0
      }
    )

    await clock.advance(by: .seconds(5))
    #expect(weakStore == nil)
    #expect(await clock.sleeperCount == 0)
  }

  @Test("Store deinit prevents long-running effect completion")
  func storeDeinitPreventsLongRunningCompletion() async {
    let probe = DeinitCancellationProbe()
    var store: Store<DeinitCancellationFeature>? = Store(
      reducer: DeinitCancellationFeature(probe: probe),
      initialState: .init()
    )

    store?.send(.start)

    for _ in 0..<100 {
      if await probe.started == 1 {
        break
      }
      try? await Task.sleep(for: .milliseconds(20))
    }
    store = nil

    for _ in 0..<150 {
      if await probe.cancelled == 1 {
        break
      }
      if await probe.completed > 0 {
        break
      }
      try? await Task.sleep(for: .milliseconds(20))
    }

    #expect(await probe.started == 1)
    #expect(await probe.completed == 0)
    #expect(await probe.cancelled == 1)
  }

  @Test("EffectContext.checkCancellation throws after store release")
  func effectContextCheckCancellationThrowsAfterStoreRelease() async {
    let clock = ManualTestClock()
    let probe = CancellationCheckProbe()
    var store: Store<CancellationCheckFeature>? = Store(
      reducer: CancellationCheckFeature(probe: probe),
      initialState: .init(),
      clock: .manual(clock)
    )

    store?.send(.start)
    for _ in 0..<10 {
      await Task.yield()
    }

    await clock.advance(by: .milliseconds(10))

    for _ in 0..<30 {
      if await probe.passed == 1 {
        break
      }
      await Task.yield()
    }

    store = nil

    for _ in 0..<30 {
      if await probe.cancelled == 1 {
        break
      }
      await Task.yield()
    }

    #expect(await probe.cancelled == 1)
  }

  @Test("Store startRun honors cancellation boundaries before user operation")
  func storeStartRunHonorsCancellationBoundariesBeforeUserOperation() async {
    let id = AnyEffectID(StaticEffectID("store-start-gate-race"))
    let context = EffectExecutionContext(cancellationID: id, sequence: 1)
    let probe = RunStartGateRaceProbe()
    let store = Store(
      reducer: CounterFeature(),
      initialState: .init()
    )

    await store.cancelEffects(id: id, context: context)
    await store.startRun(
      priority: nil,
      operation: { _, _ in
        await probe.markStarted()
      }, context: context, awaited: true)

    let metrics = await store.effectRuntimeMetrics
    #expect(metrics.preparedRuns == 1)
    #expect(metrics.finishedRuns == 1)
    #expect(metrics.cancellations == 1)
    #expect(await probe.started == 0)
  }

  @Test("Store cancelled run effects do not start after public cancellation")
  func storeCancelledRunEffectsDoNotStartAfterPublicCancellation() async {
    let probe = RunStartGateRaceProbe()
    let store = Store(
      reducer: RunStartGateRaceFeature(probe: probe),
      initialState: .init()
    )

    store.send(.start)
    await store.cancelEffects(identifiedBy: "start-gate-race")
    await drainAsyncWork()
    try? await Task.sleep(for: .milliseconds(20))
    await drainAsyncWork()

    #expect(await probe.started == 0)
  }
}
