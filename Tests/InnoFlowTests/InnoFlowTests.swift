// MARK: - InnoFlowTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import Testing
import SwiftUI
@testable import InnoFlow
@testable import InnoFlowTesting

// MARK: - Fixtures

struct CounterFeature: Reducer {
    struct State: Equatable, Sendable, DefaultInitializable {
        var count = 0
        init() {}
        init(count: Int) { self.count = count }
    }

    enum Action: Equatable, Sendable {
        case increment
        case decrement
        case reset
    }

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
        switch action {
        case .increment:
            state.count += 1
            return .none
        case .decrement:
            state.count -= 1
            return .none
        case .reset:
            state.count = 0
            return .none
        }
    }
}

struct AsyncFeature: Reducer {
    struct State: Equatable, Sendable, DefaultInitializable {
        var value: String = ""
        var isLoading = false
    }

    enum Action: Equatable, Sendable {
        case load
        case _loaded(String)
    }

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
        switch action {
        case .load:
            state.isLoading = true
            return .run { send in
                await send(._loaded("Hello, InnoFlow v2"))
            }
        case ._loaded(let value):
            state.value = value
            state.isLoading = false
            return .none
        }
    }
}

struct ImmediateSendFeature: Reducer {
    struct State: Equatable, Sendable, DefaultInitializable {
        var logs: [String] = []
    }

    enum Action: Equatable, Sendable {
        case trigger
        case _logged(String)
    }

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
        switch action {
        case .trigger:
            return .send(._logged("event"))
        case ._logged(let value):
            state.logs.append(value)
            return .none
        }
    }
}

struct CancellableFeature: Reducer {
    struct State: Equatable, Sendable, DefaultInitializable {
        var completed: [Int] = []
        var requested = 0
    }

    enum Action: Equatable, Sendable {
        case start(Int)
        case _completed(Int)
    }

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
        switch action {
        case .start(let value):
            state.requested += 1
            return .run { send in
                do {
                    try await Task.sleep(for: .milliseconds(200))
                    await send(._completed(value))
                } catch {
                    // Cancellation should stop action emission.
                }
            }
            .cancellable("load", cancelInFlight: true)

        case ._completed(let value):
            state.completed.append(value)
            return .none
        }
    }
}

struct UncooperativeCancellableFeature: Reducer {
    struct State: Equatable, Sendable, DefaultInitializable {
        var completed: [String] = []
    }

    enum Action: Equatable, Sendable {
        case start
        case _completed(String)
    }

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
        switch action {
        case .start:
            return .run { send in
                // Intentionally ignores cancellation and still tries to emit.
                let jitter = Int.random(in: 20...80)
                try? await Task.sleep(for: .milliseconds(jitter))
                await send(._completed("late-value"))
            }
            .cancellable("uncooperative")

        case ._completed(let value):
            state.completed.append(value)
            return .none
        }
    }
}

struct CompositeUncooperativeFeature: Reducer {
    struct State: Equatable, Sendable, DefaultInitializable {
        var completed: [Int] = []
    }

    enum Action: Equatable, Sendable {
        case start(Int)
        case _completed(Int)
    }

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
        switch action {
        case .start(let value):
            return .concatenate(
                .merge(
                    .run { send in
                        let jitter = Int.random(in: 10...30)
                        try? await Task.sleep(for: .milliseconds(jitter))
                        await send(._completed(value * 10 + 1))
                    },
                    .run { send in
                        let jitter = Int.random(in: 20...40)
                        try? await Task.sleep(for: .milliseconds(jitter))
                        await send(._completed(value * 10 + 2))
                    }
                ),
                .run { send in
                    let jitter = Int.random(in: 30...60)
                    try? await Task.sleep(for: .milliseconds(jitter))
                    await send(._completed(value * 10 + 3))
                }
            )
            .cancellable("composite-uncooperative")

        case ._completed(let value):
            state.completed.append(value)
            return .none
        }
    }
}

