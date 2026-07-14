// MARK: - StoreEffectBridgeIsolationTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import Testing

@testable import InnoFlowCore

/// Regression suite for the documented MainActor isolation contract on
/// ``StoreEffectBridge``. The test bodies assert behavior, but their main value
/// is structural: the file declares ``@MainActor`` on every test method that
/// invokes the bridge, so removing the class-level isolation from
/// ``StoreEffectBridge`` would surface as a compile error here.
@MainActor
@Suite("StoreEffectBridge isolation contract")
struct StoreEffectBridgeIsolationTests {
  @Test("markCancelledInFlight rolls the boundary back by exactly one sequence")
  func markCancelledInFlightRollsBackByOne() {
    let bridge = StoreEffectBridge<Int>()
    let id = AnyEffectID(StaticEffectID("isolation.in-flight"))

    let s1 = bridge.nextSequence()
    let s2 = bridge.nextSequence()

    let boundary = bridge.markCancelledInFlight(id: id, upTo: s2)

    #expect(boundary == s2 - 1)
    #expect(bridge.shouldStart(sequence: s1, cancellationID: id) == false)
    #expect(bridge.shouldStart(sequence: s2, cancellationID: id) == true)
  }

  @Test("markCancelledInFlight is monotonic — earlier calls cannot lower the boundary")
  func markCancelledInFlightIsMonotonic() {
    let bridge = StoreEffectBridge<Int>()
    let id = AnyEffectID(StaticEffectID("isolation.monotonic"))

    _ = bridge.nextSequence()
    let s2 = bridge.nextSequence()
    let s3 = bridge.nextSequence()

    _ = bridge.markCancelledInFlight(id: id, upTo: s3)
    let lowered = bridge.markCancelledInFlight(id: id, upTo: s2)

    // The second call returns upTo - 1 (= s2 - 1), but the stored boundary
    // was already set to s3 - 1 by the first call and is not lowered,
    // so s2 (<= s3 - 1) remains cancelled.
    #expect(lowered == s2 - 1)
    #expect(bridge.shouldStart(sequence: s2, cancellationID: id) == false)
    #expect(bridge.shouldStart(sequence: s3, cancellationID: id) == true)
  }

  @Test("markCancelledInFlight saturates at zero when no sequences have been issued")
  func markCancelledInFlightSaturatesAtZero() {
    let bridge = StoreEffectBridge<Int>()
    let id = AnyEffectID(StaticEffectID("isolation.saturate"))

    let boundary = bridge.markCancelledInFlight(id: id, upTo: 0)

    #expect(boundary == 0)
    // sequence 0 is never issued by `nextSequence`, but if a caller probes it
    // the bridge should still report it as cancelled because boundary == 0.
    #expect(bridge.shouldStart(sequence: 0, cancellationID: id) == false)
  }

  @Test("markCancelled and markCancelledInFlight maintain independent semantics")
  func cancelVariantsHaveDistinctSemantics() {
    let bridge = StoreEffectBridge<Int>()
    let id = AnyEffectID(StaticEffectID("isolation.distinct"))

    let s1 = bridge.nextSequence()
    let s2 = bridge.nextSequence()

    // markCancelled cancels through `s2` inclusive.
    let inclusive = bridge.markCancelled(id: id, upTo: s2)
    #expect(inclusive == s2)
    #expect(bridge.shouldStart(sequence: s1, cancellationID: id) == false)
    #expect(bridge.shouldStart(sequence: s2, cancellationID: id) == false)

    // markCancelledInFlight on a fresh bridge would have left s2 alive; here
    // the inclusive boundary is already higher, so the lower boundary is
    // dropped on the floor — verifying monotonicity across both variants.
    let inFlight = bridge.markCancelledInFlight(id: id, upTo: s2)
    #expect(inFlight == s2 - 1)
    #expect(bridge.shouldStart(sequence: s2, cancellationID: id) == false)
  }

