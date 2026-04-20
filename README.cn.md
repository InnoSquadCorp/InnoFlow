# InnoFlow

[English](./README.md) | [한국어](./README.kr.md) | [日本語](./README.jp.md) | 简体中文

> 这是一份中文入口文档。始终以 [English README](./README.md) 作为最新、最权威的版本。

InnoFlow 是一个面向业务/领域状态转换的 SwiftUI-first 单向架构框架。

## 核心方向

- 官方 feature authoring 方式是 `var body: some Reducer<State, Action>`。
- 组合以 `Reduce`、`CombineReducers`、`Scope`、`IfLet`、`IfCaseLet`、`ForEachReducer` 为核心。
- `PhaseMap` 是 phase-heavy feature 的 canonical runtime phase-transition layer。
- `PhaseTransitionGraph` 不是 generic automata runtime，而是 opt-in validation layer。
- binding 通过 `@BindableField` 和 projected key path 显式连接。
- 路由、transport、session lifecycle、构建期依赖图由应用边界之外负责。

## 安装

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

## 关键链接

- [English README](./README.md)
- [Architecture Contract](./ARCHITECTURE_CONTRACT.md)
- [Dependency Patterns](./docs/DEPENDENCY_PATTERNS.md)
- [Phase-Driven Modeling](./PHASE_DRIVEN_MODELING.md)
- [Release Notes](./RELEASE_NOTES.md)
- [Framework Evaluation](./FRAMEWORK_EVALUATION.md)
- [Canonical Sample README](./Examples/InnoFlowSampleApp/README.md)

## 文档策略

- 英文文档作为 canonical source of truth。
- 中文/韩文/日文文档主要承担入口说明和快速概览的角色。
- 更详细的 authoring guidance 与 API 合同，优先在英文文档中更新。

## 什么时候使用 `PhaseMap`

- 已经有 `phase` enum
- legal transition 是 feature contract 的一部分
- reducer 中有多处分散的 `state.phase = ...`

strict totality enforcement、`SelectedStore` 的 4+ dependency 优化、optional metrics package 等目前都属于条件触发的 roadmap 项目，而不是当前的核心必做项。
