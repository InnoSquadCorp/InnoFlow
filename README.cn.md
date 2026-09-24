# InnoFlow

[English](./README.md) | [한국어](./README.kr.md) | [日本語](./README.jp.md) | 简体中文

> 这是一份中文 companion 文档。始终以 [English README](./README.md) 作为最新、最权威的版本。

InnoFlow 是一个面向业务/领域状态转换的 SwiftUI-first 单向架构框架。

本文及下方安装示例描述 6.0.0 候选版本的 API 契约。候选版本冻结时的公开稳定基线为 5.1.1；
6.0.0 标签和 GitHub Release 是否已公开，需在 GitHub 上另行确认。

## 核心方向

- 官方 feature authoring 会显式声明第三个 reducer generic：没有 app-boundary
  output 时使用 `Never`，需要发出 output 时使用 feature 的 typed `Output`。
- 对于不符合标准合成形式的 labeled/multi-payload `Action` case，应通过 canonical
  `<caseName>CasePath` 手动声明或 `@InnoFlowCasePathIgnored` 明确表达警告处理意图。
- 组合以 `Reduce`、`CombineReducers`、`Scope`、`IfLet`、`IfCaseLet`、`ForEachReducer` 为核心。
- `PhaseMap` 是 phase-heavy feature 的 canonical runtime phase-transition layer。
- `PhaseTransitionGraph` 不是 generic automata runtime，而是 opt-in validation layer。
- binding 通过 `@BindableField` 和 projected key path 显式连接。
- `TestStore.exhaustivity` 默认为 `.on`，会完整验证所有状态转换和 effect action。测试应以 `finish()` 结束；若 deinit 时仍有未验证工作，则会按策略记录失败、警告或保持静默。若执行取消尚未先被接受，`EffectTask.run` 中除取消以外的未处理错误不受该策略影响，并会在原始 action assertion 位置记录一次失败。
- `Store.send(_:)` 返回 `FlowTask`，可只等待或取消由该次 dispatch 派生的完整 effect tree。
- reducer 可通过 typed `Output` 发出一次性的 app-boundary command；需要恢复或渲染的值仍应放在 `State` 中。
- 当需要关联到特定 dispatch 的 output 时，`send(_:capturingOutputs:)` 会在
  enqueue 前建立 single-consumer `OutputFlowTask` 流，并与全局
  `outputs()` broadcast 分离。
- 取消等待 captured output 的 consumer Task 只会取消对应的 dispatch。
  正常结束或取消 broadcast 订阅不会停止 effect。若保留 capture 并通过 `break`
  提前退出，需显式调用 `cancel()` 来停止工作。
- 无 output 的子 reducer 和 effect helper 可通过 `promoteOutput(to:)` 复用。
  实际的 output 类型仍须使用 `mapOutput(_:)` 显式转换，不能静默丢弃事件。
- `TestStore.receiveOutput` 也支持 predicate 和 `CasePath`，可以验证非 `Equatable` output。
  所有形式都遵守 exhaustivity 策略和总 timeout。
- `strictPhaseTotality: true` 会把直接声明的 `Phase` source/target 缺失变为
  编译错误；动态 trigger 语义仍通过 `requireComplete(...)` 验证。
- `Store` 会在 MainActor 边界上对 effect 取消与 run failure 进行排序。若取消先被接受，非协作任务随后抛出的错误不会再被归类为 `didFailRun`。
- 路由、transport、session lifecycle、构建期依赖图由应用边界之外负责。

边界文档：

- [Cross-Framework Boundaries](./docs/CROSS_FRAMEWORK.md)
- [Dependency Patterns](./docs/DEPENDENCY_PATTERNS.md)

## Why InnoFlow over TCA?

