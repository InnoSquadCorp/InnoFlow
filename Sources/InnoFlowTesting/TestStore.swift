// MARK: - TestStore.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
@_exported public import InnoFlowCore

/// A deterministic test harness for InnoFlow reducers.
///
/// `TestStore` asserts state transitions and captures effect-emitted actions.
/// Timeout behavior is controlled with structured-concurrency races,
/// avoiding arbitrary polling sleeps. Follow-up actions are observed using the
/// same queue-based vocabulary as `Store`.
///
/// Call `finish()` at the terminal test boundary. If a store instead leaves
/// scope with valid buffered actions or active framework-owned effects, its
/// synchronous deinitializer snapshots that work, cancels it, and then reports
/// one diagnostic according to ``exhaustivity``. That safety net does not wait
/// for effects or reduce buffered actions. A completed or failed `finish()` is
/// not reported again unless new work begins or arrives later.
///
/// Non-cancellation errors escaping `EffectTask.run` are always reported once
/// at the public action assertion that created the effect. This runtime-failure
/// contract is independent of ``exhaustivity``.
@MainActor
public final class TestStore<R: Reducer> where R.State: Equatable {

  package struct TrackedEffectTask {
    package let task: Task<Void, Never>
    package let sequence: UInt64
  }

  package struct TrackedDebounceTask {
    package let task: Task<Void, Never>?
    package let scope: DelayedEffectScope
    package let generation: UInt64
  }

  // MARK: - Properties

  public package(set) var state: R.State
  /// Controls state, effect-action, and omitted-terminal-work diagnostics.
  public var exhaustivity: Exhaustivity = .on

  package let reducer: R
  package let effectTimeout: Duration
  package let diffLineLimit: Int
  package let wallClock = ContinuousClock()
  package let manualClock: ManualTestClock?
  package let queue = ActionQueue<R.Action>()
  package let finishActivity = TestStoreFinishActivity()
  package var assertionFailureReporter: (String, StaticString, UInt) -> Void = {
    testStoreAssertionFailure($0, file: $1, line: $2)
  }
  package var skippedAssertionReporter: (String, StaticString, UInt) -> Void = {
    testStoreAssertionWarning($0, file: $1, line: $2)
  }
  package var terminalVerificationRevision: UInt64 = 0
  package var lastHandledTerminalVerificationRevision: UInt64?
  package var terminalVerificationSource: (file: StaticString, line: UInt)?

  package var runningTasks: [UUID: TrackedEffectTask] = [:]
  package var taskIDsByEffectID: [AnyEffectID: Set<UUID>] = [:]
  package var debounceTasksByID: [AnyEffectID: TrackedDebounceTask] = [:]
  package var nextDebounceGenerationValue: UInt64 = 0
  package let effectBoundaries = EffectCancellationBoundaries()
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
  // Retest when swiftlang/swift#88173 is fixed:
  // https://github.com/swiftlang/swift/issues/88173
  // Tracked in docs/SWIFT_TOOLCHAIN_TRACKING.md.
  @_optimize(none)
  isolated deinit {
    let diagnostic = makeTerminalVerificationDiagnostic()
    let failureReporter = assertionFailureReporter
    let warningReporter = skippedAssertionReporter

    _ = markCancelledAll()
    for trackedTask in runningTasks.values {
      trackedTask.task.cancel()
    }
    for trackedTask in debounceTasksByID.values {
      trackedTask.task?.cancel()
    }
    throttleState.clearAll()

    guard let diagnostic else { return }
    switch diagnostic.severity {
    case .failure:
      failureReporter(diagnostic.message, diagnostic.file, diagnostic.line)
    case .warning:
      warningReporter(diagnostic.message, diagnostic.file, diagnostic.line)
    }
  }

  // MARK: - Sequence Boundaries

  package func nextSequence() -> UInt64 {
    effectBoundaries.nextSequence()
  }

  package func nextEffectContext(
    file: StaticString,
    line: UInt
  ) -> EffectExecutionContext {
    .init(
      sequence: nextSequence(),
      origin: .init(file: file, line: line)
    )
  }

  package func shouldStart(sequence: UInt64, cancellationID: AnyEffectID?) -> Bool {
    effectBoundaries.shouldStart(sequence: sequence, cancellationID: cancellationID)
  }

  package func shouldStart(sequence: UInt64, cancellationIDs: [AnyEffectID]) -> Bool {
    effectBoundaries.shouldStart(sequence: sequence, cancellationIDs: cancellationIDs)
  }

  @discardableResult
  package func markCancelled(id: AnyEffectID, upTo sequence: UInt64? = nil) -> UInt64 {
    effectBoundaries.markCancelled(id: id, upTo: sequence)
  }

  @discardableResult
  package func markCancelledInFlight(id: AnyEffectID, upTo sequence: UInt64? = nil) -> UInt64 {
    effectBoundaries.markCancelledInFlight(id: id, upTo: sequence)
  }

  @discardableResult
  package func markCancelledAll(upTo sequence: UInt64? = nil) -> UInt64 {
    effectBoundaries.markCancelledAll(upTo: sequence)
  }

}
