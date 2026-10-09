// MARK: - EffectCancellationScopeTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import Testing

@testable import InnoFlowCore

@MainActor
@Suite("Effect Cancellation Scope Tests", .serialized)
struct EffectCancellationScopeTests {
  @Test("Cancellation before ID discovery creates a cancelled exact token")
  func cancellationBeforeIDDiscoveryStaysEffective() {
    let boundaries = EffectCancellationBoundaries()
    let id = AnyEffectID(StaticEffectID("scope.future"))
    let sequence = boundaries.nextSequence()
    var context: EffectExecutionContext? = boundaries.makeContext(
      sequence: sequence,
      potentialCancellationIDs: [id]
    )

    boundaries.markCancelled(id: id, upTo: sequence)

    #expect(boundaries.retainedCancellationIDCount == 1)
    let discovered = EffectExecutionContext.withCancellation(id, on: context)
    #expect(discovered.shouldProceed == false)

    context = nil
    _ = discovered
  }

  @Test("Rediscovered ID stays cancelled after its first exact token is released")
  func rediscoveredIDKeepsPendingCancellation() {
    let boundaries = EffectCancellationBoundaries()
    let id = AnyEffectID(StaticEffectID("scope.rediscovered"))
    let sequence = boundaries.nextSequence()
    let interpreter = boundaries.makeContext(
      sequence: sequence,
      potentialCancellationIDs: [id]
    )
    var first: EffectExecutionContext? = .withCancellation(id, on: interpreter)

    boundaries.markCancelled(id: id, upTo: sequence)
    #expect(first?.shouldProceed == false)

    first = nil
    #expect(boundaries.liveExactTokenCount == 0)
    #expect(boundaries.retainedCancellationIDCount == 1)

    let rediscovered = EffectExecutionContext.withCancellation(id, on: interpreter)
    #expect(rediscovered.shouldProceed == false)
  }

  @Test("Unrelated dynamic cancellations are not retained by a live interpreter")
  func unrelatedDynamicCancellationsStayBounded() {
    let boundaries = EffectCancellationBoundaries()
    let ownedID = AnyEffectID(StaticEffectID("scope.owned"))
    let sequence = boundaries.nextSequence()
    let context = boundaries.makeContext(
      sequence: sequence,
      potentialCancellationIDs: [ownedID]
    )

    for _ in 0..<10_000 {
      boundaries.markCancelled(
        id: AnyEffectID(EffectID(UUID())),
        upTo: sequence
      )
    }

    #expect(context.shouldProceed)
    #expect(boundaries.liveScopeCount == 1)
    #expect(boundaries.liveInterpreterCount == 1)
    #expect(boundaries.retainedPotentialIDCount == 1)
    #expect(boundaries.retainedCancellationIDCount == 0)
    #expect(boundaries.liveExactTokenCount == 0)
  }

  @Test("Frozen exact tokens remain cancelled after interpretation ends")
  func frozenExactTokenOutlivesInterpreter() {
    let boundaries = EffectCancellationBoundaries()
    let id = AnyEffectID(StaticEffectID("scope.exact"))
    let sequence = boundaries.nextSequence()
    let observed = observeFrozenCancellation(boundaries: boundaries, id: id, sequence: sequence)

    #expect(observed.liveInterpreterCount == 0)
    #expect(observed.retainedPotentialIDCount == 0)
    #expect(observed.liveExactTokenCount == 1)
    #expect(observed.shouldProceed == false)
    #expect(observed.retainedCancellationIDCount == 0)
    #expect(boundaries.liveScopeCount == 0)
    #expect(boundaries.liveExactTokenCount == 0)
  }

  @Test("Global cancellation reaches frozen contexts without exact IDs")
  func globalCancellationReachesFrozenContext() {
    let boundaries = EffectCancellationBoundaries()
    let sequence = boundaries.nextSequence()
    var interpreter: EffectExecutionContext? = boundaries.makeContext(sequence: sequence)
    let frozen = interpreter?.frozenForExecution()
    interpreter = nil

    boundaries.markCancelledAll(upTo: sequence)

    #expect(frozen?.shouldProceed == false)
    #expect(boundaries.retainedCancellationIDCount == 0)
  }

