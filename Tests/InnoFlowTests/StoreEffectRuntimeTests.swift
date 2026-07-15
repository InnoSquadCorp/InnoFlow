// MARK: - StoreEffectRuntimeTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import Testing
import os

@testable import InnoFlowCore
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
  func storeRunDropsPostCancellationEmissions() async throws {
    let clock = ManualTestClock()
    let emittedFirst = AsyncTestSignal()
    let finished = AsyncTestSignal()
    let store = Store(
      reducer: RunEmissionBoundaryFeature(),
      initialState: .init(),
      clock: .manual(clock),
      instrumentation: .init(
        didFinishRun: { _ in finished.signal() },
        didEmitAction: { event in
          if event.action == ._record("first-1") {
            emittedFirst.signal()
          }
        }
      )
    )

    store.send(.start("first"))
    try #require(await emittedFirst.wait())
    #expect(store.events.contains("first-1"))
    try #require(
      await waitUntilAsync(timeout: .seconds(60), pollInterval: .milliseconds(1)) {
        await clock.sleeperCount == 1
      }
    )

    store.send(.cancel)
    try #require(await finished.wait())

    #expect(store.events == ["first-1"])
    #expect(await clock.sleeperCount == 0)
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

  @Test("Store stale cancellation preserves a newer run sequence")
  func storeStaleCancellationPreservesNewerRunSequence() async throws {
    let staleCancellationReady = AsyncTestSignal()
    let releaseStaleCancellation = LateSendGate()
    let staleCancellationApplied = AsyncTestSignal()
    let newerRunReady = AsyncTestSignal()
    let releaseNewerRun = LateSendGate()
    let newerRunFinished = AsyncTestSignal()
    let probe = SequenceCancellationProbe()
    let store = Store(
      reducer: SequenceBoundedCancellationFeature(
        staleCancellationReady: staleCancellationReady,
        releaseStaleCancellation: releaseStaleCancellation,
        staleCancellationApplied: staleCancellationApplied,
        newerRunReady: newerRunReady,
        releaseNewerRun: releaseNewerRun,
        newerRunFinished: newerRunFinished,
        probe: probe
      ),
      initialState: .init()
    )

    store.send(.scheduleStaleCancellation)
    try #require(await staleCancellationReady.wait())

    store.send(.startNewerRun)
    try #require(await newerRunReady.wait())

    await releaseStaleCancellation.open()
    try #require(await staleCancellationApplied.wait())

    await releaseNewerRun.open()
    try #require(await newerRunFinished.wait())

    #expect(await probe.wasCancellationRequested == false)
  }

  @Test("Store stale cancellation preserves a newer concatenate composite")
  func storeStaleCancellationPreservesNewerCompositeSequence() async throws {
    let staleCancellationReady = AsyncTestSignal()
    let releaseStaleCancellation = RunStartGate()
    let staleCancellationApplied = AsyncTestSignal()
    let newerChildReady = AsyncTestSignal()
    let releaseNewerChild = RunStartGate()
    let newerCompositeFinished = AsyncTestSignal()
    let store = Store(
      reducer: SequenceBoundedCompositeFeature(
        staleCancellationReady: staleCancellationReady,
        releaseStaleCancellation: releaseStaleCancellation,
        staleCancellationApplied: staleCancellationApplied,
        newerChildReady: newerChildReady,
        releaseNewerChild: releaseNewerChild,
        newerCompositeFinished: newerCompositeFinished
      ),
      initialState: .init()
    )

    do {
      store.send(.scheduleStaleCancellation)
      try #require(await staleCancellationReady.wait())

      store.send(.startNewerComposite)
      try #require(await newerChildReady.wait())

      await releaseStaleCancellation.open()
      try #require(await staleCancellationApplied.wait())

      await releaseNewerChild.open()
      try #require(await newerCompositeFinished.wait())
    } catch {
      await releaseStaleCancellation.open()
      await releaseNewerChild.open()
      await store.cancelAllEffects()
      throw error
    }

    #expect(store.finished)
    await store.cancelAllEffects()
  }

  @Test("Store stale cancellation preserves a newer merge composite wrapper")
  func storeStaleCancellationPreservesNewerMergeComposite() async throws {
    let store = Store(reducer: CounterFeature(), initialState: .init())
    let id = AnyEffectID(StaticEffectID("sequence-bounded-merge"))
    let staleSequence = store.effectBridge.nextSequence()
    let newerSequence = store.effectBridge.nextSequence()
    let newerContext = EffectExecutionContext(cancellationID: id, sequence: newerSequence)
    let childReady = AsyncTestSignal()
    let releaseChild = RunStartGate()
    let childFinished = AsyncTestSignal()
    let probe = SequenceCancellationProbe()

    await store.runConcurrently(
      [.none],
      context: newerContext,
      awaited: false
    ) { _, _, _ in
      childReady.signal()
      await releaseChild.wait()
      await probe.recordCancellationRequested(Task.isCancelled)
      childFinished.signal()
    }

    do {
      try #require(await childReady.wait())
      await store.cancelEffects(id: id, context: .init(sequence: staleSequence))
      await releaseChild.open()
      try #require(await childFinished.wait())
    } catch {
      await releaseChild.open()
      await store.cancelAllEffects()
      throw error
    }

    #expect(await probe.wasCancellationRequested == false)
    await store.cancelAllEffects()
  }

  @Test("Store cancel-in-flight preserves its current composite wrapper")
  func storeCancelInFlightPreservesCurrentComposite() async throws {
    let store = Store(reducer: CounterFeature(), initialState: .init())
    let id = AnyEffectID(StaticEffectID("sequence-bounded-in-flight-composite"))
    let olderSequence = store.effectBridge.nextSequence()
    let currentSequence = store.effectBridge.nextSequence()
    let olderContext = EffectExecutionContext(cancellationID: id, sequence: olderSequence)
    let currentContext = EffectExecutionContext(cancellationID: id, sequence: currentSequence)
    let olderReady = AsyncTestSignal()
    let releaseOlder = RunStartGate()
    let olderFinished = AsyncTestSignal()
    let currentFinished = AsyncTestSignal()
    let olderProbe = SequenceCancellationProbe()
    let currentProbe = SequenceCancellationProbe()

    await store.runSequentially(
      [.none],
      context: olderContext,
      awaited: false
    ) { _, _, _ in
      olderReady.signal()
      await releaseOlder.wait()
      await olderProbe.recordCancellationRequested(Task.isCancelled)
      olderFinished.signal()
    }

    do {
      try #require(await olderReady.wait())

      await store.runSequentially(
        [.none],
        context: currentContext,
        awaited: false
      ) { _, _, _ in
        await store.cancelInFlightEffects(id: id, context: currentContext)
        await currentProbe.recordCancellationRequested(Task.isCancelled)
        currentFinished.signal()
      }

      try #require(await currentFinished.wait())
      await releaseOlder.open()
      try #require(await olderFinished.wait())
    } catch {
      await releaseOlder.open()
      await store.cancelAllEffects()
      throw error
    }

    #expect(await olderProbe.wasCancellationRequested == true)
    #expect(await currentProbe.wasCancellationRequested == false)
    await store.cancelAllEffects()
  }

  @Test("Store stale outer cancellation preserves a newer inner debounce sleeper")
  func storeStaleOuterCancellationPreservesNewerDebounce() async throws {
    try await assertStaleOuterCancellationPreservesNewerDelayedEffect(.debounce)
  }

  @Test("Store stale outer cancellation preserves a newer inner throttle drain")
  func storeStaleOuterCancellationPreservesNewerThrottle() async throws {
    try await assertStaleOuterCancellationPreservesNewerDelayedEffect(.throttle)
  }

  @Test("Throttle rejects an older clock read after newer state finishes")
  func throttleRejectsOlderClockReadAfterNewerFinish() async throws {
    let timingID = AnyEffectID(StaticEffectID("throttle-admission-tombstone"))
    let clockReads = FirstClockReadGate()
    let newerFinished = AsyncTestSignal()
    let staleExecutionProbe = InstrumentationProbe()
    let store = Store(
      reducer: CounterFeature(),
      initialState: .init(),
      clock: .init(
        now: { await clockReads.now() },
        sleep: { _ in }
      )
    )
    let staleEffect = EffectTask<CounterFeature.Action>.run { _, _ in
      staleExecutionProbe.record("stale")
    }
    .throttle(timingID, for: .seconds(60), leading: true, trailing: false)
    let staleWalk = Task { @MainActor in
      await store.walkEffect(
        staleEffect,
        context: .init(sequence: 1),
        awaited: true
      )
    }

    do {
      try #require(await clockReads.firstReadStarted.wait())

      let newerEffect = EffectTask<CounterFeature.Action>.run { _, _ in
        newerFinished.signal()
      }
      .throttle(timingID, for: .seconds(60), leading: false, trailing: true)
      await store.walkEffect(
        newerEffect,
        context: .init(sequence: 2),
        awaited: true
      )
      try #require(await newerFinished.wait())

      #expect(store.throttleState.scope(for: timingID) == nil)
      #expect(store.throttleState.latestAdmissionSequence(for: timingID) == 2)

      await clockReads.release()
      _ = await staleWalk.result
    } catch {
      await clockReads.release()
      await store.cancelAllEffects()
      _ = await staleWalk.result
      throw error
    }

    #expect(staleExecutionProbe.events.isEmpty)
    #expect(store.throttleState.latestAdmissionSequence(for: timingID) == nil)
    await store.cancelAllEffects()
  }

  @Test("Suppressed non-trailing throttle does not steal active delayed ownership")
  func suppressedNonTrailingThrottleKeepsActiveOwner() async throws {
    let timingID = AnyEffectID(StaticEffectID("throttle-active-owner"))
    let firstOuterID = AnyEffectID(StaticEffectID("throttle-active-owner-first"))
    let suppressedOuterID = AnyEffectID(StaticEffectID("throttle-active-owner-suppressed"))
    let sleepProbe = CancellationAwareSleepProbe()
    let instant = ContinuousClock().now
    let store = Store(
      reducer: CounterFeature(),
      initialState: .init(),
      clock: .init(
        now: { instant },
        sleep: { _ in try await sleepProbe.sleep() }
      )
    )
    let delayedEffect = EffectTask<CounterFeature.Action>.run { _, _ in }
      .throttle(timingID, for: .seconds(60), leading: false, trailing: true)

    do {
      await store.walkEffect(
        delayedEffect,
        context: .init(cancellationID: firstOuterID, sequence: 1),
        awaited: false
      )
      try #require(await sleepProbe.started.wait())

      let suppressedEffect = EffectTask<CounterFeature.Action>.run { _, _ in }
        .throttle(timingID, for: .seconds(60), leading: true, trailing: false)
      await store.walkEffect(
        suppressedEffect,
        context: .init(cancellationID: suppressedOuterID, sequence: 2),
        awaited: true
      )

      #expect(store.throttleState.scope(for: timingID)?.contains(firstOuterID) == true)
      #expect(store.throttleState.scope(for: timingID)?.contains(suppressedOuterID) == false)
      #expect(store.throttleState.latestAdmissionSequence(for: timingID) == nil)

      await store.cancelEffects(id: firstOuterID, context: .init(sequence: 1))
      try #require(await sleepProbe.cancelled.wait())
    } catch {
      await sleepProbe.release()
      await store.cancelAllEffects()
      throw error
    }

    #expect(store.throttleState.scope(for: timingID) == nil)
    #expect(store.throttleState.latestAdmissionSequence(for: timingID) == nil)
    await store.cancelAllEffects()
  }

  @Test("Awaited concatenate waits for trailing throttle nested run before next effect")
  func awaitedConcatenateWaitsForTrailingThrottleNestedRun() async throws {
    let timingID = AnyEffectID(StaticEffectID("awaited-trailing-throttle"))
    let sleepProbe = CancellationAwareSleepProbe()
    let trailingRunStarted = AsyncTestSignal()
    let trailingRunFinished = AsyncTestSignal()
    let nextRunStarted = AsyncTestSignal()
    let releaseTrailingRun = RunStartGate()
    let orderProbe = InstrumentationProbe()
    let instant = ContinuousClock().now
    let store = Store(
      reducer: CounterFeature(),
      initialState: .init(),
      clock: .init(
        now: { instant },
        sleep: { _ in try await sleepProbe.sleep() }
      )
    )
    let trailingEffect = EffectTask<CounterFeature.Action>.run { _, _ in
      orderProbe.record("trailing-start")
      trailingRunStarted.signal()
      await releaseTrailingRun.wait()
      orderProbe.record("trailing-finish")
      trailingRunFinished.signal()
    }
    .throttle(timingID, for: .seconds(60), leading: false, trailing: true)
    let effect = EffectTask<CounterFeature.Action>.concatenate(
      trailingEffect,
      .run { _, _ in
        orderProbe.record("next-start")
        nextRunStarted.signal()
      }
    )
    let sequence = store.effectBridge.nextSequence()
    let walk = Task { @MainActor in
      await store.walkEffect(
        effect,
        context: .init(sequence: sequence),
        awaited: true
      )
    }

    do {
      try #require(await sleepProbe.started.wait())
      #expect(orderProbe.events.isEmpty)

      await sleepProbe.release()
      try #require(await trailingRunStarted.wait())
      #expect(orderProbe.events == ["trailing-start"])

      await releaseTrailingRun.open()
      try #require(await trailingRunFinished.wait())
      try #require(await nextRunStarted.wait())
      _ = await walk.result
    } catch {
      await sleepProbe.release()
      await releaseTrailingRun.open()
      await store.cancelAllEffects()
      _ = await walk.result
      throw error
    }

    #expect(orderProbe.events == ["trailing-start", "trailing-finish", "next-start"])
    await store.cancelAllEffects()
  }

  @Test("Awaited concatenate waits for debounce nested run before next effect")
  func awaitedConcatenateWaitsForDebounceNestedRun() async throws {
    let timingID = AnyEffectID(StaticEffectID("awaited-debounce"))
    let clock = ManualTestClock()
    let debouncedRunStarted = AsyncTestSignal()
    let debouncedRunFinished = AsyncTestSignal()
    let nextRunStarted = AsyncTestSignal()
    let releaseDebouncedRun = RunStartGate()
    let orderProbe = InstrumentationProbe()
    let store = Store(
      reducer: CounterFeature(),
      initialState: .init(),
      clock: .manual(clock)
    )
    let debouncedEffect = EffectTask<CounterFeature.Action>.run { _, _ in
      orderProbe.record("debounced-start")
      debouncedRunStarted.signal()
      await releaseDebouncedRun.wait()
      orderProbe.record("debounced-finish")
      debouncedRunFinished.signal()
    }
    .debounce(timingID, for: .seconds(60))
    let effect = EffectTask<CounterFeature.Action>.concatenate(
      debouncedEffect,
      .run { _, _ in
        orderProbe.record("next-start")
        nextRunStarted.signal()
      }
    )
    let sequence = store.effectBridge.nextSequence()
    let walk = Task { @MainActor in
      await store.walkEffect(
        effect,
        context: .init(sequence: sequence),
        awaited: true
      )
    }

    do {
      try #require(
        await waitUntilAsync(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
          await clock.sleeperCount == 1
        }
      )
      #expect(orderProbe.events.isEmpty)

      await clock.advance(by: .seconds(60))
      try #require(await debouncedRunStarted.wait())
      #expect(orderProbe.events == ["debounced-start"])

      await releaseDebouncedRun.open()
      try #require(await debouncedRunFinished.wait())
      try #require(await nextRunStarted.wait())
      _ = await walk.result
    } catch {
      await releaseDebouncedRun.open()
      await store.cancelAllEffects()
      _ = await walk.result
      throw error
    }

    #expect(orderProbe.events == ["debounced-start", "debounced-finish", "next-start"])
    await store.cancelAllEffects()
  }

  @Test("Trailing drain uses latest context and keeps awaited requirement across replacement")
  func trailingDrainKeepsAwaitedRequirementAcrossReplacement() async throws {
    let timingID = AnyEffectID(StaticEffectID("monotonic-awaited-trailing-throttle"))
    let schedulingContext = EffectExecutionContext(cancellationID: timingID, sequence: 1)
    let replacementContext = EffectExecutionContext(cancellationID: timingID, sequence: 2)
    let sleepProbe = CancellationAwareSleepProbe()
    let didRecurse = AsyncTestSignal()
    let awaitedProbe = InstrumentationProbe()
    let instant = ContinuousClock().now
    let store = Store(
      reducer: CounterFeature(),
      initialState: .init(),
      clock: .init(
        now: { instant },
        sleep: { _ in try await sleepProbe.sleep() }
      )
    )

    store.throttleState.storePending(
      .none,
      context: schedulingContext,
      requiresAwaitedCompletion: true,
      for: timingID
    )
    let trailingTask = store.scheduleTrailingDrain(
      for: timingID,
      interval: .seconds(60),
      schedulingContext: schedulingContext,
      awaited: false
    ) { [store] _, context, awaited in
      _ = store.count
      awaitedProbe.record("sequence:\(context?.sequence ?? 0)")
      awaitedProbe.record("awaited:\(awaited)")
      didRecurse.signal()
    }

    do {
      try #require(await sleepProbe.started.wait())
      store.throttleState.storePending(
        .send(.increment),
        context: replacementContext,
        requiresAwaitedCompletion: false,
        for: timingID
      )
      #expect(store.throttleState.pending(for: timingID)?.requiresAwaitedCompletion == true)
      #expect(store.throttleState.pending(for: timingID)?.context?.sequence == 2)
      #expect(
        effectOperationSignature(store.throttleState.pending(for: timingID)?.effect ?? .none)
          == "send(increment)"
      )

      await sleepProbe.release()
      try #require(await didRecurse.wait())
      _ = await trailingTask.result
    } catch {
      await sleepProbe.release()
      trailingTask.cancel()
      _ = await trailingTask.result
      throw error
    }

    #expect(awaitedProbe.events == ["sequence:2", "awaited:true"])
    await store.cancelAllEffects()
  }

  @Test("Debounce reports scheduling context and clears state when the store clock fails")
  func debounceClearsStateAfterClockFailure() async {
    let timingID = AnyEffectID(StaticEffectID("debounce-clock-failure"))
    let dropProbe = InstrumentationProbe()
    let instant = ContinuousClock().now
    let store = Store(
      reducer: CounterFeature(),
      initialState: .init(),
      clock: .init(
        now: { instant },
        sleep: { _ in throw TestClockFailure() }
      ),
      instrumentation: .init(
        didDropAction: { event in
          guard event.reason == .throttledOrDebouncedCancellation else { return }
          dropProbe.record(
            "drop:\(event.cancellationID?.description ?? "nil"):\(event.sequence.map(String.init) ?? "nil")"
          )
        }
      )
    )
    let sequence = store.effectBridge.nextSequence()
    let context = EffectExecutionContext(cancellationID: timingID, sequence: sequence)
    let scope = DelayedEffectScope(ownerID: timingID, sequence: sequence)
    let recurseProbe = InstrumentationProbe()

    let task = await store.scheduleDebounce(
      .none,
      id: timingID,
      interval: .seconds(60),
      context: context,
      scope: scope,
      nestedAwaited: true
    ) { _, _, _ in
      recurseProbe.record("recursed")
    }
    if let task {
      _ = await task.result
    }

    #expect(store.effectBridge.debounceScope(for: timingID) == nil)
    #expect(store.effectBridge.debounceGeneration(for: timingID) == nil)
    #expect(recurseProbe.events.isEmpty)
    #expect(dropProbe.events == ["drop:debounce-clock-failure:\(sequence)"])
  }

  @Test("Trailing throttle reports scheduling context and clears state on clock failure")
  func trailingThrottleClearsStateAfterClockFailure() async throws {
    let timingID = AnyEffectID(StaticEffectID("throttle-clock-failure"))
    let sleepStarted = AsyncTestSignal()
    let releaseSleep = RunStartGate()
    let dropProbe = InstrumentationProbe()
    let instant = ContinuousClock().now
    let store = Store(
      reducer: CounterFeature(),
      initialState: .init(),
      clock: .init(
        now: { instant },
        sleep: { _ in
          sleepStarted.signal()
          await releaseSleep.wait()
          throw TestClockFailure()
        }
      ),
      instrumentation: .init(
        didDropAction: { event in
          guard event.reason == .throttledOrDebouncedCancellation else { return }
          dropProbe.record(
            "drop:\(event.cancellationID?.description ?? "nil"):\(event.sequence.map(String.init) ?? "nil")"
          )
        }
      )
    )
    let effect = EffectTask<CounterFeature.Action>.none
      .throttle(timingID, for: .seconds(60), leading: false, trailing: true)

    let walk = Task { @MainActor in
      await store.walkEffect(
        effect,
        context: .init(sequence: 1),
        awaited: true
      )
    }

    do {
      try #require(await sleepStarted.wait())
      await store.walkEffect(
        effect,
        context: .init(sequence: 2),
        awaited: false
      )
      #expect(store.throttleState.scope(for: timingID)?.sequence == 2)
      #expect(store.throttleState.pending(for: timingID)?.context?.sequence == 2)
      await releaseSleep.open()
      _ = await walk.result
    } catch {
      await releaseSleep.open()
      walk.cancel()
      _ = await walk.result
      throw error
    }

    #expect(store.throttleState.scope(for: timingID) == nil)
    #expect(store.throttleState.generation(for: timingID) == nil)
    #expect(store.throttleState.pending(for: timingID) == nil)
    #expect(store.throttleState.windowEnd(for: timingID) == nil)
    #expect(store.throttleState.trailingTask(for: timingID) == nil)
    #expect(store.throttleState.latestAdmissionSequence(for: timingID) == nil)
    #expect(dropProbe.events == ["drop:throttle-clock-failure:1"])
  }

  private func assertStaleOuterCancellationPreservesNewerDelayedEffect(
    _ kind: SequenceBoundedDelayedEffectKind
  ) async throws {
    let staleCancellationReady = AsyncTestSignal()
    let releaseStaleCancellation = RunStartGate()
    let staleCancellationApplied = AsyncTestSignal()
    let sleepProbe = CancellationAwareSleepProbe()
    let clock = StoreClock(
      now: { ContinuousClock().now },
      sleep: { _ in
        try await sleepProbe.sleep()
      }
    )
    let store = Store(
      reducer: SequenceBoundedDelayedEffectFeature(
        kind: kind,
        staleCancellationReady: staleCancellationReady,
        releaseStaleCancellation: releaseStaleCancellation,
        staleCancellationApplied: staleCancellationApplied
      ),
      initialState: .init(),
      clock: clock
    )

    do {
      store.send(.scheduleStaleCancellation)
      try #require(await staleCancellationReady.wait())

      store.send(.startNewerDelayedEffect)
      try #require(await sleepProbe.started.wait())

      await releaseStaleCancellation.open()
      try #require(await staleCancellationApplied.wait())

      #expect(sleepProbe.isCancelled == false)

      await store.cancelEffects(identifiedBy: "sequence-bounded-delayed-outer")
      try #require(await sleepProbe.cancelled.wait())
    } catch {
      await releaseStaleCancellation.open()
      await sleepProbe.release()
      await store.cancelAllEffects()
      throw error
    }

    #expect(sleepProbe.isCancelled)
    await store.cancelAllEffects()
  }

  @Test("Store .run keeps FIFO ordering for multiple emitted actions")
  func storeRunEmissionOrderingRemainsFIFO() async throws {
    let clock = ManualTestClock()
    let emittedFirst = AsyncTestSignal()
    let finished = AsyncTestSignal()
    let store = Store(
      reducer: RunEmissionBoundaryFeature(),
      initialState: .init(),
      clock: .manual(clock),
      instrumentation: .init(
        didFinishRun: { _ in finished.signal() },
        didEmitAction: { event in
          if event.action == ._record("ordered-1") {
            emittedFirst.signal()
          }
        }
      )
    )

    store.send(.start("ordered"))
    try #require(await emittedFirst.wait())
    #expect(store.events == ["ordered-1"])
    try #require(
      await waitUntilAsync(timeout: .seconds(60), pollInterval: .milliseconds(1)) {
        await clock.sleeperCount == 1
      }
    )

    await clock.advance(by: .milliseconds(100))
    try #require(await finished.wait())

    #expect(store.events == ["ordered-1", "ordered-2", "ordered-3"])
  }

  @Test("Store .run remains reusable after cancel and restart")
  func storeRunEmissionRecoversAfterRestart() async throws {
    let clock = ManualTestClock()
    let emittedFirst = AsyncTestSignal()
    let emittedSecondFirst = AsyncTestSignal()
    let emittedSecondLast = AsyncTestSignal()
    let store = Store(
      reducer: RunEmissionBoundaryFeature(),
      initialState: .init(),
      clock: .manual(clock),
      instrumentation: .init(
        didEmitAction: { event in
          switch event.action {
          case ._record("first-1"):
            emittedFirst.signal()
          case ._record("second-1"):
            emittedSecondFirst.signal()
          case ._record("second-3"):
            emittedSecondLast.signal()
          default:
            break
          }
        }
      )
    )

    store.send(.start("first"))
    try #require(await emittedFirst.wait())
    #expect(store.events.contains("first-1"))
    try #require(
      await waitUntilAsync(timeout: .seconds(60), pollInterval: .milliseconds(1)) {
        await clock.sleeperCount == 1
      }
    )

    store.send(.cancel)
    try #require(
      await waitUntilAsync(timeout: .seconds(60), pollInterval: .milliseconds(1)) {
        await clock.sleeperCount == 0
      }
    )

    store.send(.start("second"))
    try #require(await emittedSecondFirst.wait())
    #expect(store.events == ["first-1", "second-1"])
    try #require(
      await waitUntilAsync(timeout: .seconds(60), pollInterval: .milliseconds(1)) {
        await clock.sleeperCount == 1
      }
    )

    await clock.advance(by: .milliseconds(100))
    try #require(await emittedSecondLast.wait())

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

    await waitUntil(timeout: .seconds(5), pollInterval: .milliseconds(10)) {
      store.values.count == 20
    }

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

  @Test("Store cancelAll cancels non-cancellable sequential composite wrappers")
  func storeCancelAllCancelsNonCancellableSequentialCompositeWrapper() async {
    let clock = ManualTestClock()
    let store = Store(
      reducer: NonCancellableSequentialCompositeFeature(),
      initialState: .init(),
      clock: .manual(clock)
    )

    store.send(.start)
    _ = await waitUntilAsync {
      await clock.sleeperCount == 1
    }

    await store.cancelAllEffects()
    await clock.advance(by: .milliseconds(100))
    await drainAsyncWork()

    #expect(store.finished == false)
  }

  @Test("Store outer cancellation reaches already-started nested cancellable runs")
  func storeOuterCancellationCancelsNestedCancellableRun() async {
    let clock = ManualTestClock()
    let store = Store(
      reducer: NestedCancellableFeature(),
      initialState: .init(),
      clock: .manual(clock)
    )

    store.send(.start)
    _ = await waitUntilAsync {
      await clock.sleeperCount == 1
    }

    await store.cancelEffects(identifiedBy: "outer-cancellation")
    await clock.advance(by: .milliseconds(100))
    await drainAsyncWork()

    #expect(store.finished == false)
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
    #expect(!String(reflecting: type(of: reducer)).contains("_ReducerBuilder"))
  }

  @Test("CombineReducers if/else builder paths keep semantics without exposing builder internals")
  func combineReducersEitherBuilderPath() {
    let reducer = BuilderCompositionFeature.eitherBuilder(chooseFirst: false)
    var state = BuilderCompositionFeature.State()

    let effect = reducer.reduce(into: &state, action: .run)

    #expect(state.log == ["second"])
    #expect(effect.isNone)
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
    #expect(!String(reflecting: type(of: reducer)).contains("_ReducerBuilder"))
  }

  @Test("ReducerBuilder preserves concrete composition without existential reducer arrays")
  func combineReducersConcreteWrapperChain() {
    let reducer = BuilderCompositionFeature.straightLineBuilder()
    var state = BuilderCompositionFeature.State()

    let effect = reducer.reduce(into: &state, action: .run)
    let typeDescription = String(reflecting: type(of: reducer))

    #expect(state.log == ["first", "second"])
    #expect(effect.isNone)
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
    #expect(
      await waitUntilAsync(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
        await clock.sleeperCount == 1
      }
    )
    #expect(store.emitted.isEmpty)

    await clock.advance(by: .milliseconds(79))
    #expect(store.emitted.isEmpty)

    await clock.advance(by: .milliseconds(1))
    await waitUntil(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
      store.emitted == [2]
    }
    #expect(store.emitted == [2])
  }

  @Test("Store activates trailing work within a leading-only throttle window")
  func storeActivatesTrailingWorkWithinLeadingOnlyThrottleWindow() async throws {
    let timingID = AnyEffectID(StaticEffectID("store-late-trailing-activation"))
    let clock = ManualTestClock()
    let store = Store(
      reducer: CounterFeature(),
      initialState: .init(),
      clock: .manual(clock)
    )
    let leadingEffect = EffectTask<CounterFeature.Action>.send(.increment)
      .throttle(timingID, for: .milliseconds(80), leading: true, trailing: false)
    let trailingEffect = EffectTask<CounterFeature.Action>.send(.decrement)
      .throttle(timingID, for: .milliseconds(80), leading: false, trailing: true)
    var trailingTask: Task<Void, Never>?

    do {
      await store.walkEffect(
        leadingEffect,
        context: .init(sequence: 1),
        awaited: true
      )

      #expect(store.count == 1)
      #expect(await clock.sleeperCount == 0)
      let originalDeadline = try #require(store.throttleState.windowEnd(for: timingID))
      #expect(store.throttleState.scope(for: timingID)?.sequence == 1)

      await clock.advance(by: .milliseconds(30))
      await store.walkEffect(
        trailingEffect,
        context: .init(sequence: 2),
        awaited: false
      )
      try #require(
        await waitUntilAsync(timeout: .seconds(2), pollInterval: .milliseconds(1)) {
          await clock.sleeperCount == 1
        }
      )
      let activeTrailingTask = try #require(
        store.throttleState.trailingTask(for: timingID)
      )
      trailingTask = activeTrailingTask

      #expect(store.throttleState.windowEnd(for: timingID) == originalDeadline)
      #expect(store.throttleState.scope(for: timingID)?.sequence == 2)
      #expect(store.throttleState.pending(for: timingID)?.context?.sequence == 2)

      await clock.advance(by: .milliseconds(49))

      #expect(store.count == 1)
      #expect(await clock.sleeperCount == 1)
      #expect(store.throttleState.pending(for: timingID) != nil)

      await clock.advance(by: .milliseconds(1))
      try #require(
        await waitUntilAsync(timeout: .seconds(2), pollInterval: .milliseconds(1)) {
          await clock.sleeperCount == 0
        }
      )
      if let trailingTask {
        _ = await trailingTask.result
      }
    } catch {
      await store.cancelAllEffects()
      await clock.advance(by: .milliseconds(80))
      if let trailingTask {
        _ = await trailingTask.result
      }
      throw error
    }

    #expect(store.count == 0)
    #expect(await clock.sleeperCount == 0)
    #expect(store.throttleState.scope(for: timingID) == nil)
    #expect(store.throttleState.generation(for: timingID) == nil)
    #expect(store.throttleState.pending(for: timingID) == nil)
    #expect(store.throttleState.windowEnd(for: timingID) == nil)
    #expect(store.throttleState.trailingTask(for: timingID) == nil)
    #expect(store.throttleState.latestAdmissionSequence(for: timingID) == nil)
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
    #expect(
      await waitUntilAsync(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
        await clock.sleeperCount == 1
      }
    )
    #expect(store.emitted.isEmpty)

    await clock.advance(by: .milliseconds(59))
    #expect(store.emitted.isEmpty)

    await clock.advance(by: .milliseconds(1))
    await waitUntil(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
      store.emitted == [2]
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
    #expect(
      await waitUntilAsync(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
        await clock.sleeperCount == 1
      }
    )
    #expect(store.emitted.isEmpty)

    await clock.advance(by: .milliseconds(79))
    #expect(store.emitted.isEmpty)

    await clock.advance(by: .milliseconds(1))
    await waitUntil(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
      store.emitted == [2]
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

  @Test("Store release breaks awaited trailing throttle composite ownership")
  func storeReleaseBreaksAwaitedTrailingThrottleCompositeOwnership() async throws {
    let clock = ManualTestClock()
    weak var weakStore: Store<AwaitedTrailingReleaseFeature>?

    do {
      var store: Store<AwaitedTrailingReleaseFeature>? = Store(
        reducer: AwaitedTrailingReleaseFeature(),
        initialState: .init(),
        clock: .manual(clock)
      )
      weakStore = store
      store?.send(.start)
      try #require(
        await waitUntilAsync(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
          await clock.sleeperCount == 1
        }
      )
      store = nil
    }

    let released = await waitUntil {
      weakStore == nil
    }
    if !released {
      await clock.advance(by: .seconds(60))
      await waitUntil {
        weakStore == nil
      }
    }
    #expect(released)
    try #require(
      await waitUntilAsync(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
        await clock.sleeperCount == 0
      }
    )
    #expect(weakStore == nil)
  }

  @Test("Store release breaks awaited debounce composite ownership")
  func storeReleaseBreaksAwaitedDebounceCompositeOwnership() async throws {
    let clock = ManualTestClock()
    weak var weakStore: Store<AwaitedDebounceReleaseFeature>?

    do {
      var store: Store<AwaitedDebounceReleaseFeature>? = Store(
        reducer: AwaitedDebounceReleaseFeature(),
        initialState: .init(),
        clock: .manual(clock)
      )
      weakStore = store
      store?.send(.start)
      try #require(
        await waitUntilAsync(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
          await clock.sleeperCount == 1
        }
      )
      store = nil
    }

    let released = await waitUntil {
      weakStore == nil
    }
    if !released {
      await clock.advance(by: .seconds(60))
      await waitUntil {
        weakStore == nil
      }
    }
    #expect(released)
    try #require(
      await waitUntilAsync(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
        await clock.sleeperCount == 0
      }
    )
    #expect(weakStore == nil)
  }

  @Test("Store release breaks awaited run composite ownership")
  func storeReleaseBreaksAwaitedRunCompositeOwnership() async throws {
    let clock = ManualTestClock()
    var store: Store<AwaitedRunReleaseFeature>? = Store(
      reducer: AwaitedRunReleaseFeature(),
      initialState: .init(),
      clock: .manual(clock)
    )
    weak var weakStore: Store<AwaitedRunReleaseFeature>?
    weakStore = store

    do {
      store?.send(.start)
      try #require(
        await waitUntil {
          store?.state.runStarted == true
        }
      )
      try #require(
        await waitUntilAsync(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
          await clock.sleeperCount == 1
        }
      )
      #expect(store?.state.runCompleted == false)
      #expect(store?.state.continued == false)
    } catch {
      await store?.cancelAllEffects()
      await clock.advance(by: .seconds(60))
      store = nil
      throw error
    }

    store = nil
    let released = await waitUntil {
      weakStore == nil
    }
    if !released {
      await clock.advance(by: .seconds(60))
      await waitUntil {
        weakStore == nil
      }
    }

    #expect(released)
    #expect(weakStore == nil)
    try #require(
      await waitUntilAsync(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
        await clock.sleeperCount == 0
      }
    )
  }

  @Test(
    "Store release is not retained by a post-fire delayed nested effect",
    arguments: PostFireDelayedEffectKind.allCases
  )
  func storeReleaseIsNotRetainedByPostFireDelayedNestedEffect(
    kind: PostFireDelayedEffectKind
  ) async throws {
    let clock = ManualTestClock()
    var store: Store<PostFireDelayedReleaseFeature>? = Store(
      reducer: PostFireDelayedReleaseFeature(kind: kind),
      initialState: .init(),
      clock: .manual(clock)
    )
    weak var weakStore: Store<PostFireDelayedReleaseFeature>?
    weakStore = store

    do {
      store?.send(.start)
      try #require(
        await waitUntilAsync(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
          await clock.sleeperCount == 1
        }
      )
      await clock.advance(by: .seconds(60))
      try #require(
        await waitUntil {
          store?.state.nestedStarted == true
        }
      )
      try #require(
        await waitUntilAsync(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
          await clock.sleeperCount == 1
        }
      )
      #expect(store?.state.completed == false)
      #expect(store?.state.continued == false)
      switch kind {
      case .debounce:
        #expect(store?.effectBridge.debounceGeneration(for: kind.outerID) == nil)
      case .trailingThrottle:
        #expect(store?.throttleState.generation(for: kind.outerID) == nil)
      }
    } catch {
      await store?.cancelAllEffects()
      await clock.advance(by: .seconds(60))
      store = nil
      throw error
    }

    store = nil
    let released = await waitUntil {
      weakStore == nil
    }
    if !released {
      await clock.advance(by: .seconds(60))
      await waitUntil {
        weakStore == nil
      }
    }

    #expect(released)
    #expect(weakStore == nil)
    try #require(
      await waitUntilAsync(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
        await clock.sleeperCount == 0
      }
    )
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
    let task = await store.startRun(
      priority: nil,
      operation: { _, _ in
        await probe.markStarted()
      }, context: context)
    _ = await task.result

    let metrics = await store.effectRuntimeMetrics
    #expect(metrics.preparedRuns == 1)
    #expect(metrics.finishedRuns == 1)
    #expect(metrics.cancellations == 1)
    #expect(await probe.started == 0)
  }

  @Test("EffectRuntime counts a cancelled token finish only once")
  func effectRuntimeCancelledTokenFinishIsIdempotent() async {
    let runtime = EffectRuntime<CounterFeature.Action>()
    let token = UUID()
    let gate = RunStartGate()
    let task = Task<Void, Never> {}

    await runtime.registerAndStart(
      token: token,
      id: nil,
      sequence: 1,
      task: task,
      gate: gate
    )
    await runtime.cancelAll(upTo: 1)
    await runtime.finish(token: token)
    await runtime.finish(token: token)

    let metrics = await runtime.metricsSnapshot()
    #expect(metrics.preparedRuns == 1)
    #expect(metrics.attachedRuns == 1)
    #expect(metrics.finishedRuns == 1)
    #expect(metrics.cancellations == 1)
  }

  @Test("EffectRuntime cancellation preserves registered runs above its sequence boundary")
  func effectRuntimeCancellationPreservesNewerRegisteredRuns() async {
    let runtime = EffectRuntime<CounterFeature.Action>()
    let id = AnyEffectID(StaticEffectID("runtime-sequence-boundary"))
    let olderToken = UUID()
    let newerToken = UUID()
    let olderHold = LateSendGate()
    let newerHold = LateSendGate()
    let olderTask = Task<Void, Never> {
      await olderHold.wait()
    }
    let newerTask = Task<Void, Never> {
      await newerHold.wait()
    }

    await runtime.registerAndStart(
      token: olderToken,
      id: id,
      sequence: 1,
      task: olderTask,
      gate: RunStartGate()
    )
    await runtime.registerAndStart(
      token: newerToken,
      id: id,
      sequence: 2,
      task: newerTask,
      gate: RunStartGate()
    )

    await runtime.cancel(id: id, upTo: 1)

    #expect(olderTask.isCancelled)
    #expect(newerTask.isCancelled == false)
    switch await runtime.emissionDecision(token: newerToken, id: id, sequence: 2) {
    case .allow:
      break
    case .drop(let reason):
      Issue.record("Expected the newer run to remain active, but it was dropped: \(reason)")
    }

    await olderHold.open()
    await newerHold.open()
    _ = await olderTask.result
    _ = await newerTask.result
    await runtime.finish(token: olderToken)
    await runtime.finish(token: newerToken)
  }

  @Test("EffectRuntime cancelAll preserves registered runs above its sequence boundary")
  func effectRuntimeCancelAllPreservesNewerRegisteredRuns() async {
    let runtime = EffectRuntime<CounterFeature.Action>()
    let olderToken = UUID()
    let newerToken = UUID()
    let olderHold = LateSendGate()
    let newerHold = LateSendGate()
    let olderTask = Task<Void, Never> {
      await olderHold.wait()
    }
    let newerTask = Task<Void, Never> {
      await newerHold.wait()
    }

    await runtime.registerAndStart(
      token: olderToken,
      id: nil,
      sequence: 1,
      task: olderTask,
      gate: RunStartGate()
    )
    await runtime.registerAndStart(
      token: newerToken,
      id: nil,
      sequence: 2,
      task: newerTask,
      gate: RunStartGate()
    )

    await runtime.cancelAll(upTo: 1)

    #expect(olderTask.isCancelled)
    #expect(newerTask.isCancelled == false)
    switch await runtime.emissionDecision(token: newerToken, id: nil, sequence: 2) {
    case .allow:
      break
    case .drop(let reason):
      Issue.record("Expected the newer run to remain active, but it was dropped: \(reason)")
    }

    await olderHold.open()
    await newerHold.open()
    _ = await olderTask.result
    _ = await newerTask.result
    await runtime.finish(token: olderToken)
    await runtime.finish(token: newerToken)
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
