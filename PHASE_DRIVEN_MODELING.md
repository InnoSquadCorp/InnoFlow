# Phase-Driven Modeling in InnoFlow

`InnoFlow`에서 상태머신을 도입할 때의 권장 방식은 **범용 오토마타 런타임**이 아니라
**feature-level phase graph** 입니다.

핵심 원칙:
- 비즈니스/도메인 전이는 `InnoFlow`가 소유한다.
- 네비게이션 전이는 `InnoRouter`가 소유한다.
- transport/session lifecycle은 `InnoNetwork`가 소유한다.
- DI lifecycle은 `InnoDI`의 정적 스코프/그래프 검증으로 유지한다.

## 언제 쓰는가

다음처럼 feature 상태가 명확한 단계로 나뉠 때 적합합니다.
- `idle -> loading -> loaded`
- `draft -> validating -> submitting -> submitted`
- `unauthenticated -> authenticating -> authenticated`

반대로 단순 CRUD나 계산성 state만 있는 feature에는 굳이 도입할 필요가 없습니다.

## 기본 패턴

```swift
import InnoFlow

@InnoFlow
struct ProfileFeature {
    enum Phase: Hashable, Sendable {
        case idle
        case loading
        case loaded
        case failed
    }

    struct State: Equatable, Sendable, DefaultInitializable {
        var phase: Phase = .idle
        var profile: UserProfile?
    }

    enum Action: Sendable {
        case load
        case _loaded(UserProfile)
        case _failed
    }

    static let phaseGraph: PhaseTransitionGraph<Phase> = [
        .idle: [.loading],
        .loading: [.loaded, .failed],
        .failed: [.loading],
    ]

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
        switch action {
        case .load:
            state.phase = .loading
            return .none
        case ._loaded(let profile):
            state.phase = .loaded
            state.profile = profile
            return .none
        case ._failed:
            state.phase = .failed
            return .none
        }
    }
}
```

## 테스트 패턴

`InnoFlowTesting`의 `TestStore` helper를 쓰면 reducer action이 phase graph를 따르는지 검증할 수 있습니다.

```swift
import InnoFlowTesting

let store = TestStore(reducer: ProfileFeature())

await store.send(.load, tracking: \.phase, through: ProfileFeature.phaseGraph) {
    $0.phase = .loading
}
```

이 helper는 illegal transition이 생기면 일반 state mismatch와 별도로 실패를 기록합니다.

## 설계 기준

- phase는 `enum`으로 유지한다.
- graph는 `static let`로 feature 내부에 둔다.
- guard, stack, non-deterministic automata까지 일반화하지 않는다.
- 복잡한 전이 orchestration은 reducer/action/effect로 풀고, graph는 **허용 전이 문서 + 검증** 용도로 쓴다.

## 하지 말아야 할 것

- `InnoFlow`를 범용 DFA/NFA/PDA 엔진으로 확장하기
- `InnoRouter`의 navigation phase를 `InnoFlow` phase와 중복 모델링하기
- `InnoNetwork` retry/reconnect lifecycle을 비즈니스 phase graph에 다시 복제하기

요약하면, `InnoFlow`의 phase-driven FSM은 **도메인 전이를 더 명시적으로 만들기 위한 얇은 레이어**여야 합니다.
