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
  package let lifetime = StoreLifetimeToken()
  private let actionQueue = StoreActionQueue<R.Action>()
  package let effectBridge = StoreEffectBridge<R.Action>()
  package let collectionScopeCache = CollectionScopeCache()
  package let selectionCache = SelectionCache()
  private let observerRegistry = ProjectionObserverRegistry<R.State>()

  private var walker: EffectWalker<Store<R>> {
    EffectWalker(driver: self)
  }

  /// Creates a store with an explicit initial state.
  public init(
    reducer: R,
    initialState: R.State,
    clock: StoreClock = .continuous,
    instrumentation: StoreInstrumentation<R.Action> = .disabled
  ) {
    self.reducer = reducer
    self.state = initialState
    self.clock = clock
    self.instrumentation = instrumentation
  }

  /// Creates a store with default-initialized state.
  public convenience init(
    reducer: R,
    clock: StoreClock = .continuous,
    instrumentation: StoreInstrumentation<R.Action> = .disabled
  ) where R.State: DefaultInitializable {
    self.init(
      reducer: reducer, initialState: R.State(), clock: clock, instrumentation: instrumentation)
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

  /// Sends an action to the reducer.
  public func send(_ action: R.Action) {
    enqueue(action, animation: nil)
  }

  /// Cancels effects associated with an identifier and waits for cancellation bookkeeping.
  public func cancelEffects(identifiedBy id: EffectID) async {
    let sequence = effectBridge.markCancelled(id: id)
    recordCancellation(id: id, sequence: sequence)
    await effectBridge.cancelEffects(id: id, upTo: sequence)
  }

  /// Cancels every running effect and waits for cancellation bookkeeping.
  public func cancelAllEffects() async {
    let sequence = effectBridge.markCancelledAll()
    recordCancellation(id: nil, sequence: sequence)
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
  // (`@MainActor isolated deinit`) are unchanged.
  @_optimize(none)
  isolated deinit {
    lifetime.markReleased()
    let shutdownSequence = effectBridge.shutdown()
    instrumentation.didCancelEffects(.init(id: nil, sequence: shutdownSequence))
  }

  private func executeEffect(_ effect: EffectTask<R.Action>, sequence: UInt64) {
    switch effect.operation {
    case .none:
      return

    case .send(let action):
      enqueue(action, animation: nil)
      recordEmission(action, context: .init(sequence: sequence))

    default:
      let context = EffectExecutionContext(sequence: sequence)
      Task { [weak self] in
        guard let self else { return }
        await self.walker.walk(effect, context: context, awaited: false)
      }
    }
  }

  package func enqueue(_ action: R.Action, animation: EffectAnimation?) {
    actionQueue.enqueue(action, animation: animation)
    drainActionQueueIfNeeded()
  }

  private func drainActionQueueIfNeeded() {
    guard actionQueue.beginDrain() else { return }

    defer {
      actionQueue.finishDrain()
    }

    while let queuedAction = actionQueue.next() {
      let sequence = effectBridge.nextSequence()
      let previousState = state
      let effect: EffectTask<R.Action>

      if let animation = queuedAction.animation {
        var animatedEffect: EffectTask<R.Action> = .none
        animation.perform {
          animatedEffect = reducer.reduce(into: &state, action: queuedAction.action)
        }
        effect = animatedEffect
      } else {
        effect = reducer.reduce(into: &state, action: queuedAction.action)
      }

      observerRegistry.refresh(from: previousState, to: state)
      executeEffect(effect, sequence: sequence)
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

  package func collectionScopeCallsite(
    fileID: StaticString,
    line: UInt
  ) -> CollectionScopeCallsite {
    .init(fileID: fileID.description, line: line)
  }

  package func selectionCallsite(
    fileID: StaticString,
    line: UInt
  ) -> SelectionCallsite {
    .init(fileID: fileID.description, line: line)
  }

  package func recordEmission(_ action: R.Action, context: EffectExecutionContext?) {
    instrumentation.didEmitAction(
      .init(
        action: action,
        cancellationID: context?.cancellationID,
        sequence: context?.sequence
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
        sequence: context?.sequence
      )
    )
  }

  package func recordCancellation(id: EffectID?, sequence: UInt64) {
    instrumentation.didCancelEffects(.init(id: id, sequence: sequence))
  }

  package func makeRunEvent(token: UUID, context: EffectExecutionContext?)
    -> StoreInstrumentation<R.Action>.RunEvent
  {
    .init(
      token: token,
      cancellationID: context?.cancellationID,
      sequence: context?.sequence
    )
  }
}
