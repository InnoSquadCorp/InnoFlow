// MARK: - Store.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import Observation
import SwiftUI

// MARK: - Effect Runtime Core

private actor EffectRuntime<Action: Sendable> {
    private var activeTokens: Set<UUID> = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var tokensByID: [EffectID: Set<UUID>] = [:]
    private var idByToken: [UUID: EffectID] = [:]

    func prepare(token: UUID, id: EffectID?) {
        activeTokens.insert(token)
        guard let id else { return }
        idByToken[token] = id
        tokensByID[id, default: []].insert(token)
    }

    func attach(task: Task<Void, Never>, token: UUID) {
        guard activeTokens.contains(token) else {
            task.cancel()
            return
        }
        tasks[token] = task
    }

    func finish(token: UUID) {
        removeToken(token)
    }

    func cancel(id: EffectID) {
        guard let tokens = tokensByID[id] else { return }

        for token in tokens {
            tasks[token]?.cancel()
            removeToken(token, id: id)
        }
    }

    func cancelAll() {
        let snapshot = Array(activeTokens)
        for token in snapshot {
            tasks[token]?.cancel()
            removeToken(token)
        }
    }

    func canEmit(
        token: UUID,
        id: EffectID?,
        sequence: UInt64,
        cancelledUpToAll: UInt64,
        cancelledUpToByID: UInt64?
    ) -> Bool {
        guard activeTokens.contains(token) else { return false }
        if sequence <= cancelledUpToAll {
            return false
        }
        if let boundary = cancelledUpToByID,
           sequence <= boundary {
            return false
        }
        if let id,
           idByToken[token] != id {
            return false
        }
        return true
    }

    private func removeToken(_ token: UUID, id explicitID: EffectID? = nil) {
        activeTokens.remove(token)
        _ = tasks.removeValue(forKey: token)
        let id = explicitID ?? idByToken[token]
        idByToken.removeValue(forKey: token)

        guard let id,
              var ids = tokensByID[id] else { return }
        ids.remove(token)
        if ids.isEmpty {
            tokensByID.removeValue(forKey: id)
        } else {
            tokensByID[id] = ids
        }
    }
}

/// A store that manages feature state and executes effects.
///
/// `Store` is the SwiftUI-facing adapter. State updates happen on `@MainActor`,
/// while effect lifecycle and cancellation are coordinated by an actor runtime.
@Observable
@MainActor
@dynamicMemberLookup
public final class Store<R: Reducer> {

    // MARK: - Properties

    /// The current state.
    public private(set) var state: R.State

    private let reducer: R
    private let runtime = EffectRuntime<R.Action>()
    private let clock = ContinuousClock()
    private var lastIssuedSequence: UInt64 = 0
    private var cancelledUpToAll: UInt64 = 0
    private var cancelledUpToByID: [EffectID: UInt64] = [:]
    private var throttleWindowEndByID: [EffectID: ContinuousClock.Instant] = [:]
    private var throttlePendingTrailingByID: [EffectID: PendingTrailing<R.Action>] = [:]
    private var throttleTrailingTaskByID: [EffectID: Task<Void, Never>] = [:]

    // MARK: - Initialization

    /// Creates a store with an explicit initial state.
    public init(reducer: R, initialState: R.State) {
        self.reducer = reducer
        self.state = initialState
    }

    /// Creates a store with default-initialized state.
    public convenience init(reducer: R) where R.State: DefaultInitializable {
        self.init(reducer: reducer, initialState: R.State())
    }

    // MARK: - Dynamic Member Lookup

    /// Direct access to state properties (e.g. `store.count`).
    public subscript<Value>(dynamicMember keyPath: KeyPath<R.State, Value>) -> Value {
        state[keyPath: keyPath]
    }

    /// Direct access to `BindableProperty` values.
    public subscript<Value>(dynamicMember keyPath: KeyPath<R.State, BindableProperty<Value>>) -> Value where Value: Equatable & Sendable {
        state[keyPath: keyPath].value
    }

    // MARK: - Action Dispatch

    /// Sends an action to the reducer.
    public func send(_ action: R.Action) {
        let sequence = nextSequence()
        let effect = reducer.reduce(into: &state, action: action)
        execute(effect, sequence: sequence)
    }

