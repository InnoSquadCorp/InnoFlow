// MARK: - Store.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import Observation

/// A store that manages feature state and executes effects.
///
/// `Store` is the SwiftUI-facing adapter. State updates happen on `@MainActor`,
/// while effect lifecycle and cancellation are coordinated by support objects that
/// keep queueing, observer refresh, scoped cache, and runtime bookkeeping isolated.
@Observable
@MainActor
@dynamicMemberLookup
public final class Store<R: Reducer> {
  /// The current state.
  public private(set) var state: R.State

  private let reducer: R
  package let clock: StoreClock
  package let instrumentation: StoreInstrumentation<R.Action>
  package let diagnostics: StoreDiagnostics?
  package let lifetime = StoreLifetimeToken()
  private let actionQueue = StoreActionQueue<R.Action>()
  package let effectBridge = StoreEffectBridge<R.Action, R.Output>()
  package let outputHub = StoreOutputHub<R.Output>()
  package let singleScopeCache = SingleScopeCache()
  package let collectionScopeCache = CollectionScopeCache()
  package let selectionCache = SelectionCache()
  private let observerRegistry = ProjectionObserverRegistry<R.State>()
  @ObservationIgnored private var rootEffectInterpreterTail: Task<Void, Never>?

  private var walker: EffectWalker<Store<R>> {
    EffectWalker(driver: self)
  }

  /// Creates a store with an explicit initial state.
  public init(
    reducer: R,
    initialState: R.State,
    clock: StoreClock = .continuous,
    instrumentation: StoreInstrumentation<R.Action> = .disabled,
    diagnostics: StoreDiagnostics? = nil
  ) {
    self.reducer = reducer
    self.state = initialState
    self.clock = clock
    self.diagnostics = diagnostics
    if let diagnostics {
      self.instrumentation = .combined(instrumentation, diagnostics.instrumentation())
    } else {
      self.instrumentation = instrumentation
    }
  }

  /// Creates a store with default-initialized state.
  public convenience init(
    reducer: R,
    clock: StoreClock = .continuous,
    instrumentation: StoreInstrumentation<R.Action> = .disabled,
    diagnostics: StoreDiagnostics? = nil
  ) where R.State: DefaultInitializable {
    self.init(
      reducer: reducer,
      initialState: R.State(),
      clock: clock,
      instrumentation: instrumentation,
      diagnostics: diagnostics
    )
  }

  /// Direct access to state properties (e.g. `store.count`).
  public subscript<Value>(dynamicMember keyPath: KeyPath<R.State, Value>) -> Value {
    state[keyPath: keyPath]
  }

  /// Direct access to low-level bindable storage values.
  public subscript<Value>(dynamicMember keyPath: KeyPath<R.State, BindableProperty<Value>>) -> Value
  where Value: Equatable & Sendable {
    state[keyPath: keyPath].value
  }

  /// Sends an action and returns a handle to its complete descendant effect tree.
  @discardableResult
  public func send(_ action: R.Action) -> FlowTask {
    let dispatchID = DispatchID()
    diagnostics?.recordSubmitted(dispatchID)
    let diagnostics = diagnostics
    let tracker = FlowTaskTracker(
      dispatchID: dispatchID,
      onFinish: { dispatchID in diagnostics?.recordTerminated(dispatchID) },
      onCancel: { dispatchID in diagnostics?.recordCancellationRequested(dispatchID) }
    )
    enqueue(action, animation: nil, flowTaskTracker: tracker)
    return FlowTask(tracker: tracker)
  }

  /// Sends an action and captures outputs from only its descendant effect tree.
  ///
  /// Unlike the store-wide live broadcast returned by ``outputs(bufferingPolicy:)``,
  /// this stream is installed before dispatch and therefore buffers synchronous
  /// root output as well as output from descendant effects. Callers choose the
  /// buffering policy explicitly because dropping output is a domain contract.
  @discardableResult
  public func send(
    _ action: R.Action,
    capturingOutputs bufferingPolicy: AsyncStream<R.Output>.Continuation.BufferingPolicy
  ) -> OutputFlowTask<R.Output> {
    let capture = TypedFlowTaskOutputCapture<R.Output>(bufferingPolicy: bufferingPolicy)
    let dispatchID = DispatchID()
    diagnostics?.recordSubmitted(dispatchID)
    let diagnostics = diagnostics
    let tracker = FlowTaskTracker(
      dispatchID: dispatchID,
      outputCapture: capture,
      onFinish: { dispatchID in diagnostics?.recordTerminated(dispatchID) },
      onCancel: { dispatchID in diagnostics?.recordCancellationRequested(dispatchID) }
    )
    capture.cancelDispatchOnConsumerTermination(tracker)
    enqueue(action, animation: nil, flowTaskTracker: tracker)
    return OutputFlowTask(
      flowTask: FlowTask(tracker: tracker),
      outputs: capture.stream
    )
  }

