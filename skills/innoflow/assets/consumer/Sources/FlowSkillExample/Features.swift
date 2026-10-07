import InnoFlow

@InnoFlow
struct CounterFeature {
    struct State: Equatable, Sendable, DefaultInitializable {
        var count = 0
        @BindableField var step = 1
    }
    enum Action: Equatable, Sendable {
        case increment
        case setStep(Int)
    }
    var body: some Reducer<State, Action, Never> {
        Reduce { state, action in
            switch action {
            case .increment: state.count += state.step
            case .setStep(let step): state.step = max(1, step)
            }
            return .none
        }
    }
}

@InnoFlow(phaseManaged: true, strictPhaseTotality: true)
struct LoadFeature {
    struct State: Equatable, Sendable, DefaultInitializable {
        enum Phase: Hashable, Sendable { case idle, loading, loaded, failed }
        var phase: Phase = .idle
        var value: Int?
        var errorMessage: String?
    }
    enum Action: Equatable, Sendable {
        case load
        case cancel
        case loaded(Int)
        case failed(String)
        case select(Int)
    }
    enum Output: Equatable, Sendable { case openDetail(Int) }
    struct Dependencies: Sendable {
        var fetch: @Sendable () async throws -> Int
    }
    let dependencies: Dependencies

    static var phaseMap: PhaseMap<State, Action, State.Phase> {
        PhaseMap(\.phase) {
            From(.idle) { On(.load, to: .loading) }
            From(.loading) {
                On(Action.loadedCasePath, to: .loaded)
                On(Action.failedCasePath, to: .failed)
                On(.cancel, to: .idle)
            }
            From(.loaded) { On(.load, to: .loading) }
            From(.failed) { On(.load, to: .loading) }
        }
    }

    var body: some Reducer<State, Action, Output> {
        Reduce { state, action in
            switch action {
            case .load:
                state.errorMessage = nil
                let fetch = dependencies.fetch
                return .perform(
                    operation: { try await fetch() },
                    success: Action.loaded,
                    failure: { _ in .failed("unavailable") }
                ).cancellable("load", cancelInFlight: true)
            case .cancel:
                return .cancel("load")
            case .loaded(let value):
                state.value = value
                return .none
            case .failed(let message):
                state.errorMessage = message
                return .none
            case .select(let id):
                return Self.output(.openDetail(id))
            }
        }
    }
}

@InnoFlow
struct ParentFeature {
    struct State: Equatable, Sendable, DefaultInitializable {
        var child = LoadFeature.State()
    }
    enum Action: Equatable, Sendable { case child(LoadFeature.Action) }
    enum Output: Equatable, Sendable { case showDetail(Int) }
    let dependencies: LoadFeature.Dependencies

    var body: some Reducer<State, Action, Output> {
        Scope(state: \.child, action: Action.childCasePath,
              reducer: LoadFeature(dependencies: dependencies).mapOutput { output in
            switch output { case .openDetail(let id): return Output.showDetail(id) }
        })
    }
}

@InnoFlow
struct DelayedFeature {
    struct State: Equatable, Sendable, DefaultInitializable {
        var completed: [Int] = []
    }
    enum Action: Equatable, Sendable { case start(Int), finished(Int) }
    var body: some Reducer<State, Action, Never> {
        Reduce { state, action in
            switch action {
            case .start(let id):
                return .run { send, context in
                    do {
                        try await context.sleep(for: .seconds(1))
                        await send(.finished(id))
                    } catch {
                        // This run only awaits the cancellable clock.
                        return
                    }
                }
            case .finished(let id):
                state.completed.append(id)
                return .none
            }
        }
    }
}
