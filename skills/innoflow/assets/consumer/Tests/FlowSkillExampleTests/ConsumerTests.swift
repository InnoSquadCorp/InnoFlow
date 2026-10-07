import InnoFlow
import InnoFlowSwiftUI
import InnoFlowTesting
import Testing
@testable import FlowSkillExample

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ConsumerTests {
    @Test func exhaustiveCounterUsesThreeGenericReducer() async {
        let store = TestStore(reducer: CounterFeature())
        await store.send(.setStep(3)) { $0.step = 3 }
        await store.send(.increment) { $0.count = 3 }
        await store.finish()
    }

    @Test func swiftUIBindingSendsAnAction() async {
        let store = Store(reducer: CounterFeature())
        let binding = store.binding(\.$step, to: CounterFeature.Action.setStep)
        binding.wrappedValue = 4
        await store.send(.increment).finish()
        #expect(store.state.step == 4)
        #expect(store.state.count == 4)
        _ = CounterView(store: store)
    }

    @Test func phaseManagedSuccess() async {
        let store = TestStore(reducer: LoadFeature(dependencies: .init(fetch: { 42 })))
        await store.send(.load, through: LoadFeature.phaseMap) { $0.phase = .loading }
        await store.receive(.loaded(42), through: LoadFeature.phaseMap) {
            $0.phase = .loaded
            $0.value = 42
        }
        await store.finish()
    }

    @Test func failureAndExplicitRetry() async {
        let attempts = Attempts()
        let store = TestStore(reducer: LoadFeature(dependencies: .init(fetch: { try await attempts.fetch() })))
        await store.send(.load) { $0.phase = .loading }
        await store.receive(.failed("unavailable")) {
            $0.phase = .failed
            $0.errorMessage = "unavailable"
        }
        await store.send(.load) {
            $0.phase = .loading
            $0.errorMessage = nil
        }
        await store.receive(.loaded(7)) { $0.phase = .loaded; $0.value = 7 }
        await store.finish()
    }

    @Test func thrownCancellationErrorIsFailureWhileActive() async {
        let store = TestStore(reducer: LoadFeature(dependencies: .init(fetch: { throw CancellationError() })))
        await store.send(.load) { $0.phase = .loading }
        await store.receive(.failed("unavailable")) {
            $0.phase = .failed
            $0.errorMessage = "unavailable"
        }
        await store.finish()
    }

    @Test func typedOutputIsConsumedExhaustively() async {
        let store = TestStore(reducer: LoadFeature(dependencies: .init(fetch: { 0 })))
        await store.send(.select(9))
        let id = await store.receiveOutput(LoadFeature.Output.openDetailCasePath)
        #expect(id == 9)
        await store.finish()
    }

    @Test func parentScopeLiftsChildOutput() async {
        let store = TestStore(reducer: ParentFeature(dependencies: .init(fetch: { 5 })))
        let child = store.scope(state: \.child, action: ParentFeature.Action.childCasePath)
        await child.send(.load) { $0.phase = .loading }
        await child.receive(.loaded(5)) { $0.phase = .loaded; $0.value = 5 }
        await store.send(.child(.select(5)))
        await store.receiveOutput(.showDetail(5))
        await store.finish()
    }

    @Test func capturedOutputIncludesSynchronousEmission() async {
        let store = Store(reducer: LoadFeature(dependencies: .init(fetch: { 0 })))
        let dispatch = store.send(.select(12), capturingOutputs: .bufferingNewest(1))
        var received: [LoadFeature.Output] = []
        for await output in dispatch.outputs { received.append(output) }
        await dispatch.finish()
        #expect(received == [.openDetail(12)])
        #expect(dispatch.isFinished)
    }

    @Test func testStoreUsesRegistrationAwareManualTime() async throws {
        let clock = ManualTestClock()
        let store = TestStore(reducer: DelayedFeature(), clock: clock)
        await store.send(.start(1))
        try await clock.advance(by: .seconds(1), onceSleepersReach: 1)
        await store.receive(.finished(1)) { $0.completed = [1] }
        await store.finish()
    }

    @Test func cancellationIsScopedToOneDispatch() async throws {
        let clock = ManualTestClock()
        let store = Store(reducer: DelayedFeature(), clock: .manual(clock))
        let first = store.send(.start(1))
        let second = store.send(.start(2))
        try await clock.waitForSleepers(atLeast: 2)
        first.cancel()
        await first.finish()
        try await clock.advance(by: .seconds(1), onceSleepersReach: 1)
        await second.finish()
        #expect(first.isCancelled)
        #expect(second.isCancelled == false)
        #expect(store.state.completed == [2])
    }

    @Test func lexicalScopeCancelsOnlyTrackedWork() async throws {
        let clock = ManualTestClock()
        let store = Store(reducer: DelayedFeature(), clock: .manual(clock))
        let independent = store.send(.start(2))
        let owned = try await withFlowScope { scope in
            let owned = await scope.track(store.send(.start(1)))
            try await clock.waitForSleepers(atLeast: 2)
            return owned
        }
        #expect(owned.isCancelled && owned.isFinished)
        try await clock.advance(by: .seconds(1), onceSleepersReach: 1)
        await independent.finish()
        #expect(store.state.completed == [2])
        #expect(independent.isCancelled == false)
    }
}

private actor Attempts {
    enum Failure: Error { case unavailable }
    var count = 0
    func fetch() throws -> Int {
        count += 1
        if count == 1 { throw Failure.unavailable }
        return 7
    }
}