  /// Returns a non-replaying stream of outputs emitted after subscription.
  ///
  /// Each subscriber receives the same live outputs. The default is unbounded
  /// because outputs represent one-shot coordinator commands that must not be
  /// silently dropped. A host may opt into a bounded policy only when loss is
  /// an explicit part of that output's contract.
  public func outputs(
    bufferingPolicy: AsyncStream<R.Output>.Continuation.BufferingPolicy = .unbounded
  ) -> AsyncStream<R.Output> {
    outputHub.stream(bufferingPolicy: bufferingPolicy)
  }

  /// Cancels effects associated with an identifier and waits for cancellation bookkeeping.
  public func cancelEffects<ID: Hashable & Sendable>(identifiedBy id: EffectID<ID>) async {
    let erasedID = AnyEffectID(id)
    let sequence = effectBridge.markCancelled(id: erasedID)
    recordCancellation(id: erasedID, sequence: sequence)
    let targets = await effectBridge.cancellationTargetDispatchIDs(
      id: erasedID,
      upTo: sequence
    )
    recordDiagnosticCancellations(targets, sequence: sequence, hasEffectID: true)
    await effectBridge.cancelEffects(id: erasedID, upTo: sequence)
  }

  /// Cancels every running effect and waits for cancellation bookkeeping.
  public func cancelAllEffects() async {
    let sequence = effectBridge.markCancelledAll()
    recordCancellation(id: nil, sequence: sequence)
    let targets = await effectBridge.cancellationTargetDispatchIDs(upTo: sequence)
    recordDiagnosticCancellations(targets, sequence: sequence, hasEffectID: false)
    await effectBridge.cancelAllEffects(upTo: sequence)
  }

  // NOTE: `@_optimize(none)` is intentional. The SIL `EarlyPerfInliner` under
  // Swift 6.3 release optimization crashes in
  // `isCallerAndCalleeLayoutConstraintsCompatible` while scanning this
  // isolated deinit for inlining candidates — the generic `R.Action` context
  // combined with the builder-emitted composition types that `Store` stores
  // appears to trip the layout-compatibility check. Disabling optimization on
  // just this one function sidesteps the crash. `deinit` is not a hot path, so
  // the lost optimization opportunity is negligible. Lifecycle semantics
  // (`@MainActor isolated deinit`) are unchanged. Retest when
  // swiftlang/swift#88173 is fixed:
  // https://github.com/swiftlang/swift/issues/88173
  // Tracked in docs/SWIFT_TOOLCHAIN_TRACKING.md.
  @_optimize(none)
  isolated deinit {
    lifetime.markReleased()
    let shutdownSequence = effectBridge.shutdown()
    instrumentation.didCancelEffects(.init(id: nil, sequence: shutdownSequence))
    // Projection handles can outlive this Store. Notify their observable
    // liveness while the registry is still available on MainActor; weak
    // registrations avoid extending the handles' lifetime.
    observerRegistry.refreshAll()
    observerRegistry.pruneAllObservers()
  }

  private func executeEffect(
    _ effect: ReducerEffect<R.Action, R.Output>,
    sequence: UInt64,
    flowTaskTracker: FlowTaskTracker?
  ) {
    switch effect.operation {
    case .none:
      return

    case .send(let action):
      recordEmission(
        action,
        context: .unmanaged(sequence: sequence, flowTaskTracker: flowTaskTracker)
      )
      enqueue(action, animation: nil, flowTaskTracker: flowTaskTracker)

    case .output(let output):
      deliverOutput(
        output,
        context: .unmanaged(sequence: sequence, flowTaskTracker: flowTaskTracker)
      )

    default:
      // The scope and interpreter lease are registered synchronously before
      // the root Task can race with store-level cancellation.
      let context = effectBridge.makeEffectContext(
        sequence: sequence,
        potentialCancellationIDs: effect.potentialCancellationIDs,
        flowTaskTracker: flowTaskTracker
      )
      let activity = flowTaskTracker?.beginActivity()
      let predecessor = rootEffectInterpreterTail
      let task = Task { @MainActor [weak self, weak flowTaskTracker] in
        defer {
          if let activity {
            flowTaskTracker?.endActivity(activity)
          }
        }
        if let predecessor {
          await predecessor.value
        }
        guard let self else { return }
        guard !Task.isCancelled else { return }
        // Keep the root interpreter unawaited so its frame never owns Store
        // across user or delayed work. Every concrete descendant registers
        // its own FlowTask activity before this walk returns.
        await self.walkEffect(effect, context: context, awaited: false)
      }
      rootEffectInterpreterTail = task
      if let activity {
        flowTaskTracker?.attach(task, to: activity)
      }
    }
  }

  package func walkEffect(
    _ effect: ReducerEffect<R.Action, R.Output>,
    context: EffectExecutionContext?,
    awaited: Bool
  ) async {
    await walker.walk(effect, context: context, awaited: awaited)
  }

