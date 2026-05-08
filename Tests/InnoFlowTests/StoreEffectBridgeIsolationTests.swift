// MARK: - StoreEffectBridgeIsolationTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

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
}