  @Test("nested cancellation contexts honor every active boundary")
  func nestedCancellationContextChecksEveryBoundary() {
    let bridge = StoreEffectBridge<Int>()
    let outer = AnyEffectID(StaticEffectID("isolation.outer"))
    let inner = AnyEffectID(StaticEffectID("isolation.inner"))
    let sequence = bridge.nextSequence()
    let context = EffectExecutionContext(cancellationIDs: [outer, inner], sequence: sequence)

    bridge.markCancelled(id: outer, upTo: sequence)

    #expect(bridge.shouldProceed(context: context) == false)
  }

  @Test("ID cancellation honors its effective boundary and preserves newer indexes")
  func idCancellationHonorsEffectiveCompositeBoundary() async {
    let bridge = StoreEffectBridge<Int>()
    let id = AnyEffectID(StaticEffectID("composite.sequence.id"))
    let staleSequence = bridge.nextSequence()
    let effectiveSequence = bridge.nextSequence()
    let newerSequence = bridge.nextSequence()
    let effectiveToken = UUID()
    let newerToken = UUID()
    let hold = RunStartGate()
    let effectiveTask = Task<Void, Never> {
      await hold.wait()
    }
    let newerTask = Task<Void, Never> {
      await hold.wait()
    }

    bridge.registerCompositeTask(
      token: effectiveToken,
      id: id,
      sequence: effectiveSequence,
      task: effectiveTask
    )
    bridge.registerCompositeTask(
      token: newerToken,
      id: id,
      sequence: newerSequence,
      task: newerTask
    )

    bridge.markCancelled(id: id, upTo: effectiveSequence)
    let staleBoundary = bridge.markCancelled(id: id, upTo: staleSequence)
    bridge.cancelCompositeTasks(id: id, upTo: staleBoundary)

    #expect(staleBoundary == staleSequence)
    #expect(effectiveTask.isCancelled)
    #expect(newerTask.isCancelled == false)

    bridge.cancelCompositeTasks(id: id, upTo: newerSequence)

    #expect(newerTask.isCancelled)

    await hold.open()
    _ = await effectiveTask.result
    _ = await newerTask.result
  }

  @Test("Cancel all honors its effective boundary and preserves newer indexes")
  func cancelAllHonorsEffectiveCompositeBoundary() async {
    let bridge = StoreEffectBridge<Int>()
    let id = AnyEffectID(StaticEffectID("composite.sequence.all"))
    let staleSequence = bridge.nextSequence()
    let effectiveSequence = bridge.nextSequence()
    let newerSequence = bridge.nextSequence()
    let effectiveToken = UUID()
    let newerToken = UUID()
    let hold = RunStartGate()
    let effectiveTask = Task<Void, Never> {
      await hold.wait()
    }
    let newerTask = Task<Void, Never> {
      await hold.wait()
    }

    bridge.registerCompositeTask(
      token: effectiveToken,
      id: id,
      sequence: effectiveSequence,
      task: effectiveTask
    )
    bridge.registerCompositeTask(
      token: newerToken,
      id: id,
      sequence: newerSequence,
      task: newerTask
    )

    bridge.markCancelledAll(upTo: effectiveSequence)
    let staleBoundary = bridge.markCancelledAll(upTo: staleSequence)
    bridge.cancelAllCompositeTasks(upTo: staleBoundary)

    #expect(staleBoundary == staleSequence)
    #expect(effectiveTask.isCancelled)
    #expect(newerTask.isCancelled == false)

    bridge.cancelCompositeTasks(id: id, upTo: newerSequence)

    #expect(newerTask.isCancelled)

    await hold.open()
    _ = await effectiveTask.result
    _ = await newerTask.result
  }

