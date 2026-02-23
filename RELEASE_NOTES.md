# InnoFlow Release Notes

## 2.4.0 Patch (Throttle Full Control + Animation Modifier)

This patch extends effect orchestration while preserving cancellation guarantees and existing store APIs.

### Added

1. Full-control throttle API:
   - `throttle(_ id:for:)` (existing leading-only shortcut)
   - `throttle(_ id:for:leading:trailing:)`
2. Animation modifier:
   - `animation(_ animation: Animation? = .default)`
   - Applies to actions emitted from nested effect paths (`.send` and `.run`).
3. Coverage expansion:
   - trailing-only throttle semantics
   - leading+trailing semantics (trailing only when an extra in-window event exists)
   - throttle cancellation integration (`cancelEffects`, `cancelAllEffects`)
   - animation composition tests

### Changed

1. `Store` and `TestStore` now track pending trailing throttle events per `EffectID`.
2. Trailing throttle state is cleaned up on ID cancellation and global cancellation.
3. Effect execution context now carries animation metadata without introducing dynamic `EffectID` values.

**요약(KR)**: v2.4는 throttle의 leading/trailing 전체 조합과 animation modifier를 추가하고, 취소 강보장을 유지한 채 테스트 범위를 확장한 릴리스입니다.

## 2.3.0 Patch (Coverage + Combinators + Diagnostics)

This patch focuses on runtime ergonomics and quality gates without changing `Store` public method signatures.

### Added

1. Built-in combinators on `EffectTask`:
   - `debounce(_ id:for:)`
   - `throttle(_ id:for:)` (leading-only)
2. Expanded test coverage:
   - `ScopedStore` projection and action forwarding
   - binding positive flow and compile contract rejection for non-bindable key paths
   - deinit cancellation edge case
   - CI-safe stress loops with heavy opt-in mode (`INNOFLOW_HEAVY_STRESS=1`)
3. Improved macro diagnostics:
   - exact expected reducer signature
   - concrete mismatch details
   - explicit remediation guidance

### Changed

1. Runtime semantics are now aligned for `merge` in awaited paths (concurrent execution + wait-for-all).
2. Documentation is updated with English-primary content and Korean summary notes.

**요약(KR)**: v2.3은 `debounce`/`throttle` 내장, 테스트 커버리지 확대, 매크로 진단 고도화를 포함한 품질 패치 릴리스입니다.

## 🚧 2.0.0 Preview (Breaking API Changes)

This section previews the intended API direction of **InnoFlow v2**.
v2 prioritizes ideal API design over backward compatibility, and allows breaking changes.

**요약(KR)**: 이 섹션은 v2 API 방향을 미리 공유하는 프리뷰이며, 하위호환보다 이상적 설계를 우선합니다.

### Why v2?

1. Effect 모델을 단일 조합 DSL로 통합
2. binding/reducer 계약의 일관성 강화
3. async 취소/테스트 결정성 개선
4. SwiftUI 사용성은 유지하면서 동시성 런타임을 강화

### Planned Breaking Changes (Preview)

1. `Reducer<State, Action, Mutation, Effect>` → `Reducer<State, Action>`
2. `Reduce`, `EffectOutput` 제거
3. `handle(effect:)` 파이프라인 제거
4. `reduce(into:action:) -> EffectTask<Action>` 도입
5. `Store.binding`을 `@BindableField` 기반 필드로 제한
6. `@InnoFlow` 매크로 계약을 v2 reducer 형태로 변경
7. `EffectTask.Operation` 내부 캡슐화 (public surface 제거)
8. `EffectID`를 `StaticString` 기반 `Sendable` 타입으로 재정의 (동적 `String` ID 금지)
9. `Store.cancelEffects` / `Store.cancelAllEffects`를 `async` 계약으로 변경
10. 매크로 시그니처 검증을 구조 중심(`reduce` + `into`/`action` + `inout`)으로 조정
11. 취소 경계 런타임 단순화 (`pendingCancellableRunsByID` 제거, emit 게이트 강화)

### Quality Gates (SwiftUI + SOLID)

| Gate | Status | Notes |
|---|---|---|
| SwiftUI philosophy alignment | Conditional Pass | Single state path and explicit binding are satisfied; bridge alignment is still pending |
| SOLID alignment | Conditional Pass | Reducer/runtime/store boundaries are strong; DIP still depends on app-level conventions |

### Dependency Impact

| Module | Impact | Required Action |
|---|---|---|
| InnoFlow | High | Migrate all features to `EffectTask`-based reducer |
| InnoFlowTesting | High | Replace sleep-oriented async testing patterns with deterministic timeout/cancellation model |
| InnoRouterFlowBridge | High | Release **v2** aligned with new reducer/effect contracts |
| InnoRouterEffects | Medium | Update InnoFlow integration examples to v2 effect syntax |
| App Integrators | High | Run migration checklist and update feature templates/macros |

