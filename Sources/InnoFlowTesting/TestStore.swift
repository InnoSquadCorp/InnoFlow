// MARK: - TestStore.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import InnoFlow
import SwiftUI
#if canImport(XCTest)
import XCTest
#elseif canImport(Testing)
import Testing
#endif

private actor ActionQueue<Action: Sendable> {
    private var buffer: [Action] = []
    private var waiters: [UUID: CheckedContinuation<Action?, Never>] = [:]

    func enqueue(_ action: Action) {
        if let waiterID = waiters.keys.first,
           let continuation = waiters.removeValue(forKey: waiterID) {
            continuation.resume(returning: action)
            return
        }

        buffer.append(action)
    }

    func next() async -> Action? {
        if !buffer.isEmpty {
            return buffer.removeFirst()
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[waiterID] = continuation
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterID)
            }
        }
    }

    func popBuffered() -> Action? {
        guard !buffer.isEmpty else { return nil }
        return buffer.removeFirst()
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let continuation = waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(returning: nil)
    }
}

/// A deterministic test harness for InnoFlow v2 reducers.
///
/// `TestStore` asserts state transitions and captures effect-emitted actions.
/// Timeout behavior is controlled with structured-concurrency races,
/// avoiding arbitrary polling sleeps.
@MainActor
public final class TestStore<R: Reducer> where R.State: Equatable {

    // MARK: - Properties

    public private(set) var state: R.State

    private let reducer: R
    private let effectTimeout: Duration
    private let clock = ContinuousClock()
    private let queue = ActionQueue<R.Action>()

    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var taskIDsByEffectID: [EffectID: Set<UUID>] = [:]
    private var debounceDelayTasksByID: [EffectID: Task<Void, Never>] = [:]
    private var throttleWindowEndByID: [EffectID: ContinuousClock.Instant] = [:]
    private var throttlePendingTrailingByID: [EffectID: PendingTrailing<R.Action>] = [:]
    private var throttleTrailingTaskByID: [EffectID: Task<Void, Never>] = [:]
    private var throttleGenerationByID: [EffectID: UInt64] = [:]

    // MARK: - Initialization

    public init(
        reducer: R,
        initialState: R.State,
        effectTimeout: Duration = .seconds(1)
    ) {
        self.reducer = reducer
        self.state = initialState
        self.effectTimeout = effectTimeout
    }

    public convenience init(
        reducer: R,
        initialState: R.State? = nil,
        effectTimeout: Duration = .seconds(1)
    ) where R.State: DefaultInitializable {
        self.init(
            reducer: reducer,
            initialState: initialState ?? R.State(),
            effectTimeout: effectTimeout
        )
    }

    deinit {
        for task in runningTasks.values {
            task.cancel()
        }
        for task in debounceDelayTasksByID.values {
            task.cancel()
        }
        for task in throttleTrailingTaskByID.values {
            task.cancel()
        }
    }

    // MARK: - Public APIs

    public func send(
        _ action: R.Action,
        assert updateExpectedState: ((inout R.State) -> Void)? = nil,
        file: StaticString = #file,
        line: UInt = #line
    ) async {
        var expectedState = state
        updateExpectedState?(&expectedState)

        let effect = reducer.reduce(into: &state, action: action)

        if updateExpectedState != nil, state != expectedState {
            testStoreAssertionFailure(
                """
                State mismatch after action.

                Expected:
                \(expectedState)

                Actual:
                \(state)
                """,
                file: file,
                line: line
            )
        }

        execute(effect)
    }

    public func receive(
        _ expectedAction: R.Action,
        assert updateExpectedState: ((inout R.State) -> Void)? = nil,
        file: StaticString = #file,
        line: UInt = #line
    ) async where R.Action: Equatable {
        guard let action = await nextActionWithinTimeout() else {
            testStoreAssertionFailure(
                """
                Expected to receive action:
                \(expectedAction)

                But timed out after \(effectTimeout).
                """,
                file: file,
                line: line
            )
            return
        }

        if action != expectedAction {
            testStoreAssertionFailure(
                """
                Received unexpected action.

                Expected:
                \(expectedAction)

                Received:
                \(action)
                """,
                file: file,
                line: line
            )
            return
        }

        var expectedState = state
        updateExpectedState?(&expectedState)

        let effect = reducer.reduce(into: &state, action: action)

        if updateExpectedState != nil, state != expectedState {
            testStoreAssertionFailure(
                """
                State mismatch after receiving action.

                Expected:
                \(expectedState)

                Actual:
                \(state)
                """,
                file: file,
                line: line
            )
        }

        execute(effect)
    }

    public func assertNoMoreActions(
        file: StaticString = #file,
        line: UInt = #line
    ) async {
        if let buffered = await queue.popBuffered() {
            testStoreAssertionFailure(
                """
                Unhandled received action:
                \(buffered)

                All effect actions should be verified with `receive(_:assert:)`.
                """,
                file: file,
                line: line
            )
            return
        }

        let queue = self.queue
        let leftover = await withTimeout(effectTimeout) {
            await queue.next()
        }

        if let leftover {
            testStoreAssertionFailure(
                """
                Unhandled received action:
                \(leftover)

                All effect actions should be verified with `receive(_:assert:)`.
                """,
                file: file,
                line: line
            )
        }
    }