struct ScopedCounterFeature: Reducer {
    struct State: Equatable, Sendable, DefaultInitializable {
        struct Child: Equatable, Sendable {
            var count = 0
        }
        var child = Child()
    }

    enum Action: Equatable, Sendable {
        case childIncrement
    }

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
        switch action {
        case .childIncrement:
            state.child.count += 1
            return .none
        }
    }
}

struct BindingFeature: Reducer {
    struct State: Equatable, Sendable, DefaultInitializable {
        var step = BindableProperty(1)
    }

    enum Action: Equatable, Sendable {
        case setStep(Int)
    }

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
        switch action {
        case .setStep(let step):
            state.step.value = max(1, step)
            return .none
        }
    }
}

struct DebounceFeature: Reducer {
    struct State: Equatable, Sendable, DefaultInitializable {
        var emitted: [Int] = []
    }

    enum Action: Equatable, Sendable {
        case trigger(Int)
        case _emitted(Int)
    }

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
        switch action {
        case .trigger(let value):
            return EffectTask.send(._emitted(value))
                .debounce("debounce-effect", for: .milliseconds(60))
        case ._emitted(let value):
            state.emitted.append(value)
            return .none
        }
    }
}

struct ThrottleFeature: Reducer {
    struct State: Equatable, Sendable, DefaultInitializable {
        var emitted: [Int] = []
    }

    enum Action: Equatable, Sendable {
        case trigger(Int)
        case _emitted(Int)
    }

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
        switch action {
        case .trigger(let value):
            return EffectTask.send(._emitted(value))
                .throttle("throttle-effect", for: .milliseconds(80))
        case ._emitted(let value):
            state.emitted.append(value)
            return .none
        }
    }
}

struct ThrottleTrailingFeature: Reducer {
    struct State: Equatable, Sendable, DefaultInitializable {
        var emitted: [Int] = []
    }

    enum Action: Equatable, Sendable {
        case trigger(Int)
        case _emitted(Int)
    }

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
        switch action {
        case .trigger(let value):
            return EffectTask.send(._emitted(value))
                .throttle("throttle-trailing", for: .milliseconds(80), leading: false, trailing: true)
        case ._emitted(let value):
            state.emitted.append(value)
            return .none
        }
    }
}

struct ThrottleLeadingTrailingFeature: Reducer {
    struct State: Equatable, Sendable, DefaultInitializable {
        var emitted: [Int] = []
    }

    enum Action: Equatable, Sendable {
        case trigger(Int)
        case _emitted(Int)
    }

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
        switch action {
        case .trigger(let value):
            return EffectTask.send(._emitted(value))
                .throttle("throttle-leading-trailing", for: .milliseconds(80), leading: true, trailing: true)
        case ._emitted(let value):
            state.emitted.append(value)
            return .none
        }
    }
}

struct AnimationFeature: Reducer {
    struct State: Equatable, Sendable, DefaultInitializable {
        var values: [Int] = []
    }

    enum Action: Equatable, Sendable {
        case animate(Int)
        case animateRun(Int)
        case _animated(Int)
    }

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
        switch action {
        case .animate(let value):
            return EffectTask.send(._animated(value))
                .animation(.easeInOut)

        case .animateRun(let value):
            return EffectTask.run { send in
                await send(._animated(value))
            }
            .animation(.spring())

        case ._animated(let value):
            state.values.append(value)
            return .none
        }
    }
}

struct ComposedAnimationFeature: Reducer {
    struct State: Equatable, Sendable, DefaultInitializable {
        var value = 0
    }

    enum Action: Equatable, Sendable {
        case trigger(Int)
        case _result(Int)
    }

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
        switch action {
        case .trigger(let value):
            return EffectTask.send(._result(value))
                .debounce("animation-debounce", for: .milliseconds(30))
                .animation(.easeInOut)
        case ._result(let value):
            state.value = value
            return .none
        }
    }
}