  package func enqueue(
    _ action: R.Action,
    animation: EffectAnimation?,
    flowTaskTracker: FlowTaskTracker? = nil
  ) {
    actionQueue.enqueue(
      action,
      animation: animation,
      flowTaskTracker: flowTaskTracker
    )
    drainActionQueueIfNeeded()
  }

  private func drainActionQueueIfNeeded() {
    guard actionQueue.beginDrain() else { return }

    defer {
      let snapshot = actionQueue.finishDrain()
      instrumentation.didDrainActionQueue(
        .init(
          processedActionCount: snapshot.processedActionCount,
          pendingActionHighWaterMark: snapshot.pendingActionHighWaterMark,
          storageHighWaterMark: snapshot.storageHighWaterMark,
          retainedCapacity: snapshot.retainedCapacity,
          retainedByteEstimate: snapshot.retainedByteEstimate,
          retentionBudgetBytes: storeActionQueueRetainedStorageBudget,
          didReleaseExcessCapacity: snapshot.didReleaseExcessCapacity
        )
      )
    }

    while let queuedAction = actionQueue.next() {
      defer {
        if let activity = queuedAction.flowTaskActivity {
          queuedAction.flowTaskTracker?.endActivity(activity)
        }
      }
      let sequence = effectBridge.nextSequence()
      // Cancellation can arrive after emission but before this FIFO entry is
      // reduced (including inside a synchronous observation/instrumentation
      // callback). Do not let a cancelled tree mutate state or start new work.
      guard queuedAction.flowTaskTracker?.isCancelled != true else {
        recordDrop(
          queuedAction.action,
          reason: .cancellationBoundary,
          context: .unmanaged(
            sequence: sequence,
            flowTaskTracker: queuedAction.flowTaskTracker
          )
        )
        continue
      }
      let previousState = state
      let effect: ReducerEffect<R.Action, R.Output>

      if let animation = queuedAction.animation {
        var animatedEffect: ReducerEffect<R.Action, R.Output> = .none
        animation.perform {
          animatedEffect = reducer.reduce(into: &state, action: queuedAction.action)
          observerRegistry.refresh(from: previousState, to: state)
        }
        effect = animatedEffect
      } else {
        effect = reducer.reduce(into: &state, action: queuedAction.action)
        observerRegistry.refresh(from: previousState, to: state)
      }

      executeEffect(
        effect,
        sequence: sequence,
        flowTaskTracker: queuedAction.flowTaskTracker
      )
    }
  }

  package func registerProjectionObserver(
    _ observer: any ProjectionObserver,
    registration: ProjectionObserverRegistration<R.State> = .alwaysRefresh
  ) {
    observerRegistry.register(observer, registration: registration)
  }

  package var scopedObserverRefreshCount: UInt64 {
    observerRegistry.statsSnapshot.refreshPassCount
  }

  package var projectionObserverStats: ProjectionObserverRegistryStats {
    observerRegistry.statsSnapshot
  }

  package var effectRuntimeMetrics: EffectRuntime<R.Action>.MetricsSnapshot {
    get async {
      await effectBridge.runtime.metricsSnapshot()
    }
  }

  package func singleScopeCallsite(
    fileID: StaticString,
    line: UInt,
    column: UInt
  ) -> SingleScopeCallsite {
    .init(fileID: fileID.description, line: line, column: column)
  }

  package func selectionCallsite(
    fileID: StaticString,
    line: UInt,
    column: UInt
  ) -> SelectionCallsite {
    .init(fileID: fileID.description, line: line, column: column)
  }

  package func recordEmission(_ action: R.Action, context: EffectExecutionContext?) {
    instrumentation.didEmitAction(
      .init(
        action: action,
        cancellationID: context?.cancellationID,
        sequence: context?.sequence,
        dispatchID: context?.dispatchID
      )
    )
  }

  package func recordDrop(
    _ action: R.Action?,
    reason: ActionDropReason,
    context: EffectExecutionContext?
  ) {
    instrumentation.didDropAction(
      .init(
        action: action,
        reason: reason,
        cancellationID: context?.cancellationID,
        sequence: context?.sequence,
        dispatchID: context?.dispatchID
      )
    )
  }

  package func recordCancellation(
    id: AnyEffectID?,
    sequence: UInt64,
    dispatchID: DispatchID? = nil
  ) {
    instrumentation.didCancelEffects(
      .init(id: id, sequence: sequence, dispatchID: dispatchID)
    )
  }

  package func recordDiagnosticCancellations(
    _ dispatchIDs: Set<DispatchID>,
    sequence: UInt64?,
    hasEffectID: Bool
  ) {
    for dispatchID in dispatchIDs {
      diagnostics?.recordCancellationRequested(
        dispatchID,
        sequence: sequence,
        hasEffectID: hasEffectID
      )
    }
  }

  package func makeRunEvent(token: UUID, context: EffectExecutionContext?)
    -> StoreInstrumentation<R.Action>.RunEvent
  {
    .init(
      token: token,
      cancellationID: context?.cancellationID,
      sequence: context?.sequence,
      dispatchID: context?.dispatchID
    )
  }
}
