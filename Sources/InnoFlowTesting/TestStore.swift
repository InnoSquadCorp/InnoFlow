// MARK: - TestStore.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import InnoFlow
import SwiftUI

/// A deterministic test harness for InnoFlow v2 reducers.
///
/// `TestStore` asserts state transitions and captures effect-emitted actions.
/// Timeout behavior is controlled with structured-concurrency races,
/// avoiding arbitrary polling sleeps. Follow-up actions are observed using the
/// same queue-based vocabulary as `Store`.
@MainActor
public final class TestStore<R: Reducer> where R.State: Equatable {

  // MARK: - Properties

  public package(set) var state: R.State

  package let reducer: R
  package let effectTimeout: Duration
  package let diffLineLimit: Int
  package let wallClock = ContinuousClock()
  package let manualClock: ManualTestClock?
  package let queue = ActionQueue<R.Action>()

  package var runningTasks: [UUID: Task<Void, Never>] = [:]
  package var taskIDsByEffectID: [AnyEffectID: Set<UUID>] = [:]
  package var debounceDelayTasksByID: [AnyEffectID: Task<Void, Never>] = [:]
  package var debounceGenerationByID: [AnyEffectID: UUID] = [:]
  package var lastIssuedSequence: UInt64 = 0
  package var cancelledUpToAll: UInt64 = 0
  package var cancelledUpToByID: [AnyEffectID: UInt64] = [:]
  package let throttleState = ThrottleStateMap<R.Action>()

  package var walker: EffectWalker<TestStore<R>> {
    EffectWalker(driver: self)
  }

  // MARK: - Initialization

  public init(
    reducer: R,
    initialState: R.State,
    clock: ManualTestClock? = nil,
    effectTimeout: Duration = .seconds(1),
    diffLineLimit: Int? = nil
  ) {
    self.reducer = reducer
    self.state = initialState
    self.manualClock = clock
    self.effectTimeout = effectTimeout
    self.diffLineLimit = resolveDiffLineLimit(
      explicit: diffLineLimit,
      environment: ProcessInfo.processInfo.environment
    )
  }

  public convenience init(
    reducer: R,
    initialState: R.State? = nil,
    clock: ManualTestClock? = nil,
    effectTimeout: Duration = .seconds(1),
    diffLineLimit: Int? = nil
  ) where R.State: DefaultInitializable {
    self.init(
      reducer: reducer,
      initialState: initialState ?? R.State(),
      clock: clock,
      effectTimeout: effectTimeout,
      diffLineLimit: diffLineLimit
    )
  }

  // NOTE: `@_optimize(none)` matches the workaround applied to `Store.deinit`.
  // See the comment there — the Swift 6.3 `EarlyPerfInliner` crashes on
  // generic isolated deinits that touch builder-emitted composition types.
  @_optimize(none)
  isolated deinit {
    for task in runningTasks.values {
      task.cancel()
    }
    for task in debounceDelayTasksByID.values {
      task.cancel()
    }
    throttleState.clearAll()
  }

  // MARK: - Sequence Boundaries

  package func nextSequence() -> UInt64 {
    lastIssuedSequence &+= 1
    return lastIssuedSequence
  }

  package func shouldStart(sequence: UInt64, cancellationID: AnyEffectID?) -> Bool {
    if sequence <= cancelledUpToAll {
      return false
    }
    guard let cancellationID else { return true }
    return sequence > (cancelledUpToByID[cancellationID] ?? 0)
  }

  @discardableResult
  package func markCancelled(id: AnyEffectID, upTo sequence: UInt64? = nil) -> UInt64 {
    let sequence = sequence ?? lastIssuedSequence
    cancelledUpToByID[id] = max(cancelledUpToByID[id] ?? 0, sequence)
    return sequence
  }

  @discardableResult
  package func markCancelledInFlight(id: AnyEffectID, upTo sequence: UInt64? = nil) -> UInt64 {
    let sequence = sequence ?? lastIssuedSequence
    let previousSequence = sequence == 0 ? 0 : sequence - 1
    cancelledUpToByID[id] = max(cancelledUpToByID[id] ?? 0, previousSequence)
    return previousSequence
  }

  @discardableResult
  package func markCancelledAll(upTo sequence: UInt64? = nil) -> UInt64 {
    let sequence = sequence ?? lastIssuedSequence
    cancelledUpToAll = max(cancelledUpToAll, sequence)
    cancelledUpToByID.removeAll(keepingCapacity: true)
    return sequence
  }

}
