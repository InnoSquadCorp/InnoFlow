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
    var interpreter: EffectExecutionContext? = boundaries.makeContext(
      sequence: sequence,
      cancellationIDs: [id],
      potentialCancellationIDs: [id]
    )
    var frozen: EffectExecutionContext? = interpreter?.frozenForExecution()

    interpreter = nil
    #expect(boundaries.liveInterpreterCount == 0)
    #expect(boundaries.retainedPotentialIDCount == 0)
    #expect(boundaries.liveExactTokenCount == 1)

    boundaries.markCancelled(id: id, upTo: sequence)

    #expect(frozen?.shouldProceed == false)
    #expect(boundaries.retainedCancellationIDCount == 0)

    frozen = nil
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
    var interpreter: EffectExecutionContext? = boundaries.makeContext(
      sequence: sequence,
      potentialCancellationIDs: [id]
    )
    let scopeKeeper = interpreter?.frozenForExecution()
    var exactContext: EffectExecutionContext? = .withCancellation(id, on: interpreter)

    #expect(exactContext?.shouldProceed == true)
    #expect(boundaries.liveExactTokenCount == 1)
    exactContext = nil
    #expect(boundaries.liveExactTokenCount == 0)

    interpreter = nil
    #expect(scopeKeeper?.shouldProceed == true)
    #expect(boundaries.liveScopeCount == 1)
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