struct CombinatorCompositionFeature: Reducer {
    struct State: Equatable, Sendable, DefaultInitializable {
        var debounced: [Int] = []
        var throttled: [Int] = []
    }

    enum Action: Equatable, Sendable {
        case start(Int)
        case _debounced(Int)
        case _throttled(Int)
    }

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
        switch action {
        case .start(let value):
            return .merge(
                EffectTask.send(._debounced(value))
                    .debounce("compose-debounce", for: .milliseconds(50)),
                EffectTask.send(._throttled(value))
                    .throttle("compose-throttle", for: .milliseconds(50))
            )
        case ._debounced(let value):
            state.debounced.append(value)
            return .none
        case ._throttled(let value):
            state.throttled.append(value)
            return .none
        }
    }
}

actor DeinitCancellationProbe {
    private(set) var started = 0
    private(set) var cancelled = 0
    private(set) var completed = 0

    func markStarted() {
        started += 1
    }

    func markCancelled() {
        cancelled += 1
    }

    func markCompleted() {
        completed += 1
    }
}

struct DeinitCancellationFeature: Reducer {
    struct State: Equatable, Sendable, DefaultInitializable {
        var started = false
    }

    enum Action: Equatable, Sendable {
        case start
        case _finished
    }

    let probe: DeinitCancellationProbe

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
        switch action {
        case .start:
            state.started = true
            return .run { send in
                await probe.markStarted()
                do {
                    try await Task.sleep(for: .seconds(5))
                    await probe.markCompleted()
                    await send(._finished)
                } catch {
                    await probe.markCancelled()
                }
            }
            .cancellable("deinit-effect")
        case ._finished:
            return .none
        }
    }
}

// MARK: - EffectTask Tests

@Suite("EffectTask Tests")
@MainActor
struct EffectTaskTests {

    @Test("EffectID supports StaticString literals")
    func effectIDStaticStringLiteral() {
        let first: EffectID = "load-user"
        let second = EffectID("load-user")

        #expect(first == second)
        #expect(String(describing: first.rawValue) == "load-user")
    }

    @Test("EffectID rejects dynamic String construction at compile time")
    func effectIDRejectsDynamicStringConstruction() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

        let source = """
        import InnoFlow

        let dynamic = String("dynamic-id")
        let _ = EffectID(dynamic)
        """

        let result = try typecheckSource(
            source,
            moduleDirectory: moduleDirectory
        )

