# InnoFlow

A lightweight, SwiftUI-native unidirectional architecture framework.

## Core Principles

InnoFlow v2 focuses on:

- **Single reducer contract**: `reduce(into:action:) -> EffectTask<Action>`
- **Explicit async model**: one `EffectTask` DSL for run/merge/concatenate/cancel/combinators
- **Cancellation completion contract**: store cancellation APIs are `async`
- **SwiftUI-first runtime**: `@Observable` store + `@MainActor` state adapter
- **Strict binding intent**: only `@BindableField` properties are bindable
- **Deterministic testing**: `TestStore` with timeout/cancellation-oriented flow

## State Ownership

InnoFlow is the preferred place to model **business and domain state transitions** across the
InnoSquad framework family.

- Use `InnoFlow` for feature lifecycle and orchestration.
- Let `InnoRouter` own navigation transitions.
- Let `InnoNetwork` own transport/session lifecycle transitions.
- Let `InnoDI` remain a static dependency graph validator rather than a runtime state machine.

This keeps one transition owned by one framework and avoids duplicating the same lifecycle in
multiple layers.

**요약(KR)**: InnoFlow v2는 단일 reducer 계약, 명시적 effect DSL, async 취소 완료 보장, SwiftUI 친화 런타임을 핵심 원칙으로 둡니다.

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/InnoSquad-mdd/InnoFlow.git", branch: "main")
]
```

```swift
.target(
    name: "YourApp",
    dependencies: ["InnoFlow"]
)

.testTarget(
    name: "YourAppTests",
    dependencies: ["InnoFlow", "InnoFlowTesting"]
)
```

## Quick Start

**요약(KR)**: `@InnoFlow` feature를 정의하고 `Store`를 SwiftUI `View`에 연결하면 기본 UDF 흐름을 바로 사용할 수 있습니다.

### 1. Define a Feature

```swift
import InnoFlow

@InnoFlow
struct CounterFeature {
    struct State: Equatable, Sendable, DefaultInitializable {
        var count = 0
        @BindableField var step = 1

        init() {}
    }

    enum Action: Sendable {
        case increment
        case decrement
        case setStep(Int)
    }

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
        switch action {
        case .increment:
            state.count += state.step
            return .none

        case .decrement:
            state.count -= state.step
            return .none

        case .setStep(let step):
            state.step = max(1, step)
            return .none
        }
    }
}
```

### 2. Use in SwiftUI

```swift
import SwiftUI
import InnoFlow

struct CounterView: View {
    @State private var store = Store(reducer: CounterFeature())

    var body: some View {
        VStack(spacing: 20) {
            Text("Count: \(store.count)")
                .font(.largeTitle)

            HStack(spacing: 32) {
                Button("−") { store.send(.decrement) }
                Button("+") { store.send(.increment) }
            }

            Stepper(
                "Step: \(store.step)",
                value: store.binding(\.step, send: { .setStep($0) })
            )
        }
    }
}
```

## Side Effects with `EffectTask`

```swift
@InnoFlow
struct UserFeature {
    struct State: Equatable, Sendable {
        var user: User?
        var isLoading = false
        var errorMessage: String?
    }

    enum Action: Sendable {
        case load
        case _loaded(Result<User, Error>)
    }

    let userService: UserServiceProtocol

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
        switch action {
        case .load:
            state.isLoading = true
            state.errorMessage = nil

            return .run { send in
                do {
                    let user = try await userService.fetchUser()
                    await send(._loaded(.success(user)))
                } catch {
                    await send(._loaded(.failure(error)))
                }
            }
            .cancellable("load-user", cancelInFlight: true)

        case ._loaded(.success(let user)):
            state.user = user
            state.isLoading = false
            return .none

        case ._loaded(.failure(let error)):
            state.errorMessage = error.localizedDescription
            state.isLoading = false
            return .none
        }
    }
}
```

### Effect DSL Summary

```swift
// fire-and-forget action emission
EffectTask<Action>.send(.someAction)

// async work
EffectTask<Action>.run { send in
    await send(.someAction)
}

// composition
EffectTask<Action>.merge(effectA, effectB)
EffectTask<Action>.concatenate(effectA, effectB)

// cancellation
EffectTask<Action>.cancel("task-id")
effect.cancellable("task-id", cancelInFlight: true)

// built-in combinators
effect.debounce("search-query", for: .milliseconds(300))
effect.throttle("scroll-event", for: .milliseconds(100))
effect.throttle("search-query", for: .milliseconds(300), leading: false, trailing: true)