### InnoRouter Compatibility Note

InnoFlow and InnoRouter are highly compatible from a `NavStack<Route>` state-driven navigation perspective.
However, v2 migration requires a synchronized update of **InnoRouterFlowBridge** and effect-integration examples.

**요약(KR)**: 상태 기반 네비게이션 궁합은 높지만, 브리지와 예제 코드는 v2로 함께 정렬해야 합니다.

### Migration Planning

See [API_DESIGN_EVALUATION.md](API_DESIGN_EVALUATION.md) for full migration and evaluation details.

1. 외부 프레임워크 가중 비교(TCA/ReactorKit/ReSwift/SwiftRex)
2. v1 점수표와 API gap
3. v2 공개 API 제안과 migration checklist
4. InnoRouter 연동 전략과 회귀 시나리오

---

## InnoFlow 1.0.0 Release Notes (Legacy v1 API)

We're excited to announce the initial release of **InnoFlow** - a lightweight, hybrid architecture framework for SwiftUI that combines the best of Elm Architecture with SwiftUI's native `@Observable` pattern.

## 🎉 What is InnoFlow?

InnoFlow provides a clean, testable architecture for SwiftUI apps with:
- **Unidirectional Data Flow**: `Action → Reduce → Mutation → State → View`
- **SwiftUI-Native**: Built on `@Observable` for seamless integration
- **Type-Safe**: Leverages Swift's type system for compile-time safety
- **Testable**: First-class testing support with `TestStore`
- **Lightweight**: Minimal boilerplate compared to other architectures

## ✨ Key Features

### Core Architecture
- **Store**: Observable state container that automatically updates SwiftUI views
- **Reducer**: Protocol-based feature definition with clear separation of concerns
- **Action/Mutation/Effect**: Clean separation between user actions, state changes, and side effects

### Swift Macros
- **@InnoFlow**: Automatically generates boilerplate code and protocol conformance
- **@BindableField**: Type-safe two-way bindings for SwiftUI controls

### Effect System
- Support for async operations (API calls, database access, etc.)
- Multiple effect output types: `.none`, `.single`, `.stream`
- Automatic effect cancellation

### Testing
- **TestStore**: Comprehensive testing utilities
- Action and state assertion support
- Effect testing with action verification

## 📦 Installation

### Swift Package Manager

Add InnoFlow to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/innosquad-mdd/InnoFlow.git", from: "1.0.0")
]
```

Or add it in Xcode:
1. File → Add Package Dependencies
2. Enter: `https://github.com/innosquad-mdd/InnoFlow.git`
3. Select version: `1.0.0`

## 🚀 Quick Start

### 1. Define Your Feature

```swift
import InnoFlow

@InnoFlow
struct CounterFeature {
    struct State: Equatable {
        var count = 0
        @BindableField var step = 1
    }
    
    enum Action {
        case increment
        case decrement
        case setStep(Int)
    }
    
    enum Mutation {
        case setCount(Int)
        case setStep(Int)
    }
    
    func reduce(state: State, action: Action) -> Reduce<Mutation, Never> {
        switch action {
        case .increment:
            return .mutation(.setCount(state.count + state.step))
        case .decrement:
            return .mutation(.setCount(state.count - state.step))
        case .setStep(let step):
            return .mutation(.setStep(step))
        }
    }
    
    func mutate(state: inout State, mutation: Mutation) {
        switch mutation {
        case .setCount(let count):
            state.count = count
        case .setStep(let step):
            state.step = max(1, step)
        }
    }
}
```

### 2. Use in SwiftUI

```swift
struct CounterView: View {
    @State private var store = Store(CounterFeature())
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Count: \(store.count)")
                .font(.largeTitle)
            
            HStack(spacing: 40) {
                Button("−") { store.send(.decrement) }
                Button("+") { store.send(.increment) }
            }
            
            Stepper("Step: \(store.step)", value: store.binding(
                \.step,
                send: { .setStep($0) }
            ))
        }
    }
}
```

## 📚 Documentation

- [README](README.md) - Complete guide and API reference
- [Examples](Examples/) - Sample apps demonstrating InnoFlow usage
- [Changelog](CHANGELOG.md) - Version history

## 🤝 Contributing

We welcome contributions! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## 📄 License

MIT License - See [LICENSE](LICENSE) for details.

## 🙏 Acknowledgments

InnoFlow is inspired by:
- The Elm Architecture
- TCA (The Composable Architecture)
- SwiftUI's `@Observable` pattern

---

**Made with ❤️ by InnoSquad**

For questions, issues, or feature requests, please open an issue on GitHub.