当团队需要包含 dependency system、navigation pattern、testing convention 和大型
ecosystem 的完整 application architecture 时，TCA 仍然是更强的默认选择。InnoFlow
适合希望保持更小框架边界的项目：reducer 只负责业务转换，dependency 通过构造期
bundle 显式传入，navigation/transport 留在 app boundary，SwiftUI 专用便捷 API
放在可选 product `InnoFlowSwiftUI` 中。

更完整的比较见 [Framework Comparison](./docs/FRAMEWORK_COMPARISON.md)。

## 安装

```swift
dependencies: [
  .package(url: "https://github.com/InnoSquadCorp/InnoFlow.git", from: "6.0.0")
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

runtime-only non-UI feature/domain target 可以只依赖 `InnoFlowCore`。使用
`@InnoFlow` macro 的 target 必须直接依赖 `InnoFlow`。SwiftUI app target 还需要依赖
`InnoFlowSwiftUI`，以使用 `Store.binding`、`ScopedStore.binding`、`Store.preview`
和 `EffectTask.animation(Animation?)`。
compiler-plugin trust、SwiftSyntax prebuilt fallback、CI flag 与 `InnoFlowCore`
恢复路径请参阅 [`Macro Operations`](./docs/MACRO_OPERATIONS.md)。

## 关键链接

- [English README](./README.md)
- [Architecture Contract](./ARCHITECTURE_CONTRACT.md)
- [Cross-Framework Boundaries](./docs/CROSS_FRAMEWORK.md)
- [Dependency Patterns](./docs/DEPENDENCY_PATTERNS.md)
- [Macro Operations](./docs/MACRO_OPERATIONS.md)
- [Support](./SUPPORT.md)
- [Governance](./GOVERNANCE.md)
- [Contributing](./CONTRIBUTING.md)
- [Security](./SECURITY.md)
- [Framework Comparison](./docs/FRAMEWORK_COMPARISON.md)
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

  var body: some Reducer<State, Action, Never> {
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
SwiftUI view target 需要添加 `import InnoFlowSwiftUI`。

```swift
Stepper(
  "Step: \(store.step)",
  value: store.binding(\.$step, to: CounterFeature.Action.setStep)
)
```

`binding(_:to:)` 是规范（canonical）写法。`binding(_:send:)` 与 trailing-closure 写法是语义完全相同的兼容写法，保留且不会弃用；新代码请使用 `to:`。

## 组合表面

- `Reduce`: 基础 reducer primitive
- `CombineReducers`: 按声明顺序组合 reducer
- `Scope`: 始终存在的 child state/action 提升
- `IfLet`: optional child state
- `IfCaseLet`: enum-backed child state
- `ForEachReducer`: collection child state
- `SelectedStore`: 只读派生模型。单个显式 key path 使用 `select(dependingOn:)`，两个或更多使用可变参数的 `select(dependingOnAll:)`；无法声明 dependency 时，`select { ... }` 是 always-refresh fallback。dynamic member read 为 SwiftUI observer race 在 debug 中给出诊断，并在 release 中返回最后的 snapshot。非 UI 代码应通过 `optionalValue` 的 `nil` 处理 dead projection，或使用在所有构建中都严格失败的 `requireAlive()`。

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

## 6.0 执行编排与验证

当不同 dispatch 竞争同一个 Store-local resource 时，可使用 `.latest`、
`.dropWhileRunning` 与 bounded `.serial(maxPending:)`。多个 dispatch 的生命周期
由 `withFlowScope` 管理；生产诊断使用 opt-in、bounded、payload-free 的
`StoreDiagnostics`。测试可使用 `TestStoreInvariant`、`TestStoreScenario` 以及
macro 合成的 Output case path。这些能力不替代持久化 transaction、retry 或 rollback。

## 什么时候使用 `PhaseMap`

- 已经有 `phase` enum
- legal transition 是 feature contract 的一部分
- reducer 中有多处分散的 `state.phase = ...`

strict totality enforcement、optional metrics package 等目前都属于条件触发的 roadmap 项目，而不是当前的核心必做项。
