# InnoFlow 3.0.0 평가 요약

[English](./FRAMEWORK_EVALUATION.md) | 한국어 | [日本語](./FRAMEWORK_EVALUATION.jp.md) | [简体中文](./FRAMEWORK_EVALUATION.cn.md)

> 이 문서는 한국어 진입 문서입니다. 최신 기준 평가는 항상 [English evaluation](./FRAMEWORK_EVALUATION.md)입니다.

## 한눈에 보기

- 현재 평가 점수는 **9.20 / 10**
- 등급은 **Production Ready+**
- 핵심 결론은 “코어 구조는 닫혔고, 남은 건 조건부 backlog와 ecosystem polish”입니다.

## 강점

- `PhaseMap`이 canonical phase-transition layer로 정착했습니다.
- `PhaseTransitionGraph`는 topology validator로 역할이 분리돼 있습니다.
- `Store`, `EffectRuntime`, `SelectedStore`, `ScopedStore`의 책임 경계가 분명합니다.
- principle gates, ADR, UI smoke tests, visionOS build까지 포함한 계약 기반 검증이 있습니다.

## 남은 과제

- `SelectedStore` 4+ dependency / opaque selector 최적화
- 공식 `swift-metrics` adapter 여부
- dedicated immersive/spatial sample
- `PhaseMap` authoring polish

## 빠른 링크

- [Full English evaluation](./FRAMEWORK_EVALUATION.md)
- [README](./README.md)
- [Architecture Contract](./ARCHITECTURE_CONTRACT.md)
- [Phase-Driven Modeling](./PHASE_DRIVEN_MODELING.md)
- [Release Notes](./RELEASE_NOTES.md)

## 문서 정책

- 영어 평가 문서를 기준 문서로 유지합니다.
- 한국어/일본어/중국어 문서는 빠른 요약과 진입 문서 역할에 집중합니다.
- 점수, 세부 근거, backlog 기준은 영어 문서를 먼저 갱신합니다.