        #expect(result.status != 0)
        #expect(
            result.output.contains("StaticString")
                || result.output.contains("cannot convert value of type 'String'")
        )
    }

    @Test("Store.binding rejects non-bindable key paths at compile time")
    func bindingRejectsNonBindableKeyPathAtCompileTime() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

        let source = """
        import InnoFlow

        struct NonBindableFeature: Reducer {
            struct State: Sendable, DefaultInitializable {
                var count = 0
                init() {}
            }

            enum Action: Sendable {
                case setCount(Int)
            }

            func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
                .none
            }
        }

        @MainActor
        func compileContract() {
            let store = Store(reducer: NonBindableFeature(), initialState: .init())
            _ = store.binding(\\.count, send: { .setCount($0) })
        }
        """

        let result = try typecheckSource(
            source,
            moduleDirectory: moduleDirectory
        )

        #expect(result.status != 0)
        #expect(
            result.output.contains("BindableProperty")
                || result.output.contains("KeyPath")
        )
    }

    @Test("EffectTask.none does not emit follow-up actions")
    func effectNone() async {
        let store = TestStore(reducer: CounterFeature(), initialState: .init())

        await store.send(.increment) {
            $0.count = 1
        }

        await store.assertNoMoreActions()
    }

    @Test("EffectTask.send emits a follow-up action")
    func effectSend() async {
        let store = TestStore(reducer: ImmediateSendFeature(), initialState: .init())

        await store.send(.trigger)

        await store.receive(._logged("event")) {
            $0.logs = ["event"]
        }

        await store.assertNoMoreActions()
    }

    @Test("EffectTask.cancellable keeps only the latest in-flight effect")
    func effectCancellable() async {
        let store = TestStore(reducer: CancellableFeature(), initialState: .init())

        await store.send(.start(1)) {
            $0.requested = 1
        }
        await store.send(.start(2)) {
            $0.requested = 2
        }

        await store.receive(._completed(2)) {
            $0.completed = [2]
        }

        await store.assertNoMoreActions()
    }

    @Test("EffectTask.debounce keeps only the latest trigger")
    func effectDebounce() async {
        let store = TestStore(reducer: DebounceFeature(), initialState: .init())

        await store.send(.trigger(1))
        await store.send(.trigger(2))

        await store.receive(._emitted(2)) {
            $0.emitted = [2]
        }

        await store.assertNoMoreActions()
    }

    @Test("EffectTask.throttle uses leading-only semantics")
    func effectThrottleLeadingOnly() async {
        let store = TestStore(reducer: ThrottleFeature(), initialState: .init())

        await store.send(.trigger(1))
        await store.send(.trigger(2))

        await store.receive(._emitted(1)) {
            $0.emitted = [1]
        }
        await store.assertNoMoreActions()

        try? await Task.sleep(for: .milliseconds(160))
        await store.send(.trigger(3))
        await store.receive(._emitted(3)) {
            $0.emitted = [1, 3]
        }
        await store.assertNoMoreActions()
    }

    @Test("EffectTask.throttle trailing-only executes latest at window end")
    func effectThrottleTrailingOnly() async {
        let store = TestStore(reducer: ThrottleTrailingFeature(), initialState: .init())

        await store.send(.trigger(1))
        await store.send(.trigger(2))

        await store.receive(._emitted(2)) {
            $0.emitted = [2]
        }
        await store.assertNoMoreActions()
    }

    @Test("EffectTask.throttle leading+trailing executes both when window has extra event")
    func effectThrottleLeadingAndTrailing() async {
        let store = TestStore(reducer: ThrottleLeadingTrailingFeature(), initialState: .init())

        await store.send(.trigger(1))
        await store.send(.trigger(2))

        await store.receive(._emitted(1)) {
            $0.emitted = [1]
        }
        await store.receive(._emitted(2)) {
            $0.emitted = [1, 2]
        }
        await store.assertNoMoreActions()
    }

    @Test("EffectTask.animation executes nested send and run effects")
    func effectAnimationExecutes() async {
        let store = TestStore(reducer: AnimationFeature(), initialState: .init())

        await store.send(.animate(1))
        await store.receive(._animated(1)) {
            $0.values = [1]
        }

        await store.send(.animateRun(2))
        await store.receive(._animated(2)) {
            $0.values = [1, 2]
        }

        await store.assertNoMoreActions()
    }

    @Test("EffectTask.animation composes with debounce")
    func effectAnimationComposedWithDebounce() async {
        let store = TestStore(reducer: ComposedAnimationFeature(), initialState: .init())

        await store.send(.trigger(1))
        await store.receive(._result(1)) {
            $0.value = 1
        }
        await store.assertNoMoreActions()
    }
}

// MARK: - Store Tests

@Suite("Store Tests")
@MainActor
struct StoreTests {

    @Test("Store initializes with explicit state")
    func storeInitialization() {
        let store = Store(reducer: CounterFeature(), initialState: .init(count: 10))
        #expect(store.count == 10)
    }

    @Test("Store processes synchronous actions")
    func storeSyncActions() {
        let store = Store(reducer: CounterFeature(), initialState: .init(count: 0))

        store.send(.increment)
        store.send(.increment)
        store.send(.decrement)

        #expect(store.count == 1)
    }

