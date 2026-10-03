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
    package let context: EffectExecutionContext?

    package var sequence: UInt64 {
      context?.sequence ?? 0
    }
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
  package let outputQueue = ActionQueue<R.Output>()
  package let finishActivity = TestStoreFinishActivity()
  package let effectLedgers = TestEffectLedgerRegistry()
  package var issueReporter: (String, TestStoreSourceLocation) -> Void = {
    testStoreAssertionFailure($0, location: $1)
  }
  package var warningReporter: (String, TestStoreSourceLocation) -> Void = {
    testStoreAssertionWarning($0, location: $1)
  }

  // Preserve existing package-level test interception while production paths
  // and scenario decoration retain all four source-location coordinates.
  package var assertionFailureReporter: (String, StaticString, UInt) -> Void {
    get {
      let report = issueReporter
      return { report($0, .init(fileID: $1, filePath: $1, line: $2, column: 1)) }
    }
    set {
      issueReporter = { message, location in newValue(message, location.filePath, location.line) }
    }
  }
  package var skippedAssertionReporter: (String, StaticString, UInt) -> Void {
    get {
      let report = warningReporter
      return { report($0, .init(fileID: $1, filePath: $1, line: $2, column: 1)) }
    }
    set {
      warningReporter = { message, location in newValue(message, location.filePath, location.line) }
    }
  }
  package var terminalVerificationRevision: UInt64 = 0
  package var lastHandledTerminalVerificationRevision: UInt64?
  package var terminalVerificationSource: TestStoreSourceLocation?

  package var runningTasks: [UUID: TrackedEffectTask] = [:]
  package var cancelledTaskTokens: Set<UUID> = []
  package var taskIDsByEffectID: [AnyEffectID: Set<UUID>] = [:]
  package var debounceTasksByID: [AnyEffectID: TrackedDebounceTask] = [:]
  package var throttleActivityTokenByID: [AnyEffectID: UUID] = [:]
  package var nextDebounceGenerationValue: UInt64 = 0
  package let childLifetimeRegistry = ChildLifetimeRegistry()
  package let effectBoundaries = EffectCancellationBoundaries()
  package let throttleState = ThrottleStateMap<R.Action, R.Output>()
  package let runScheduler = EffectRunScheduler()
  package var invariants: [TestStoreInvariant<R.State>] = []

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
    childLifetimeRegistry.removeAll()
    let diagnostic = makeTerminalVerificationDiagnostic()
    let failureReporter = issueReporter
    let warningReporter = self.warningReporter

    for ledger in effectLedgers.values { ledger.record(.cancelled(.storeReleased)) }
    _ = markCancelledAll()
    for trackedTask in runningTasks.values {
      trackedTask.task.cancel()
    }
    for trackedTask in debounceTasksByID.values {
      trackedTask.task?.cancel()
    }
    runScheduler.cancelAll()
    throttleState.clearAll()
    // Wake handle waiters so they can observe the weak store has gone away.
    finishActivity.noteProgress()

    guard let diagnostic else { return }
    switch diagnostic.severity {
    case .failure:
      failureReporter(diagnostic.message, diagnostic.location)
    case .warning:
      warningReporter(diagnostic.message, diagnostic.location)
    }
  }

  // MARK: - Sequence Boundaries

  package func nextSequence() -> UInt64 {
    effectBoundaries.nextSequence()
  }

  package var retainedCancellationIDCount: Int {
    effectBoundaries.retainedCancellationIDCount
  }

  package var cancellationScopeMetrics: EffectCancellationScopeMetrics {
    .init(
      liveScopes: effectBoundaries.liveScopeCount,
      liveInterpreters: effectBoundaries.liveInterpreterCount,
      retainedPotentialIDs: effectBoundaries.retainedPotentialIDCount,
      pendingCancellationIDs: effectBoundaries.retainedCancellationIDCount,
      liveExactTokens: effectBoundaries.liveExactTokenCount
    )
  }

  package func nextEffectContext(
    for effect: ReducerEffect<R.Action, R.Output>,
    location: TestStoreSourceLocation,
    flowTaskTracker: FlowTaskTracker? = nil
  ) -> EffectExecutionContext {
    effectBoundaries.nextContext(
      potentialCancellationIDs: effect.potentialCancellationIDs,
      origin: .init(location: location),
      flowTaskTracker: flowTaskTracker
    )
  }

  package func makeEffectContext(
    sequence: UInt64,
    cancellationIDs: [AnyEffectID] = [],
    potentialCancellationIDs: Set<AnyEffectID> = [],
    location: TestStoreSourceLocation = .init()
  ) -> EffectExecutionContext {
    effectBoundaries.makeContext(
      sequence: sequence,
      cancellationIDs: cancellationIDs,
      potentialCancellationIDs: potentialCancellationIDs,
      origin: .init(location: location)
    )
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