    /// Cancels effects associated with an identifier and waits for cancellation bookkeeping.
    public func cancelEffects(identifiedBy id: EffectID) async {
        cancelledUpToByID[id] = max(cancelledUpToByID[id] ?? 0, lastIssuedSequence)
        await runtime.cancel(id: id)
        clearThrottleState(for: id)
    }

    /// Cancels every running effect and waits for cancellation bookkeeping.
    public func cancelAllEffects() async {
        cancelledUpToAll = max(cancelledUpToAll, lastIssuedSequence)
        await runtime.cancelAll()
        // Global boundary supersedes all id-specific boundaries.
        cancelledUpToByID.removeAll(keepingCapacity: true)
        clearAllThrottleState()
    }

    deinit {
        let runtime = self.runtime
        Task {
            await runtime.cancelAll()
        }
    }

    // MARK: - Effect Execution

    private enum ExecutionMode {
        case detached
        case awaited
    }

    private struct ExecutionContext: Sendable {
        let cancellationID: EffectID?
        let animation: Animation?
    }

    private struct PendingTrailing<Action: Sendable>: Sendable {
        let effect: EffectTask<Action>
        let sequence: UInt64
        let context: ExecutionContext
    }

    private func execute(_ effect: EffectTask<R.Action>, sequence: UInt64) {
        switch effect.operation {
        case .none:
            return

        case .send(let action):
            send(action)

        default:
            Task { [weak self] in
                guard let self else { return }
                await self.execute(effect, sequence: sequence, mode: .detached, context: nil)
            }
        }
    }

    private func execute(
        _ effect: EffectTask<R.Action>,
        sequence: UInt64,
        mode: ExecutionMode,
        context: ExecutionContext?
    ) async {
        switch effect.operation {
        case .none:
            return

        case .send(let action):
            applyAction(action, animation: context?.animation)

        case .run(let priority, let operation):
            await executeRun(
                priority: priority,
                operation: operation,
                sequence: sequence,
                mode: mode,
                context: context
            )

        case .merge(let effects):
            if mode == .awaited {
                await withTaskGroup(of: Void.self) { group in
                    for effect in effects {
                        group.addTask { [weak self] in
                            guard let self else { return }
                            await self.execute(
                                effect,
                                sequence: sequence,
                                mode: .awaited,
                                context: context
                            )
                        }
                    }
                    await group.waitForAll()
                }
            } else {
                for effect in effects {
                    Task { [weak self] in
                        guard let self else { return }
                        await self.execute(effect, sequence: sequence, mode: .detached, context: context)
                    }
                }
            }

        case .concatenate(let effects):
            if mode == .awaited {
                for effect in effects {
                    await execute(effect, sequence: sequence, mode: .awaited, context: context)
                }
            } else {
                Task { [weak self] in
                    guard let self else { return }
                    for effect in effects {
                        await self.execute(effect, sequence: sequence, mode: .awaited, context: context)
                    }
                }
            }

        case .cancel(let id):
            cancelledUpToByID[id] = max(cancelledUpToByID[id] ?? 0, sequence)
            await runtime.cancel(id: id)
            clearThrottleState(for: id)

        case .cancellable(let nested, let id, let cancelInFlight):
            if cancelInFlight {
                cancelledUpToByID[id] = max(
                    cancelledUpToByID[id] ?? 0,
                    previousSequence(of: sequence)
                )
                await runtime.cancel(id: id)
                clearThrottleState(for: id)
            }

            await execute(
                nested,
                sequence: sequence,
                mode: mode,
                context: contextWithCancellation(id, on: context)
            )

        case .debounce(let nested, let id, let interval):
            cancelledUpToByID[id] = max(
                cancelledUpToByID[id] ?? 0,
                previousSequence(of: sequence)
            )
            await runtime.cancel(id: id)
            clearThrottleState(for: id)
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            guard shouldStartRun(sequence: sequence, cancellationID: id) else {
                return
            }
            await execute(
                nested,
                sequence: sequence,
                mode: mode,
                context: contextWithCancellation(id, on: context)
            )

        case .throttle(let nested, let id, let interval, let leading, let trailing):
            let now = clock.now
            let throttleContext = contextWithCancellation(id, on: context)
            if let windowEnd = throttleWindowEndByID[id], now < windowEnd {
                if trailing {
                    throttlePendingTrailingByID[id] = .init(
                        effect: nested,
                        sequence: sequence,
                        context: throttleContext
                    )
                }
                return
            }

            throttleTrailingTaskByID[id]?.cancel()
            throttlePendingTrailingByID.removeValue(forKey: id)
            throttleWindowEndByID[id] = now.advanced(by: interval)

            if trailing {
                if !leading {
                    throttlePendingTrailingByID[id] = .init(
                        effect: nested,
                        sequence: sequence,
                        context: throttleContext
                    )
                }
                scheduleThrottleTrailing(for: id, interval: interval, mode: mode)
            }

            if leading {
                await execute(
                    nested,
                    sequence: sequence,
                    mode: mode,
                    context: throttleContext
                )
            }

        case .animation(let nested, let animation):
            await execute(
                nested,
                sequence: sequence,
                mode: mode,
                context: contextWithAnimation(animation, on: context)
            )
        }
    }