  @Test("Delayed debounce cancellation honors inherited ID effective boundaries")
  func delayedDebounceHonorsInheritedIDEffectiveBoundary() async throws {
    let bridge = StoreEffectBridge<Int>()
    let outerID = AnyEffectID(StaticEffectID("delayed.debounce.outer"))
    let effectiveID = AnyEffectID(StaticEffectID("delayed.debounce.effective"))
    let newerID = AnyEffectID(StaticEffectID("delayed.debounce.newer"))
    let staleSequence = bridge.nextSequence()
    let effectiveSequence = bridge.nextSequence()
    let newerSequence = bridge.nextSequence()
    let hold = RunStartGate()
    let effectiveTask = Task<Void, Never> { await hold.wait() }
    let newerTask = Task<Void, Never> { await hold.wait() }
    let effectiveScope = DelayedEffectScope(
      ownerID: effectiveID,
      inheritedCancellationIDs: [outerID],
      sequence: effectiveSequence
    )
    let newerScope = DelayedEffectScope(
      ownerID: newerID,
      inheritedCancellationIDs: [outerID],
      sequence: newerSequence
    )

    let effectiveGeneration = try #require(bridge.beginDebounce(effectiveScope))
    let newerGeneration = try #require(bridge.beginDebounce(newerScope))
    #expect(
      bridge.setDebounceDelayTask(
        effectiveTask,
        for: effectiveID,
        generation: effectiveGeneration
      ))
    #expect(
      bridge.setDebounceDelayTask(
        newerTask,
        for: newerID,
        generation: newerGeneration
      ))

    bridge.markCancelled(id: outerID, upTo: effectiveSequence)
    let staleBoundary = bridge.markCancelled(id: outerID, upTo: staleSequence)
    await bridge.cancelEffects(id: outerID, upTo: staleBoundary)

    #expect(effectiveTask.isCancelled)
    #expect(newerTask.isCancelled == false)
    #expect(bridge.debounceScope(for: effectiveID) == nil)
    #expect(bridge.debounceScope(for: newerID)?.sequence == newerSequence)

    await bridge.cancelEffects(id: outerID, upTo: newerSequence)
    #expect(newerTask.isCancelled)

    await hold.open()
    _ = await effectiveTask.result
    _ = await newerTask.result
  }

  @Test("Debounce registration rejects older scopes and replaces equal sequences")
  func debounceRegistrationHonorsSequenceOwnership() async throws {
    let bridge = StoreEffectBridge<Int>()
    let id = AnyEffectID(StaticEffectID("delayed.debounce.registration"))
    let hold = RunStartGate()
    let firstTask = Task<Void, Never> { await hold.wait() }
    let staleRegistrationTask = Task<Void, Never> { await hold.wait() }
    let replacementTask = Task<Void, Never> { await hold.wait() }
    let olderScope = DelayedEffectScope(ownerID: id, sequence: 1)
    let currentScope = DelayedEffectScope(ownerID: id, sequence: 2)

    let firstGeneration = try #require(bridge.beginDebounce(currentScope))
    #expect(
      bridge.setDebounceDelayTask(
        firstTask,
        for: id,
        generation: firstGeneration
      ))

    #expect(bridge.beginDebounce(olderScope) == nil)
    #expect(firstTask.isCancelled == false)

    let replacementGeneration = try #require(bridge.beginDebounce(currentScope))
    #expect(replacementGeneration > firstGeneration)
    #expect(firstTask.isCancelled)

    #expect(
      bridge.setDebounceDelayTask(
        staleRegistrationTask,
        for: id,
        generation: firstGeneration
      ) == false)
    #expect(staleRegistrationTask.isCancelled)

    #expect(
      bridge.setDebounceDelayTask(
        replacementTask,
        for: id,
        generation: replacementGeneration
      ))
    #expect(replacementTask.isCancelled == false)

    bridge.clearAllDelayedState()
    #expect(replacementTask.isCancelled)

    await hold.open()
    _ = await firstTask.result
    _ = await staleRegistrationTask.result
    _ = await replacementTask.result
  }

  @Test("Delayed cancel-all honors effective global boundaries")
  func delayedCancelAllHonorsEffectiveGlobalBoundary() async throws {
    let bridge = StoreEffectBridge<Int>()
    let effectiveThrottleID = AnyEffectID(StaticEffectID("delayed.throttle.effective"))
    let newerThrottleID = AnyEffectID(StaticEffectID("delayed.throttle.newer"))
    let effectiveDebounceID = AnyEffectID(StaticEffectID("delayed.debounce.global.effective"))
    let newerDebounceID = AnyEffectID(StaticEffectID("delayed.debounce.global.newer"))
    let staleSequence = bridge.nextSequence()
    let effectiveSequence = bridge.nextSequence()
    let newerSequence = bridge.nextSequence()
    let hold = RunStartGate()
    let effectiveThrottleTask = Task<Void, Never> { await hold.wait() }
    let newerThrottleTask = Task<Void, Never> { await hold.wait() }
    let effectiveDebounceTask = Task<Void, Never> { await hold.wait() }
    let newerDebounceTask = Task<Void, Never> { await hold.wait() }
    let effectiveThrottleScope = DelayedEffectScope(
      ownerID: effectiveThrottleID,
      sequence: effectiveSequence
    )
    let newerThrottleScope = DelayedEffectScope(
      ownerID: newerThrottleID,
      sequence: newerSequence
    )

    #expect(bridge.throttleState.beginAdmission(effectiveThrottleScope))
    #expect(bridge.throttleState.admit(effectiveThrottleScope))
    #expect(bridge.throttleState.setScope(effectiveThrottleScope))
    bridge.throttleState.endAdmission(for: effectiveThrottleID)
    bridge.throttleState.setWindowEnd(ContinuousClock().now, for: effectiveThrottleID)
    _ = bridge.throttleState.nextGeneration(for: effectiveThrottleID)
    bridge.throttleState.setTrailingTask(effectiveThrottleTask, for: effectiveThrottleID)

    #expect(bridge.throttleState.beginAdmission(newerThrottleScope))
    #expect(bridge.throttleState.admit(newerThrottleScope))
    #expect(bridge.throttleState.setScope(newerThrottleScope))
    bridge.throttleState.endAdmission(for: newerThrottleID)
    bridge.throttleState.setWindowEnd(ContinuousClock().now, for: newerThrottleID)
    _ = bridge.throttleState.nextGeneration(for: newerThrottleID)
    bridge.throttleState.setTrailingTask(newerThrottleTask, for: newerThrottleID)

    let effectiveDebounceGeneration = try #require(
      bridge.beginDebounce(
        .init(ownerID: effectiveDebounceID, sequence: effectiveSequence)
      ))
    #expect(
      bridge.setDebounceDelayTask(
        effectiveDebounceTask,
        for: effectiveDebounceID,
        generation: effectiveDebounceGeneration
      ))

    let newerDebounceGeneration = try #require(
      bridge.beginDebounce(
        .init(ownerID: newerDebounceID, sequence: newerSequence)
      ))
    #expect(
      bridge.setDebounceDelayTask(
        newerDebounceTask,
        for: newerDebounceID,
        generation: newerDebounceGeneration
      ))

    bridge.markCancelledAll(upTo: effectiveSequence)
    let staleBoundary = bridge.markCancelledAll(upTo: staleSequence)
    await bridge.cancelAllEffects(upTo: staleBoundary)

    #expect(effectiveThrottleTask.isCancelled)
    #expect(effectiveDebounceTask.isCancelled)
    #expect(newerThrottleTask.isCancelled == false)
    #expect(newerDebounceTask.isCancelled == false)
    #expect(bridge.throttleState.scope(for: effectiveThrottleID) == nil)
    #expect(bridge.throttleState.scope(for: newerThrottleID)?.sequence == newerSequence)
    #expect(bridge.debounceScope(for: effectiveDebounceID) == nil)
    #expect(bridge.debounceScope(for: newerDebounceID)?.sequence == newerSequence)

    await bridge.cancelAllEffects(upTo: newerSequence)
    #expect(newerThrottleTask.isCancelled)
    #expect(newerDebounceTask.isCancelled)

    await hold.open()
    _ = await effectiveThrottleTask.result
    _ = await newerThrottleTask.result
    _ = await effectiveDebounceTask.result
    _ = await newerDebounceTask.result
  }
}
