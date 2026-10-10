# InnoFlow

[![Release](https://img.shields.io/github/v/release/InnoSquadCorp/InnoFlow)](https://github.com/InnoSquadCorp/InnoFlow/releases) [![License](https://img.shields.io/github/license/InnoSquadCorp/InnoFlow)](LICENSE) [Swift Package Index](https://swiftpackageindex.com/InnoSquadCorp/InnoFlow) · [CI and public operations](docs/automation-policy.md)

[English](README.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Deutsch](README.de.md) | [简体中文](README.zh-Hans.md) | [日本語](README.ja.md) | [Русский](README.ru.md)

以 SwiftUI 为中心的单向状态管理框架，负责业务与领域状态转换。先使用 reducer、Store 和确定性测试，再按功能需求添加编排。

## InnoFlow 6.0.2

本 README 描述 **已发布的 6.0.2 API**，发布于 **2026-10-08**，提交为 `1176de1e4783b638c03a9334f43cc49378957148`。[版本源码](https://github.com/InnoSquadCorp/InnoFlow/tree/6.0.2) · [发布说明](RELEASE_NOTES.md) · [迁移](MIGRATION.md)。

开发分支包含后续 CI、测试组织、验证工具和文档变更。本次更新时 `Sources/` 与 6.0.2 一致；后续工具变更尚未发布。开发分支的 `STABLE_VERSION` 为 6.0.2，不可变标签保留当时的候选元数据。托管 DocC 跟随部署版本；确认已安装版本时请查看标签源码。七份 README 提供相同的入门内容，详细指南使用英语。

## 安装

要求 Swift **6.3+**、Swift **6 语言模式**；最低平台为 iOS **18+**、macOS **15+**、tvOS **18+**、watchOS **11+**、visionOS **2+**。SwiftSyntax 范围为 `>=603.0.0, <605.0.0`，仓库锁文件使用 604.0.0。请选用匹配目标的 Xcode/SDK。声明的部署下限不代表所有旧运行时均已执行验证。

添加包后明确选择产品。`from:` 允许后续兼容版本，请检查实际 `Package.resolved`。复现本次发布时使用 `exact: "6.0.2"`。

```swift
dependencies: [
  .package(url: "https://github.com/InnoSquadCorp/InnoFlow.git", from: "6.0.2")
]
```

```swift
.target(
  name: "YourDomain",
  dependencies: [.product(name: "InnoFlowCore", package: "InnoFlow")]
),
.target(
  name: "YourSwiftUIApp",
  dependencies: [
    .product(name: "InnoFlow", package: "InnoFlow"),
    .product(name: "InnoFlowSwiftUI", package: "InnoFlow")
  ]
),
.testTarget(
  name: "YourAppTests",
  dependencies: [
    .product(name: "InnoFlowCore", package: "InnoFlow"),
    .product(name: "InnoFlowTesting", package: "InnoFlow")
  ]
)
```

| 产品 | 用途 |
| --- | --- |
| `InnoFlowCore` | 无插件运行时及有意保留的恢复路径，不依赖 SwiftUI。 |
| `InnoFlow` | 宏编写入口，重新导出 Core；使用 `@InnoFlow` 时须直接 import。 |
| `InnoFlowSwiftUI` | 可选的绑定、预览、呈现和视图任务辅助工具，重新导出 Core。 |
| `InnoFlowInspector` | 可选诊断 UI，仅依赖 Core；建议在 DEBUG 下接入。 |
| `InnoFlowTesting` | 测试专用 harness 和手动时钟，重新导出 Core；勿加入交付目标。 |


## 计数器功能

宏用户声明嵌套的 `State`、`Action` 和 `body`。无输出时第三个 reducer 泛型为 `Never`，否则为类型化 `Output`。通过 `Reduce`、`CombineReducers`、`Scope`、`IfLet`、`IfCaseLet`、`ForEachReducer` 和 `ForEachIdentifiedReducer` 组合。宏生成 `reduce`，普通公开功能不应手写该方法。

无标签的单个子 payload 生成 `<caseName>CasePath`，集合 `id:action:` 生成 `CollectionActionPath`。不受支持的有标签或多 payload Action 应在 `Action` 内声明规范静态路径；无需路径或路径位于 extension 时使用 `@InnoFlowCasePathIgnored`。

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

将两个声明放入应用目标。`@BindableField` 与 `store.binding(\.$step, to:)` 是规范写法。`send:` 和尾随闭包绑定仍受支持且未弃用。`BindableProperty` 是底层存储类型。在视图层解析 `@Environment`，并向功能注入依赖。

```swift
import InnoFlow
import InnoFlowSwiftUI
import SwiftUI

struct CounterView: View {
  @State private var store: Store<CounterFeature>

  init(store: Store<CounterFeature> = Store(reducer: CounterFeature())) {
    _store = State(initialValue: store)
  }

  var body: some View {
    VStack(spacing: 20) {
      Text("Count: \(store.count)")
        .font(.largeTitle)

      HStack(spacing: 24) {
        Button("−") { store.send(.decrement) }
        Button("+") { store.send(.increment) }
      }

      Stepper(
        "Step: \(store.step)",
        value: store.binding(\.$step, to: CounterFeature.Action.setStep)
      )
    }
  }
}
```

## 测试

`TestStore.exhaustivity` 默认为 `.on`：断言所有状态变更，接收全部 effect action 和类型化输出，最后调用 `await store.finish()`。省略断言闭包表示状态不变。`.off` 仅用于有意的部分测试；运行时 effect 错误仍会导致失败。`assertNoBufferedActions()` 用于中途队列检查；`assertNoMoreActions()` 已在 6.0 删除。

下面的计数器与测试绑定到可执行文档 harness；安装片段会组装为 manifest 并解析。所有译文共享相同代码。[完整指南](docs/USER_GUIDE.md) 区分依赖上下文的示例和完整代码，[代码块记录](docs/contracts/doc-swift-fence-review.tsv) 记录检查器绑定。通过这些检查不能证明设备 UI 行为。

使用 `receive(...)` 接收 effect action，使用 `receiveOutput(...)` 接收输出。

上面的 manifest 展示产品选择。为应用测试此计数器时，还需将应用 target 加入测试依赖，并使用 `@testable import YourSwiftUIApp` 访问 `CounterFeature`。文档 harness 在同一测试 target 中一起编译功能和测试。

```swift
import InnoFlowTesting
import Testing

@Test
@MainActor
func readmeCounter() async {
  let store = TestStore(reducer: CounterFeature())
  await store.send(.setStep(2)) { $0.step = 2 }
  await store.send(.increment) { $0.count = 2 }
  await store.send(.decrement) { $0.count = 0 }
  await store.finish()
}
```

## 逐步采用功能

- **Level 1：** `Reduce`、`Store`、`@BindableField`、`TestStore`；计数器或表单无需 phase graph 或 run lane。
- **Level 2：** 子功能组合、标识集合、`SelectedStore` 与类型化临时 `Output`。通过 `mapOutput(_:)` 明确映射；`promoteOutput(to:)` 仅用于 `Never`。`outputs()` 是实时且不回放的流，应先订阅再 dispatch，或使用 `send(_:capturingOutputs:)` 及明确缓冲策略进行原子单消费者捕获。
- **Level 3：** `FlowTask`、`withFlowScope`、可选子状态生命周期、执行准入、`PhaseMap`、诊断和 Inspector。`.latest`、`.dropWhileRunning` 与有界 `.serial(maxPending:)` 管理 Store 内准入，需处理拒绝。串行执行不保证事务、重试、回滚或恰好一次交付。

单个状态片段用 `select(dependingOn:)`，多个片段用 `select(dependingOnAll:)`，普通闭包是 always-refresh fallback。`select(memoize: true)` 仅在整个 Equatable 父快照不变时跳过刷新，不推断闭包的细粒度依赖。复用存活闭包投影时，语义 `id` 须包含捕获输入。过期投影使用 `optionalState` / `optionalValue`，严格前置条件使用 `requireAlive()`。

`@InnoFlow(phaseManaged: true)` 在 reduction 后应用 `PhaseMap` 并拥有 phase 键路径。默认允许不匹配的 phase/action 对不做任何操作。`strictPhaseTotality: true` 检查直接 phase 声明；`requireComplete(...)` 验证声明的样本触发器，而非任意谓词或完整 payload 域。`PhaseTransitionGraph` 只验证拓扑，不负责导航或传输。

## 所有权与生命周期

Reducer 拥有领域状态；应用/coordinator 拥有具体导航栈、传输/会话生命周期及依赖图构建。请明确注入 Sendable 依赖 bundle。Flow 不提供 DI 容器、网络客户端或路由器。参见 [依赖模式](docs/DEPENDENCY_PATTERNS.md) 与 [框架边界](docs/CROSS_FRAMEWORK.md)。

`Store.send(_:)` 返回该 dispatch 及其后代的 `FlowTask`。`finish()` 等待完成；`cancel()` 只取消该树，不回滚已处理的状态。丢弃 handle 不等于取消。`withFlowScope` 仅拥有已跟踪的 dispatch。Effect 取消是协作式的，应使用 `EffectContext` 与注入时钟；`ManualTestClock` 支持确定性时间测试。

SwiftUI 辅助工具覆盖 sheet、navigation destination、alert、confirmation dialog 及受支持平台的 popover；macOS 不支持 full-screen cover。`innoFlowTask` 将 dispatch 与视图消失或 ID 变化绑定。Inspector 与 `StoreDiagnostics` 是可选、有界且不含 payload 的；不要向诊断标签加入领域 payload。渲染、导航、空间窗口和 immersive 编排仍由应用负责。

## 官方示例

[官方示例](Examples/InnoFlowSampleApp/README.md) 包含十个演示，通过本地路径使用当前 checkout。交互式应用外壳以 iOS 为主；其他平台编译不代表提供 immersive 示例或完整 UI 等价性。[设置](Examples/SETUP_GUIDE.md)。

使用系统控件、Dynamic Type、VoiceOver 标签及稳定的 `accessibilityIdentifier`。Smoke 测试覆盖以下标识符，但并非完整无障碍审计：

`sample.basics`, `sample.orchestration`, `sample.phase-driven-fsm`, `sample.router-composition`, `sample.authentication-flow`, `sample.list-detail-pagination`, `sample.offline-first`, `sample.realtime-stream`, `sample.form-validation`, `sample.bidirectional-websocket`.

## 文档与选择 Flow

- [详细用户指南](docs/USER_GUIDE.md)、[文档索引与版本边界](docs/DOCUMENTATION.md)
- [入门与 API](https://innosquadcorp.github.io/InnoFlow/documentation/innoflow/)、[测试 API](https://innosquadcorp.github.io/InnoFlow/testing/documentation/innoflowtesting/)
- [Phase 建模](PHASE_DRIVEN_MODELING.md)、[SwiftUI 平台限制](docs/SWIFTUI_DX_6_0.md)、[监测](docs/INSTRUMENTATION_COOKBOOK.md)
- [架构契约](ARCHITECTURE_CONTRACT.md)、[迁移](MIGRATION.md)、[宏信任与恢复](docs/MACRO_OPERATIONS.md)
- [AI skill](skills/README.md)：精确的 6.0.2 消费者基线；SwiftPM 与 AI skill 安装分别进行。

当较小的领域状态边界及构造器依赖注入适合应用时选择 Flow。TCA 提供更广泛的集成应用架构及生态。[框架比较](docs/FRAMEWORK_COMPARISON.md) 说明定位，不主张普遍性能优势。

## 开发与验证

使用隔离 checkout 与 Swift 6.3+，阅读 [贡献指南](CONTRIBUTING.md) 与 [仓库规则](CLAUDE.md)。允许本地静态检查、针对性测试和消费者 fixture。完整的 **28 项必需** release preflight 只在 CI 执行，含四个 OS 27 运行时。较旧的 iOS 18.5 / tvOS 18.5 / watchOS 11.5 / visionOS 2.5 检查是可选且不自动运行的；不可用证据不是 PASS，部署下限不变。[发布流程](RELEASING.md)。

Swift 6.3 的 Store/TestStore deinit 在 release 模式使用已记录的编译器 workaround，参见 [工具链跟踪](docs/SWIFT_TOOLCHAIN_TRACKING.md)。本地通过不等于发布认证或全平台验证。

```bash
./scripts/principle-gates.sh --static
./scripts/check-doc-copyable-examples.rb
python3 skills/innoflow/scripts/validate_consumer.py --scratch-path /tmp/innoflow-skill-validation
```

## 支持

[支持](SUPPORT.md) · [贡献](CONTRIBUTING.md) · [治理](GOVERNANCE.md) · [行为准则](CODE_OF_CONDUCT.md) · [安全](SECURITY.md) · [MIT 许可证](LICENSE)。

通过 [GitHub Sponsors](https://github.com/sponsors/InnoSquadCorp) 或 [Patreon](https://www.patreon.com/15188938/join) 支持开发。