  @Test("Released exact token keys disappear while the sequence scope stays alive")
  func releasedExactTokenKeyIsRemoved() {
    let boundaries = EffectCancellationBoundaries()
    let id = AnyEffectID(StaticEffectID("scope.weak-token"))
    let sequence = boundaries.nextSequence()
    let interpreter = boundaries.makeContext(
      sequence: sequence,
      potentialCancellationIDs: [id]
    )
    let scopeKeeper = interpreter.frozenForExecution()
    let observed = observeExactToken(boundaries: boundaries, id: id, interpreter: interpreter)

    #expect(observed.shouldProceed == true)
    #expect(observed.liveExactTokenCount == 1)
    #expect(boundaries.liveExactTokenCount == 0)

    #expect(scopeKeeper.shouldProceed == true)
    #expect(boundaries.liveScopeCount == 1)
  }

  // The Release optimizer may keep a nilled optional's former payload alive
  // until the enclosing function exits. A non-inlined boundary makes the ARC
  // release observable without changing the cancellation contract under test.
  @inline(never)
  private func makeFrozenContext(
    boundaries: EffectCancellationBoundaries,
    id: AnyEffectID,
    sequence: UInt64
  ) -> EffectExecutionContext {
    let interpreter = boundaries.makeContext(
      sequence: sequence,
      cancellationIDs: [id],
      potentialCancellationIDs: [id]
    )
    return interpreter.frozenForExecution()
  }

  @inline(never)
  private func observeFrozenCancellation(
    boundaries: EffectCancellationBoundaries,
    id: AnyEffectID,
    sequence: UInt64
  ) -> (
    liveInterpreterCount: Int,
    retainedPotentialIDCount: Int,
    liveExactTokenCount: Int,
    shouldProceed: Bool,
    retainedCancellationIDCount: Int
  ) {
    let frozen = makeFrozenContext(boundaries: boundaries, id: id, sequence: sequence)
    return withExtendedLifetime(frozen) {
      let liveInterpreterCount = boundaries.liveInterpreterCount
      let retainedPotentialIDCount = boundaries.retainedPotentialIDCount
      let liveExactTokenCount = boundaries.liveExactTokenCount
      boundaries.markCancelled(id: id, upTo: sequence)
      return (
        liveInterpreterCount,
        retainedPotentialIDCount,
        liveExactTokenCount,
        frozen.shouldProceed,
        boundaries.retainedCancellationIDCount
      )
    }
  }

  @inline(never)
  private func observeExactToken(
    boundaries: EffectCancellationBoundaries,
    id: AnyEffectID,
    interpreter: EffectExecutionContext
  ) -> (shouldProceed: Bool, liveExactTokenCount: Int) {
    let exactContext = EffectExecutionContext.withCancellation(id, on: interpreter)
    return withExtendedLifetime(exactContext) {
      (exactContext.shouldProceed, boundaries.liveExactTokenCount)
    }
  }

  @Test("Cancellation state does not cross sequence scopes")
  func cancellationDoesNotPoisonNewSequence() {
    let boundaries = EffectCancellationBoundaries()
    let id = AnyEffectID(StaticEffectID("scope.reuse"))
    let firstSequence = boundaries.nextSequence()
    let first = boundaries.makeContext(
      sequence: firstSequence,
      cancellationIDs: [id],
      potentialCancellationIDs: [id]
    )

    boundaries.markCancelled(id: id, upTo: firstSequence)

    let secondSequence = boundaries.nextSequence()
    let second = boundaries.makeContext(
      sequence: secondSequence,
      cancellationIDs: [id],
      potentialCancellationIDs: [id]
    )

    #expect(first.shouldProceed == false)
    #expect(second.shouldProceed == true)
  }
}