    @Test("ScopedStore reflects child state and forwards actions")
    func scopedStoreProjectionAndForwarding() {
        let store = Store(reducer: ScopedCounterFeature(), initialState: .init())
        let scoped = store.scope(
            state: \.child,
            action: { (action: ScopedCounterFeature.Action) in action }
        )

        #expect(scoped.count == 0)
        scoped.send(.childIncrement)
        #expect(scoped.count == 1)
        #expect(store.state.child.count == 1)
    }

    @Test("Store.binding reads and writes bindable field")
    func bindingPositivePath() {
        let store = Store(reducer: BindingFeature(), initialState: .init())
        let binding = store.binding(\.step, send: { .setStep($0) })

        #expect(binding.wrappedValue == 1)
        binding.wrappedValue = 5
        #expect(store.step == 5)
    }

    @Test("Store processes async run effect")
    func storeAsyncEffect() async {
        let store = Store(reducer: AsyncFeature(), initialState: .init())

        store.send(.load)
        #expect(store.isLoading)

        for _ in 0..<20 {
            if store.value == "Hello, InnoFlow v2" {
                break
            }
            await Task.yield()
        }

        #expect(store.value == "Hello, InnoFlow v2")
        #expect(store.isLoading == false)
    }

    @Test("Store cancelEffects waits for cancellation bookkeeping")
    func storeCancelEffects() async {
        let store = Store(reducer: CancellableFeature(), initialState: .init())

        store.send(.start(1))
        await store.cancelEffects(identifiedBy: "load")

        try? await Task.sleep(for: .milliseconds(300))
        #expect(store.completed.isEmpty)
    }

    @Test("Store cancelAllEffects cancels pending effects")
    func storeCancelAllEffects() async {
        let store = Store(reducer: CancellableFeature(), initialState: .init())

        store.send(.start(1))
        await store.cancelAllEffects()

        try? await Task.sleep(for: .milliseconds(300))
        #expect(store.completed.isEmpty)
    }

    @Test("Store drops emissions from cancelled uncooperative effects")
    func storeDropsCancelledEffectEmission() async {
        let store = Store(
            reducer: UncooperativeCancellableFeature(),
            initialState: .init()
        )

        store.send(.start)
        await store.cancelEffects(identifiedBy: "uncooperative")

        try? await Task.sleep(for: .milliseconds(150))
        #expect(store.completed.isEmpty)
    }

    @Test("Store repeatedly drops late emissions after cancelEffects")
    func storeCancellationStress() async {
        let store = Store(
            reducer: UncooperativeCancellableFeature(),
            initialState: .init()
        )
        let iterations = isHeavyStressEnabled ? 1_000 : 200

        for _ in 0..<iterations {
            store.send(.start)
            await store.cancelEffects(identifiedBy: "uncooperative")
        }

        try? await Task.sleep(for: .milliseconds(250))
        #expect(store.completed.isEmpty)
    }

    @Test("Store applies cancellation boundaries to merge and concatenate")
    func storeCancellationBoundaryOnComposedEffects() async {
        let store = Store(
            reducer: CompositeUncooperativeFeature(),
            initialState: .init()
        )

        for value in 0..<120 {
            store.send(.start(value))
            await store.cancelEffects(identifiedBy: "composite-uncooperative")
        }

        try? await Task.sleep(for: .milliseconds(300))
        #expect(store.completed.isEmpty)
    }