    private func executeRun(
        priority: TaskPriority?,
        operation: @escaping @Sendable (Send<R.Action>) async -> Void,
        sequence: UInt64,
        mode: ExecutionMode,
        context: ExecutionContext?
    ) async {
        guard shouldStartRun(sequence: sequence, cancellationID: context?.cancellationID) else {
            return
        }

        let token = UUID()
        await runtime.prepare(token: token, id: context?.cancellationID)

        let task = Task(priority: priority) { [weak self] in
            guard let self else { return }

            let send = Send<R.Action> { [weak self] action in
                guard let self else { return }
                let boundaries = await MainActor.run { [weak self] () -> (UInt64, UInt64?)? in
                    guard let self else { return nil }
                    let boundaryForID: UInt64?
                    if let cancellationID = context?.cancellationID {
                        boundaryForID = self.cancelledUpToByID[cancellationID]
                    } else {
                        boundaryForID = nil
                    }
                    return (
                        self.cancelledUpToAll,
                        boundaryForID
                    )
                }
                guard let boundaries else { return }
                let canEmit = await self.runtime.canEmit(
                    token: token,
                    id: context?.cancellationID,
                    sequence: sequence,
                    cancelledUpToAll: boundaries.0,
                    cancelledUpToByID: boundaries.1
                )
                guard canEmit else { return }
                await MainActor.run {
                    guard self.shouldStartRun(
                        sequence: sequence,
                        cancellationID: context?.cancellationID
                    ) else { return }
                    self.applyAction(action, animation: context?.animation)
                }
            }

            await operation(send)
            await self.runtime.finish(token: token)
        }

        await runtime.attach(task: task, token: token)

        if mode == .awaited {
            _ = await task.result
        }
    }

    private func shouldStartRun(sequence: UInt64, cancellationID: EffectID?) -> Bool {
        if sequence <= cancelledUpToAll {
            return false
        }

        guard let cancellationID else { return true }
        let boundary = cancelledUpToByID[cancellationID] ?? 0
        return sequence > boundary
    }

    private func nextSequence() -> UInt64 {
        lastIssuedSequence &+= 1
        return lastIssuedSequence
    }

    private func previousSequence(of sequence: UInt64) -> UInt64 {
        sequence == 0 ? 0 : sequence - 1
    }

    private func applyAction(_ action: R.Action, animation: Animation?) {
        if let animation {
            withAnimation(animation) {
                send(action)
            }
            return
        }
        send(action)
    }

    private func contextWithCancellation(
        _ id: EffectID,
        on context: ExecutionContext?
    ) -> ExecutionContext {
        .init(
            cancellationID: id,
            animation: context?.animation
        )
    }

    private func contextWithAnimation(
        _ animation: Animation?,
        on context: ExecutionContext?
    ) -> ExecutionContext {
        .init(
            cancellationID: context?.cancellationID,
            animation: animation
        )
    }

