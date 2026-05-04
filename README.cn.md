# InnoFlow

[English](./README.md) | [한국어](./README.kr.md) | [日本語](./README.jp.md) | 简体中文

> 这是一份中文 companion 文档。始终以 [English README](./README.md) 作为最新、最权威的版本。

InnoFlow 是一个面向业务/领域状态转换的 SwiftUI-first 单向架构框架。

## 核心方向

- 官方 feature authoring 方式是 `var body: some Reducer<State, Action>`。
- 组合以 `Reduce`、`CombineReducers`、`Scope`、`IfLet`、`IfCaseLet`、`ForEachReducer` 为核心。
- `PhaseMap` 是 phase-heavy feature 的 canonical runtime phase-transition layer。
- `PhaseTransitionGraph` 不是 generic automata runtime，而是 opt-in validation layer。
- binding 通过 `@BindableField` 和 projected key path 显式连接。
- 路由、transport、session lifecycle、构建期依赖图由应用边界之外负责。

边界文档：

- [Cross-Framework Boundaries](./docs/CROSS_FRAMEWORK.md)
- [Dependency Patterns](./docs/DEPENDENCY_PATTERNS.md)

## 安装

```swift
dependencies: [
  .package(url: "https://github.com/InnoSquadCorp/InnoFlow.git", from: "4.0.0")
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
- [Cross-Framework Boundaries](./docs/CROSS_FRAMEWORK.md)
- [Dependency Patterns](./docs/DEPENDENCY_PATTERNS.md)
- [Phase-Driven Modeling](./PHASE_DRIVEN_MODELING.md)
- [Release Notes](./RELEASE_NOTES.md)
- [Canonical Sample README](./Examples/InnoFlowSampleApp/README.md)

## 快速开始

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

在 SwiftUI 中，用 projected key path 显式连接 binding。

```swift
Stepper(
  "Step: \(store.step)",
  value: store.binding(\.$step, to: CounterFeature.Action.setStep)
)
```

`binding(_:to:)` 是 `binding(_:send:)` 的参数标签别名。既然两个 overload 都存在，就不要省略 label。

## 组合表面

- `Reduce`: 基础 reducer primitive
- `CombineReducers`: 按声明顺序组合 reducer
- `Scope`: 始终存在的 child state/action 提升
- `IfLet`: optional child state
- `IfCaseLet`: enum-backed child state
- `ForEachReducer`: collection child state
- `SelectedStore`: 只读派生模型。单个显式 key path 使用 `select(dependingOn:)`，两个或更多使用可变参数的 `select(dependingOnAll:)`；无法声明 dependency 时，`select { ... }` 是 always-refresh fallback

## 样例目录

官方样例应用维护 10 个 demo。

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

`RouterCompositionDemo` 是 navigation 边界示例，`BidirectionalWebSocketDemo` 是 transport 边界示例，`AuthenticationFlowDemo` 与 `OfflineFirstDemo` 是显式 DI bundle 模式的基准样例。

## Cross-framework 说明

- reducer 发出业务 intent，具体 route stack 由 app/coordinator 持有。
- transport、reconnect、session lifecycle 放在 reducer 之外的 adapter 边界。
- 构建期 dependency graph 在 app 层创建，只把 `Dependencies` bundle 传进 reducer。
- 边界总览见 [Cross-Framework Boundaries](./docs/CROSS_FRAMEWORK.md)，DI 细节见 [Dependency Patterns](./docs/DEPENDENCY_PATTERNS.md)。

## 文档策略

- 英文文档作为 canonical source of truth。
- 中文/韩文/日文文档同时覆盖概览、quick start、sample catalog 与 boundary docs 导航。
- 更详细的 authoring guidance 与 API 合同，优先在英文文档中更新。

## 什么时候使用 `PhaseMap`

- 已经有 `phase` enum
- legal transition 是 feature contract 的一部分
- reducer 中有多处分散的 `state.phase = ...`

strict totality enforcement、optional metrics package 等目前都属于条件触发的 roadmap 项目，而不是当前的核心必做项。