    @Test("Store combinator composition keeps debounce and throttle semantics")
    func storeCombinatorComposition() async {
        let store = Store(
            reducer: CombinatorCompositionFeature(),
            initialState: .init()
        )

        store.send(.start(1))
        store.send(.start(2))

        for _ in 0..<40 {
            if store.debounced == [2], store.throttled == [1] {
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.debounced == [2])
        #expect(store.throttled == [1])
    }

    @Test("Store throttle trailing-only emits latest value at window end")
    func storeThrottleTrailingOnly() async {
        let store = Store(
            reducer: ThrottleTrailingFeature(),
            initialState: .init()
        )

        store.send(.trigger(1))
        store.send(.trigger(2))

        for _ in 0..<40 {
            if store.emitted == [2] {
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.emitted == [2])
    }

    @Test("Store throttle leading+trailing skips trailing when no extra event")
    func storeThrottleLeadingTrailingSingleEvent() async {
        let store = Store(
            reducer: ThrottleLeadingTrailingFeature(),
            initialState: .init()
        )

        store.send(.trigger(1))
        try? await Task.sleep(for: .milliseconds(160))
        #expect(store.emitted == [1])
    }

    @Test("Store cancelEffects drops pending throttle trailing emission")
    func storeThrottleTrailingCancelledByID() async {
        let store = Store(
            reducer: ThrottleTrailingFeature(),
            initialState: .init()
        )

        store.send(.trigger(1))
        store.send(.trigger(2))
        await store.cancelEffects(identifiedBy: "throttle-trailing")

        try? await Task.sleep(for: .milliseconds(120))
        #expect(store.emitted.isEmpty)
    }

    @Test("Store cancelAllEffects drops pending throttle trailing emission")
    func storeThrottleTrailingCancelledByAll() async {
        let store = Store(
            reducer: ThrottleTrailingFeature(),
            initialState: .init()
        )

        store.send(.trigger(1))
        store.send(.trigger(2))
        await store.cancelAllEffects()

        try? await Task.sleep(for: .milliseconds(120))
        #expect(store.emitted.isEmpty)
    }

    @Test("Store deinit prevents long-running effect completion")
    func storeDeinitPreventsLongRunningCompletion() async {
        let probe = DeinitCancellationProbe()
        var store: Store<DeinitCancellationFeature>? = Store(
            reducer: DeinitCancellationFeature(probe: probe),
            initialState: .init()
        )

        store?.send(.start)

        for _ in 0..<20 {
            if await probe.started == 1 {
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        store = nil

        try? await Task.sleep(for: .milliseconds(500))

        #expect(await probe.started == 1)
        #expect(await probe.completed == 0)
    }
}

// MARK: - TestStore Tests

@Suite("TestStore Tests")
@MainActor
struct TestStoreTests {

    @Test("TestStore validates send + receive with deterministic flow")
    func testStoreReceive() async {
        let store = TestStore(
            reducer: AsyncFeature(),
            initialState: .init(),
            effectTimeout: .seconds(3)
        )

        await store.send(.load) {
            $0.isLoading = true
        }

        await store.receive(._loaded("Hello, InnoFlow v2")) {
            $0.value = "Hello, InnoFlow v2"
            $0.isLoading = false
        }

        await store.assertNoMoreActions()
    }

    @Test("TestStore async cancellation API prevents pending effect emission")
    func testStoreCancelEffects() async {
        let store = TestStore(reducer: CancellableFeature(), initialState: .init())

        await store.send(.start(1)) {
            $0.requested = 1
        }

        await store.cancelEffects(identifiedBy: "load")
        await store.assertNoMoreActions()
    }

    @Test("TestStore drops emissions from cancelled uncooperative effects")
    func testStoreDropsCancelledEffectEmission() async {
        let store = TestStore(
            reducer: UncooperativeCancellableFeature(),
            initialState: .init()
        )

        await store.send(.start)
        await store.cancelEffects(identifiedBy: "uncooperative")
        await store.assertNoMoreActions()
    }

    @Test("TestStore repeated cancellation stress keeps queue clean")
    func testStoreCancellationStress() async {
        let store = TestStore(
            reducer: UncooperativeCancellableFeature(),
            initialState: .init()
        )
        let iterations = isHeavyStressEnabled ? 1_000 : 120

        for _ in 0..<iterations {
            await store.send(.start)
            await store.cancelEffects(identifiedBy: "uncooperative")
        }

        await store.assertNoMoreActions()
    }
}

// MARK: - Compile Contract Helpers

private var isHeavyStressEnabled: Bool {
    ProcessInfo.processInfo.environment["INNOFLOW_HEAVY_STRESS"] == "1"
}

private struct TypecheckResult {
    let status: Int32
    let output: String
}

private final class ThreadSafeDataBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private enum CompileContractError: Error, CustomStringConvertible {
    case moduleNotFound(attemptedPaths: [String])

    var description: String {
        switch self {
        case .moduleNotFound(let attemptedPaths):
            let formattedPaths = attemptedPaths
                .map { "- \($0)" }
                .joined(separator: "\n")
            return """
            Failed to locate InnoFlow.swiftmodule.
            Attempted search locations:
            \(formattedPaths)
            """
        }
    }
}

private func findBuiltInnoFlowModuleDirectory(in packageRoot: URL) throws -> URL {
    let fileManager = FileManager.default
    let buildDirectory = packageRoot.appendingPathComponent(".build", isDirectory: true)
    var attemptedPaths: [String] = [
        packageRoot.path,
        buildDirectory.path,
        buildDirectory.appendingPathComponent("debug", isDirectory: true).path,
        buildDirectory.appendingPathComponent("release", isDirectory: true).path,
        buildDirectory.appendingPathComponent("arm64-apple-macosx/debug", isDirectory: true).path,
        buildDirectory.appendingPathComponent("x86_64-apple-macosx/debug", isDirectory: true).path,
        buildDirectory.appendingPathComponent("arm64-apple-macosx/release", isDirectory: true).path,
        buildDirectory.appendingPathComponent("x86_64-apple-macosx/release", isDirectory: true).path
    ]
    if let buildChildren = try? fileManager.contentsOfDirectory(
        at: buildDirectory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) {
        for child in buildChildren {
            attemptedPaths.append(child.path)
            attemptedPaths.append(child.appendingPathComponent("debug", isDirectory: true).path)
            attemptedPaths.append(child.appendingPathComponent("release", isDirectory: true).path)
        }
    }
    attemptedPaths = Array(Set(attemptedPaths)).sorted()

    guard let enumerator = fileManager.enumerator(
        at: buildDirectory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        throw CompileContractError.moduleNotFound(attemptedPaths: attemptedPaths)
    }

    for case let fileURL as URL in enumerator where fileURL.lastPathComponent == "InnoFlow.swiftmodule" {
        return fileURL.deletingLastPathComponent()
    }

    throw CompileContractError.moduleNotFound(attemptedPaths: attemptedPaths)
}

private func typecheckSource(
    _ source: String,
    moduleDirectory: URL
) throws -> TypecheckResult {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let sourceFile = temporaryDirectory.appendingPathComponent("CompileContract.swift")
    try source.write(to: sourceFile, atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = [
        "swiftc",
        "-typecheck",
        sourceFile.path,
        "-I",
        moduleDirectory.path,
    ]

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let stdoutBuffer = ThreadSafeDataBuffer()
    let stderrBuffer = ThreadSafeDataBuffer()

    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }
        stdoutBuffer.append(data)
    }

    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }
        stderrBuffer.append(data)
    }

    try process.run()
    process.waitUntilExit()

    stdoutPipe.fileHandleForReading.readabilityHandler = nil
    stderrPipe.fileHandleForReading.readabilityHandler = nil

    var stderrData = stderrBuffer.snapshot()

    var stdoutData = stdoutBuffer.snapshot()
    let stderrTail = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    let stdoutTail = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    if !stdoutTail.isEmpty {
        stdoutData.append(stdoutTail)
    }
    if !stderrTail.isEmpty {
        stderrData.append(stderrTail)
    }

    let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
    let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

    return TypecheckResult(
        status: process.terminationStatus,
        output: stdoutText + "\n" + stderrText
    )
}