// state-transition animation from effect-emitted actions
effect.animation(.easeInOut)
```

Throttle semantics:

- `leading: true, trailing: false`: leading-only (default)
- `leading: false, trailing: true`: trailing-only
- `leading: true, trailing: true`: leading + trailing (trailing fires only when there is an additional in-window event)
- `leading: false, trailing: false`: invalid (`precondition` failure)

`EffectID` is `StaticString`-based, so cancellation identifiers are compile-time literals by default.
**요약(KR)**: 취소 ID는 동적 문자열이 아니라 코드 상수 리터럴을 사용합니다.

## Optional Phase-Driven FSM Modeling

InnoFlow does not ship a general automata runtime. Instead, complex features can model legal
phase transitions explicitly while keeping the reducer contract unchanged.

```swift
enum LoadPhase: Hashable, Sendable {
    case idle
    case loading
    case loaded
    case failed
}

let phaseGraph = PhaseTransitionGraph<LoadPhase>([
    .init(from: .idle, to: .loading),
    .init(from: .loading, to: .loaded),
    .init(from: .loading, to: .failed),
])
```

In tests, `InnoFlowTesting` can validate that reducer actions follow the documented phase graph:

```swift
let store = TestStore(reducer: Feature())

await store.send(.load, tracking: \.phase, through: phaseGraph) {
    $0.phase = .loading
}
```

Use this pattern for deterministic, feature-level FSMs. Do not treat `InnoFlow` as a generic
NFA/PDA framework.

For a fuller guide, see [PHASE_DRIVEN_MODELING.md](./PHASE_DRIVEN_MODELING.md) or the
DocC article `Phase-Driven Modeling`.

### Store Cancellation APIs (async completion)

```swift
// cancellation bookkeeping is guaranteed when the await returns
Task {
    await store.cancelEffects(identifiedBy: "load-user")
    await store.cancelAllEffects()
}
```

Cancellation contract:

- When `await` returns, cancellation bookkeeping is complete.
- Late actions from canceled effect tokens are dropped by runtime guards.

**요약(KR)**: `await` 반환 시점에 취소 반영이 완료되며, 취소 후 늦게 도착한 액션은 무시됩니다.

## Testing

**요약(KR)**: `TestStore`는 상태 전이와 effect 액션을 결정적으로 검증하며 timeout/cancellation 시나리오를 안정적으로 테스트합니다.

```swift
import Testing
import InnoFlowTesting

@Test
@MainActor
func userLoadFlow() async {
    let store = TestStore(
        reducer: UserFeature(userService: MockUserService()),
        initialState: .init()
    )

    await store.send(.load) {
        $0.isLoading = true
        $0.errorMessage = nil
    }

    await store.receive(._loaded(.success(.fixture))) {
        $0.user = .fixture
        $0.isLoading = false
    }

    await store.assertNoMoreActions()
}
```

## Binding Contract (`@BindableField` only)

`store.binding(_:send:)` only accepts:

```swift
KeyPath<State, BindableProperty<Value>>
```

That means non-bindable state fields cannot be connected to two-way binding by mistake.

**요약(KR)**: `@BindableField`가 아닌 상태 필드는 양방향 바인딩에서 컴파일 단계에서 차단됩니다.

## Navigation with InnoRouter

If you keep navigation state inside InnoFlow `State` (state-driven `NavigationStack(path:)`), use:

- `InnoRouterFlowBridge`: [GitHub](https://github.com/InnoSquad-mdd/InnoRouterFlowBridge)
- `InnoRouterFlowBridge v2 placeholder`: [v2-preview](https://github.com/InnoSquad-mdd/InnoRouterFlowBridge/tree/v2-preview)

Compatibility note:

- Architectural compatibility with InnoRouter is high.
- During v2 migration, `InnoRouterFlowBridge` v1 contract is intentionally breakable and should be updated in a dedicated v2 bridge release.

**요약(KR)**: 궁합은 높지만 v2 전환 중에는 Bridge v2 릴리스로 계약 정렬이 필요합니다.

## API Design Evaluation (External Framework Comparison Included)

Evaluation was performed using `ios-native-skills`:

- Comparison targets: `TCA`, `ReactorKit`, `ReSwift`, `SwiftRex`
- Weighted axes: API 25 / Effect 25 / Concurrency 15 / Testing 20 / SwiftUI 15
- Required gates: **SwiftUI philosophy**, **SOLID**

Current conclusion:

- InnoFlow v2 is aligned with ideal API-first direction
- SwiftUI/SOLID gates are conditionally passing
- InnoRouter compatibility is high, but bridge v2 alignment is required

**요약(KR)**: v2 방향은 유효하며, SwiftUI/SOLID는 조건부 통과 상태이고 Bridge v2 정렬이 후속 과제입니다.

Detailed docs:

- [API_DESIGN_EVALUATION.md](API_DESIGN_EVALUATION.md)
- [RELEASE_NOTES.md](RELEASE_NOTES.md)

## Documentation

- [DocC API Documentation](https://innosquad-mdd.github.io/InnoFlow/documentation/innoflow/)
- [Examples](Examples/)
- [Contributing Guide](CONTRIBUTING.md)

## License

MIT License. See [LICENSE](LICENSE).
