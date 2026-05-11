# InnoFlow

[English](./README.md) | 한국어 | [日本語](./README.jp.md) | [简体中文](./README.cn.md)

> 이 문서는 한국어 동반 문서입니다. 최신 기준 문서는 항상 [English README](./README.md)입니다.

InnoFlow는 비즈니스/도메인 상태 전환에 집중한 SwiftUI 우선 단방향 아키텍처 프레임워크입니다.

## 핵심 방향

- 공식 feature authoring은 `var body: some Reducer<State, Action>`입니다.
- 합성은 `Reduce`, `CombineReducers`, `Scope`, `IfLet`, `IfCaseLet`, `ForEachReducer`를 중심으로 이뤄집니다.
- `PhaseMap`은 phase-heavy feature의 canonical runtime phase-transition layer입니다.
- `PhaseTransitionGraph`는 generic automata runtime이 아니라 opt-in validation layer입니다.
- binding은 `@BindableField`와 projected key path를 통해 명시적으로 연결합니다.
- 앱 라우팅, transport, 세션 라이프사이클, 생성 시점 의존성 그래프는 앱 경계 바깥에서 소유합니다.

경계 문서:

- [Cross-Framework Boundaries](./docs/CROSS_FRAMEWORK.md)
- [Dependency Patterns](./docs/DEPENDENCY_PATTERNS.md)

## Why InnoFlow over TCA?

TCA는 dependency system, navigation pattern, test convention, 큰 생태계까지
포함한 폭넓은 application architecture가 필요할 때 더 강한 기본 선택지입니다.
InnoFlow는 더 작은 경계를 원할 때 선택합니다. reducer는 비즈니스 전환만
소유하고, dependency는 생성자 주입 bundle로 명시하며, navigation/transport는
앱 경계에 남기고, SwiftUI 전용 편의 API는 선택 product인 `InnoFlowSwiftUI`에
둡니다.

자세한 비교는 [Framework Comparison](./docs/FRAMEWORK_COMPARISON.md)을 봅니다.

## 설치

```swift
dependencies: [
  .package(url: "https://github.com/InnoSquadCorp/InnoFlow.git", from: "4.0.0")
]
```

```swift
.target(
  name: "YourDomain",
  dependencies: ["InnoFlow"]
)

.target(
  name: "YourSwiftUIApp",
  dependencies: ["InnoFlow", "InnoFlowSwiftUI"]
)

.testTarget(
  name: "YourAppTests",
  dependencies: ["InnoFlow", "InnoFlowTesting"]
)
```

non-UI feature/domain target은 `InnoFlow`만 의존하면 됩니다. SwiftUI app target은
`InnoFlowSwiftUI`를 함께 의존해 `Store.binding`, `ScopedStore.binding`,
`Store.preview`, `EffectTask.animation(Animation?)`를 사용합니다.

## 빠른 링크

- [English README](./README.md)
- [Architecture Contract](./ARCHITECTURE_CONTRACT.md)
- [Cross-Framework Boundaries](./docs/CROSS_FRAMEWORK.md)
- [Dependency Patterns](./docs/DEPENDENCY_PATTERNS.md)
- [Framework Comparison](./docs/FRAMEWORK_COMPARISON.md)
- [Phase-Driven Modeling](./PHASE_DRIVEN_MODELING.md)
- [Release Notes](./RELEASE_NOTES.md)
- [Canonical Sample README](./Examples/InnoFlowSampleApp/README.md)

## 빠른 시작

```swift
import InnoFlow

@InnoFlow
struct CounterFeature {
  struct State: Equatable, Sendable, DefaultInitializable {
    var count = 0
    @BindableField var step = 1
  }

  enum Action: Equatable, Sendable {
    case increment
    case decrement
    case setStep(Int)
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
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
}
```

SwiftUI에서는 projected key path를 사용해 명시적으로 binding을 연결합니다.
SwiftUI view target은 `import InnoFlowSwiftUI`를 추가합니다.

```swift
Stepper(
  "Step: \(store.step)",
  value: store.binding(\.$step, to: CounterFeature.Action.setStep)
)
```

`binding(_:to:)`는 `binding(_:send:)`의 argument-label alias입니다. 두 overload가 모두 있는 상태에서는 label을 생략하지 않는 것이 기준입니다.

## 합성 표면

- `Reduce`: 기본 reducer primitive
- `CombineReducers`: 선언 순서대로 reducer 결합
- `Scope`: 항상 존재하는 child state/action lift
- `IfLet`: optional child state
- `IfCaseLet`: enum-backed child state
- `ForEachReducer`: collection child state
- `SelectedStore`: 읽기 전용 파생 모델. 단일 명시적 key path는 `select(dependingOn:)`, 둘 이상의 key path는 가변 인자 `select(dependingOnAll:)`을 사용합니다. dependency를 선언할 수 없을 때 `select { ... }`는 always-refresh fallback입니다. dead projection은 `optionalValue`에서 `nil`이 되며, `requireAlive()`/dynamic member read는 release에서도 `preconditionFailure`로 실패합니다.

## 샘플 카탈로그

공식 샘플 앱은 10개 데모를 유지합니다.

- `sample.basics`
- `sample.orchestration`
- `sample.phase-driven-fsm`
- `sample.router-composition`
- `sample.authentication-flow`
- `sample.list-detail-pagination`
- `sample.offline-first`
- `sample.realtime-stream`
- `sample.form-validation`
- `sample.bidirectional-websocket`

`RouterCompositionDemo`는 navigation 경계, `BidirectionalWebSocketDemo`는 transport 경계, `AuthenticationFlowDemo`와 `OfflineFirstDemo`는 명시적 DI bundle 패턴의 기준 샘플입니다.

## 교차 프레임워크 메모

- reducer는 비즈니스 intent를 내보내고, 구체 route stack은 앱/코디네이터가 소유합니다.
- transport, reconnect, session lifecycle은 reducer 밖 adapter 경계에 둡니다.
- 생성 시점 dependency graph는 앱에서 만들고 reducer에는 `Dependencies` bundle만 전달합니다.
- 자세한 기준은 [Cross-Framework Boundaries](./docs/CROSS_FRAMEWORK.md), DI 세부 패턴은 [Dependency Patterns](./docs/DEPENDENCY_PATTERNS.md)를 봅니다.

## 문서 정책

- 영어 문서를 기준 문서로 유지합니다.
- 한국어/일본어/중국어 문서는 개요, 빠른 시작, 샘플 카탈로그, 경계 문서를 함께 제공합니다.
- 상세 authoring 가이드와 API 계약은 영어 문서를 먼저 갱신합니다.

## 언제 `PhaseMap`을 쓰면 좋은가

- `phase` enum이 이미 존재할 때
- legal transition이 feature contract의 일부일 때
- reducer 내부에 `state.phase = ...`가 여러 branch에 흩어져 있을 때

반대로 strict totality enforcement, optional metrics package 같은 항목은 현재 코어 요구사항이 아니라 조건부 roadmap입니다.