    private func scheduleThrottleTrailing(
        for id: EffectID,
        interval: Duration,
        mode: ExecutionMode
    ) {
        throttleTrailingTaskByID[id] = Task { [weak self] in
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            await self?.drainThrottleTrailing(for: id, mode: mode)
        }
    }

    private func drainThrottleTrailing(for id: EffectID, mode: ExecutionMode) async {
        defer {
            throttleTrailingTaskByID.removeValue(forKey: id)
            throttlePendingTrailingByID.removeValue(forKey: id)
            throttleWindowEndByID.removeValue(forKey: id)
        }

        guard let pending = throttlePendingTrailingByID[id] else {
            return
        }
        guard shouldStartRun(
            sequence: pending.sequence,
            cancellationID: pending.context.cancellationID
        ) else {
            return
        }
        await execute(
            pending.effect,
            sequence: pending.sequence,
            mode: mode,
            context: pending.context
        )
    }

    private func clearThrottleState(for id: EffectID) {
        throttleTrailingTaskByID.removeValue(forKey: id)?.cancel()
        throttlePendingTrailingByID.removeValue(forKey: id)
        throttleWindowEndByID.removeValue(forKey: id)
    }

    private func clearAllThrottleState() {
        for task in throttleTrailingTaskByID.values {
            task.cancel()
        }
        throttleTrailingTaskByID.removeAll(keepingCapacity: true)
        throttlePendingTrailingByID.removeAll(keepingCapacity: true)
        throttleWindowEndByID.removeAll(keepingCapacity: true)
    }
}

// MARK: - Bindable Property

/// A wrapper for state fields that are intentionally bindable from SwiftUI.
@dynamicMemberLookup
public struct BindableProperty<Value>: Equatable, Sendable where Value: Equatable & Sendable {
    public var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    public init(wrappedValue: Value) {
        self.value = wrappedValue
    }

    public subscript<T>(dynamicMember keyPath: KeyPath<Value, T>) -> T {
        value[keyPath: keyPath]
    }
}

// MARK: - Default Initializable

/// Conform state to this protocol when default initialization is desired.
public protocol DefaultInitializable {
    init()
}

// MARK: - Binding Support

public extension Store {
    /// Creates a SwiftUI `Binding` for properties marked with `@BindableField`.
    func binding<Value>(
        _ keyPath: KeyPath<R.State, BindableProperty<Value>>,
        send action: @escaping @Sendable (Value) -> R.Action
    ) -> Binding<Value> where Value: Equatable & Sendable {
        Binding(
            get: { self.state[keyPath: keyPath].value },
            set: { self.send(action($0)) }
        )
    }
}

// MARK: - Scoping

public extension Store {
    /// Creates a derived store for child state/action pairs.
    func scope<ChildState, ChildAction>(
        state: KeyPath<R.State, ChildState>,
        action: @escaping @Sendable (ChildAction) -> R.Action
    ) -> ScopedStore<R, ChildState, ChildAction> {
        ScopedStore(parent: self, stateKeyPath: state, actionTransform: action)
    }
}

// MARK: - Scoped Store

/// A read-only projection of parent store state with action forwarding.
@Observable
@MainActor
@dynamicMemberLookup
public final class ScopedStore<ParentReducer: Reducer, ChildState, ChildAction> {

    private let parent: Store<ParentReducer>
    private let stateKeyPath: KeyPath<ParentReducer.State, ChildState>
    private let actionTransform: @Sendable (ChildAction) -> ParentReducer.Action

    public var state: ChildState {
        parent.state[keyPath: stateKeyPath]
    }

    init(
        parent: Store<ParentReducer>,
        stateKeyPath: KeyPath<ParentReducer.State, ChildState>,
        actionTransform: @escaping @Sendable (ChildAction) -> ParentReducer.Action
    ) {
        self.parent = parent
        self.stateKeyPath = stateKeyPath
        self.actionTransform = actionTransform
    }

    public subscript<Value>(dynamicMember keyPath: KeyPath<ChildState, Value>) -> Value {
        state[keyPath: keyPath]
    }

    public func send(_ action: ChildAction) {
        parent.send(actionTransform(action))
    }
}
