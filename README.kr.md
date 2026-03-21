# InnoFlow

[English](./README.md) | 한국어 | [日本語](./README.jp.md) | [简体中文](./README.cn.md)

> 이 문서는 한국어 진입 문서입니다. 최신 기준 문서는 항상 [English README](./README.md)입니다.

InnoFlow는 비즈니스/도메인 상태 전환에 집중한 SwiftUI 우선 단방향 아키텍처 프레임워크입니다.

## 핵심 방향

- 공식 feature authoring은 `var body: some Reducer<State, Action>`입니다.
- 합성은 `Reduce`, `CombineReducers`, `Scope`, `IfLet`, `IfCaseLet`, `ForEachReducer`를 중심으로 이뤄집니다.
- `PhaseMap`은 phase-heavy feature의 canonical runtime phase-transition layer입니다.
- `PhaseTransitionGraph`는 generic automata runtime이 아니라 opt-in validation layer입니다.
- binding은 `@BindableField`와 projected key path를 통해 명시적으로 연결합니다.
- 앱 라우팅, transport, 세션 라이프사이클, 생성 시점 의존성 그래프는 앱 경계 바깥에서 소유합니다.

## 설치

```swift
dependencies: [
  .package(url: "https://github.com/InnoSquadCorp/InnoFlow.git", from: "3.0.2")
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

## 빠른 링크

- [English README](./README.md)
- [Architecture Contract](./ARCHITECTURE_CONTRACT.md)
- [Phase-Driven Modeling](./PHASE_DRIVEN_MODELING.md)
- [Release Notes](./RELEASE_NOTES.md)
- [Framework Evaluation](./FRAMEWORK_EVALUATION.md)
- [Canonical Sample README](./Examples/InnoFlowSampleApp/README.md)

## 문서 정책

- 영어 문서를 기준 문서로 유지합니다.
- 한국어/일본어/중국어 문서는 빠른 진입과 개요 제공에 집중합니다.
- 상세 authoring 가이드와 API 계약은 영어 문서를 먼저 갱신합니다.

## 언제 `PhaseMap`을 쓰면 좋은가

- `phase` enum이 이미 존재할 때
- legal transition이 feature contract의 일부일 때
- reducer 내부에 `state.phase = ...`가 여러 branch에 흩어져 있을 때

반대로 strict totality enforcement, `SelectedStore` 4+ dependency 최적화, optional metrics package 같은 항목은 현재 코어 요구사항이 아니라 조건부 roadmap입니다.
