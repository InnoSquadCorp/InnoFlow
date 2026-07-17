# InnoFlow

[English](./README.md) | 한국어 | [日本語](./README.jp.md) | [简体中文](./README.cn.md)

> 이 문서는 한국어 동반 문서입니다. 최신 기준 문서는 항상 [English README](./README.md)입니다.

InnoFlow는 비즈니스/도메인 상태 전환에 집중한 SwiftUI 우선 단방향 아키텍처 프레임워크입니다.

`main` 문서는 5.0 개발 계약을 설명하며, 아래 설치 예시는 최신 안정 릴리스인 4.0.0을 유지합니다.

## 핵심 방향

- 공식 feature authoring은 `var body: some Reducer<State, Action>`입니다.
- 합성은 `Reduce`, `CombineReducers`, `Scope`, `IfLet`, `IfCaseLet`, `ForEachReducer`를 중심으로 이뤄집니다.
- `PhaseMap`은 phase-heavy feature의 canonical runtime phase-transition layer입니다.
- `PhaseTransitionGraph`는 generic automata runtime이 아니라 opt-in validation layer입니다.
- binding은 `@BindableField`와 projected key path를 통해 명시적으로 연결합니다.
- `TestStore.exhaustivity`는 기본값이 `.on`이며, 모든 상태 전환과 effect action을 빠짐없이 검증합니다. 테스트는 `finish()`로 끝내며, 미검증 작업을 남긴 deinit은 정책에 따라 실패, 경고 또는 무음으로 처리됩니다. 실행 취소가 먼저 수락되지 않은 상태에서 `EffectTask.run`을 빠져나온 취소 이외의 오류는 이 정책과 무관하게 원래 action assertion 위치에서 한 번 실패합니다.
- `Store`는 effect 취소와 run 실패를 MainActor 경계에서 순서화합니다. 취소가 먼저 수락되면 협조하지 않는 작업이 뒤늦게 던진 오류를 `didFailRun`으로 재분류하지 않습니다.
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
  dependencies: ["InnoFlowCore"]
)

.target(
  name: "YourSwiftUIApp",
  dependencies: ["InnoFlow", "InnoFlowSwiftUI"]
)

.testTarget(
  name: "YourAppTests",
  dependencies: ["InnoFlowCore", "InnoFlowTesting"]
)
```

runtime-only non-UI feature/domain target은 `InnoFlowCore`만 의존하면 됩니다.
`@InnoFlow` macro를 사용하는 target은 `InnoFlow`를 직접 의존해야 합니다. SwiftUI
app target은 `InnoFlowSwiftUI`를 함께 의존해 `Store.binding`,
`ScopedStore.binding`, `Store.preview`, `EffectTask.animation(Animation?)`를 사용합니다.
compiler-plugin trust, SwiftSyntax prebuilt fallback, CI flag, `InnoFlowCore`
복구 경로는 [`Macro Operations`](./docs/MACRO_OPERATIONS.md)를 참고하세요.

## 빠른 링크

- [English README](./README.md)
- [Architecture Contract](./ARCHITECTURE_CONTRACT.md)
- [Cross-Framework Boundaries](./docs/CROSS_FRAMEWORK.md)
- [Dependency Patterns](./docs/DEPENDENCY_PATTERNS.md)
- [Framework Comparison](./docs/FRAMEWORK_COMPARISON.md)
- [Macro Operations](./docs/MACRO_OPERATIONS.md)
- [Support](./SUPPORT.md)
- [Governance](./GOVERNANCE.md)
- [Contributing](./CONTRIBUTING.md)
- [Security](./SECURITY.md)
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
- `SelectedStore`: 읽기 전용 파생 모델. 단일 명시적 key path는 `select(dependingOn:)`, 둘 이상의 key path는 가변 인자 `select(dependingOnAll:)`을 사용합니다. dependency를 선언할 수 없을 때 `select { ... }`는 always-refresh fallback입니다. dynamic member read는 SwiftUI observer race를 위해 debug에서 진단하고 release에서 마지막 snapshot을 반환합니다. 비 UI 코드는 dead projection을 `optionalValue`의 `nil`로 처리하거나, 모든 빌드에서 엄격한 `requireAlive()`를 사용합니다.

런타임 `Store.scope(state:action:)`는 같은 호출 위치, state key path,
child 타입, `CasePath` identity가 모두 일치할 때 살아 있는 `ScopedStore`를
재사용합니다. 부모 `Store`는 이 projection을 약하게 보유하므로 수명을
연장하지 않으며, 명시적으로 새로 생성한 `CasePath`는 이전 action transform을
재사용하지 않고 안전하게 새 projection을 만듭니다. generic이나 extension 문맥에서
computed static accessor가 필요한 경우에도 매크로가 생성한 path identity는 안정적으로
유지됩니다. 이 계약은 reducer 합성 primitive인 `Scope`나 테스트용
`TestStore.scope`의 identity 계약이 아닙니다.

런타임 `Store.scope(collection:action:)`는 collection key path마다 하나의 활성
row family만 보유합니다. child 타입과 `CollectionActionPath` identity가 일치하면
호출 위치가 달라도 ID별 `ScopedStore`를 재사용하고, signature가 달라지면 family
전체를 교체합니다. 이전에 반환된 row는 기존 action transform을 유지하고 새로
scope한 row는 새 path로 라우팅됩니다. 매크로가 생성한 path는 반복 접근해도 row
객체 identity를 유지하며, path를 명시적으로 재생성하면 의도적인 안전한 교체로
취급됩니다.

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