    public func cancelEffects(identifiedBy id: EffectID) async {
        cancelEffectsSynchronously(identifiedBy: id)
    }

    public func cancelAllEffects() async {
        cancelAllEffectsSynchronously()
    }

    // MARK: - Effect Execution

    private struct ExecutionContext: Sendable {
        let cancellationID: EffectID?
        let animation: Animation?
    }

    private struct PendingTrailing<Action: Sendable>: Sendable {
        let effect: EffectTask<Action>
        let context: ExecutionContext
    }

    private func execute(
        _ effect: EffectTask<R.Action>,
        context: ExecutionContext? = nil
    ) {
        switch effect._testingOperation {
        case .none:
            return

        case .send(let action):
            Task {
                await queue.enqueue(action)
            }

        case .run(let priority, let operation):
            startRunTask(priority: priority, operation: operation, context: context)

        case .merge(let effects):
            for effect in effects {
                execute(effect, context: context)
            }

        case .concatenate(let effects):
            Task { [weak self] in
                guard let self else { return }
                for effect in effects {
                    await self.executeAwaited(effect, context: context)
                }
            }

        case .cancel(let id):
            cancelEffectsSynchronously(identifiedBy: id)

        case .cancellable(let nested, let id, let cancelInFlight):
            if cancelInFlight {
                cancelEffectsSynchronously(identifiedBy: id)
            }
            execute(nested, context: contextWithCancellation(id, on: context))

        case .debounce(let nested, let id, let interval):
            debounceDelayTasksByID[id]?.cancel()
            cancelEffectsSynchronously(identifiedBy: id)
            let task = Task { [weak self] in
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.debounceDelayTasksByID.removeValue(forKey: id)
                }
                await self?.executeAwaited(
                    nested,
                    context: self?.contextWithCancellation(id, on: context)
                )
            }
            debounceDelayTasksByID[id] = task

        case .throttle(let nested, let id, let interval, let leading, let trailing):
            let now = clock.now
            let throttleContext = contextWithCancellation(id, on: context)
            if let windowEnd = throttleWindowEndByID[id], now < windowEnd {
                if trailing {
                    throttlePendingTrailingByID[id] = .init(
                        effect: nested,
                        context: throttleContext
                    )
                }
                return
            }
            throttleTrailingTaskByID.removeValue(forKey: id)?.cancel()
            throttleGenerationByID.removeValue(forKey: id)
            throttlePendingTrailingByID.removeValue(forKey: id)
            throttleWindowEndByID[id] = now.advanced(by: interval)

            if trailing {
                if !leading {
                    throttlePendingTrailingByID[id] = .init(
                        effect: nested,
                        context: throttleContext
                    )
                }
                scheduleThrottleTrailing(for: id, interval: interval)
            }

            if leading {
                execute(
                    nested,
                    context: throttleContext
                )
            }

        case .animation(let nested, let animation):
            execute(
                nested,
                context: contextWithAnimation(animation, on: context)
            )
        }
    }

    private func executeAwaited(
        _ effect: EffectTask<R.Action>,
        context: ExecutionContext? = nil
    ) async {
        switch effect._testingOperation {
        case .none:
            return

        case .send(let action):
            await queue.enqueue(action)

        case .run(let priority, let operation):
            await withCheckedContinuation { continuation in
                startRunTask(
                    priority: priority,
                    operation: operation,
                    context: context,
                    completion: {
                        continuation.resume()
                    }
                )
            }

        case .merge(let effects):
            await withTaskGroup(of: Void.self) { group in
                for effect in effects {
                    group.addTask { [weak self] in
                        guard let self else { return }
                        await self.executeAwaited(effect, context: context)
                    }
                }
                await group.waitForAll()
            }

        case .concatenate(let effects):
            for effect in effects {
                await executeAwaited(effect, context: context)
            }

        case .cancel(let id):
            cancelEffectsSynchronously(identifiedBy: id)

        case .cancellable(let nested, let id, let cancelInFlight):
            if cancelInFlight {
                cancelEffectsSynchronously(identifiedBy: id)
            }
            await executeAwaited(
                nested,
                context: contextWithCancellation(id, on: context)
            )

        case .debounce(let nested, let id, let interval):
            debounceDelayTasksByID[id]?.cancel()
            cancelEffectsSynchronously(identifiedBy: id)
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            await executeAwaited(
                nested,
                context: contextWithCancellation(id, on: context)
            )

        case .throttle(let nested, let id, let interval, let leading, let trailing):
            let now = clock.now
            let throttleContext = contextWithCancellation(id, on: context)
            if let windowEnd = throttleWindowEndByID[id], now < windowEnd {
                if trailing {
                    throttlePendingTrailingByID[id] = .init(
                        effect: nested,
                        context: throttleContext
                    )
                }
                return
            }
            throttleTrailingTaskByID.removeValue(forKey: id)?.cancel()
            throttleGenerationByID.removeValue(forKey: id)
            throttlePendingTrailingByID.removeValue(forKey: id)
            throttleWindowEndByID[id] = now.advanced(by: interval)

            if trailing {
                if !leading {
                    throttlePendingTrailingByID[id] = .init(
                        effect: nested,
                        context: throttleContext
                    )
                }
                scheduleThrottleTrailing(for: id, interval: interval)
            }

            if leading {
                await executeAwaited(
                    nested,
                    context: throttleContext
                )
            }

        case .animation(let nested, let animation):
            await executeAwaited(
                nested,
                context: contextWithAnimation(animation, on: context)
            )
        }
    }

    private func startRunTask(
        priority: TaskPriority?,
        operation: @escaping @Sendable (Send<R.Action>) async -> Void,
        context: ExecutionContext?,
        completion: (() -> Void)? = nil
    ) {
        let token = UUID()
        let queue = self.queue

        let send = Send<R.Action> { action in
            let isActive = await MainActor.run { [weak self] in
                self?.runningTasks[token] != nil
            }
            guard isActive else { return }
            await queue.enqueue(action)
        }

        let task = Task(priority: priority) { [weak self] in
            await operation(send)

            await MainActor.run {
                guard let self else { return }
                self.runningTasks.removeValue(forKey: token)

                if let id = context?.cancellationID,
                   var tokens = self.taskIDsByEffectID[id] {
                    tokens.remove(token)
                    if tokens.isEmpty {
                        self.taskIDsByEffectID.removeValue(forKey: id)
                    } else {
                        self.taskIDsByEffectID[id] = tokens
                    }
                }

                completion?()
            }
        }

        runningTasks[token] = task

        if let id = context?.cancellationID {
            taskIDsByEffectID[id, default: []].insert(token)
        }
    }

    private func cancelEffectsSynchronously(identifiedBy id: EffectID) {
        debounceDelayTasksByID.removeValue(forKey: id)?.cancel()
        clearThrottleState(for: id)
        guard let ids = taskIDsByEffectID.removeValue(forKey: id) else { return }

        for token in ids {
            runningTasks.removeValue(forKey: token)?.cancel()
        }
    }

    private func cancelAllEffectsSynchronously() {
        for task in runningTasks.values {
            task.cancel()
        }
        for task in debounceDelayTasksByID.values {
            task.cancel()
        }
        clearAllThrottleState()
        runningTasks.removeAll()
        taskIDsByEffectID.removeAll()
        debounceDelayTasksByID.removeAll()
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

    private func scheduleThrottleTrailing(for id: EffectID, interval: Duration) {
        throttleTrailingTaskByID.removeValue(forKey: id)?.cancel()
        let generation = (throttleGenerationByID[id] ?? 0) &+ 1
        throttleGenerationByID[id] = generation
        throttleTrailingTaskByID[id] = Task { [weak self] in
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            await MainActor.run {
                self?.drainThrottleTrailing(for: id, generation: generation)
            }
        }
    }

    private func drainThrottleTrailing(for id: EffectID, generation: UInt64) {
        guard throttleGenerationByID[id] == generation else {
            return
        }
        defer {
            if throttleGenerationByID[id] == generation {
                throttleTrailingTaskByID.removeValue(forKey: id)
                throttlePendingTrailingByID.removeValue(forKey: id)
                throttleWindowEndByID.removeValue(forKey: id)
                throttleGenerationByID.removeValue(forKey: id)
            }
        }
        guard let pending = throttlePendingTrailingByID[id] else {
            return
        }
        execute(pending.effect, context: pending.context)
    }

    private func clearThrottleState(for id: EffectID) {
        throttleTrailingTaskByID.removeValue(forKey: id)?.cancel()
        throttlePendingTrailingByID.removeValue(forKey: id)
        throttleWindowEndByID.removeValue(forKey: id)
        throttleGenerationByID.removeValue(forKey: id)
    }

    private func clearAllThrottleState() {
        for task in throttleTrailingTaskByID.values {
            task.cancel()
        }
        throttleTrailingTaskByID.removeAll()
        throttlePendingTrailingByID.removeAll()
        throttleWindowEndByID.removeAll()
        throttleGenerationByID.removeAll()
    }

    // MARK: - Receiving

    private func nextActionWithinTimeout() async -> R.Action? {
        let queue = self.queue
        return await withTimeout(effectTimeout) {
            await queue.next()
        }
    }

    private func withTimeout<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                await operation()
            }

            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }

            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}

// MARK: - Assertion Helper

private func testStoreAssertionFailure(
    _ message: String,
    file: StaticString,
    line: UInt
) {
    #if DEBUG
    print("❌ TestStore Assertion Failed:")
    print(message)
    print("File: \(file), Line: \(line)")
    #endif

    #if canImport(XCTest)
    XCTFail(message, file: file, line: line)
    #elseif canImport(Testing)
    Issue.record(message)
    #else
    Swift.assertionFailure(message, file: file, line: line)
    #endif
}
