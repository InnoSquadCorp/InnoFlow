# InnoFlow API Design Evaluation (v2.4)

> Baseline: `ios-native-skills` (`innosquad-innoflow`, `innosquad-innorouter`, `swiftui-*`, `concurrency-*`, `test-methodology`, `arch-*`)  
> Policy: Ideal API design is prioritized over backward compatibility. Breaking changes are allowed.

## 1. Executive Summary

1. InnoFlow v2.4 is aligned with the API simplification direction (`Reducer + EffectTask`).
2. Built-in combinators now include full-control throttle (`leading`/`trailing`) and animation modifier support.
3. Cancellation guarantees are strong (`async` cancellation APIs + late-emission drop guards).
4. Macro diagnostics are now concrete and actionable.
5. InnoRouter architectural compatibility is high, but FlowBridge contract alignment remains a follow-up track.

**요약(KR)**: v2.4는 throttle 제어력과 animation modifier를 추가해 effect 모델링 정밀도를 높였고, 취소 안정성은 그대로 유지했습니다.

## 2. Evaluation Framework

### 2.1 Weighted Axes (for external framework comparison)

1. API consistency and clarity: 25%
2. Effect modeling (cancellation/composition/lifecycle): 25%
3. Concurrency safety (Sendable/Actor): 15%
4. Deterministic testing (TestStore/time control): 20%
5. SwiftUI ergonomics: 15%

### 2.2 Required Quality Gates (pass/conditional/fail)

1. SwiftUI philosophy alignment
2. SOLID alignment

### 2.3 Source of Truth

1. InnoFlow core:
   - `Sources/InnoFlow/InnoFlow.swift`
   - `Sources/InnoFlow/Reducer.swift`
   - `Sources/InnoFlow/EffectTask.swift`
   - `Sources/InnoFlow/Store.swift`
2. Testing and diagnostics:
   - `Sources/InnoFlowTesting/TestStore.swift`
   - `Tests/InnoFlowTests/InnoFlowTests.swift`
   - `Sources/InnoFlowMacros/InnoFlowMacro.swift`
3. InnoRouter compatibility references:
   - `../InnoRouterFlowBridge/Sources/InnoRouterFlowBridge/InnoRouterFlowNavigator.swift`
   - `../InnoRouterFlowBridge/Sources/InnoRouterFlowBridge/InnoRouterFlowNavigationHost.swift`
   - `../InnoRouter/Sources/InnoRouterEffects/NavigationEffectHandler.swift`
   - `../InnoRouter/Sources/InnoRouterCore/NavCommand.swift`

## 3. InnoFlow v2.4 Scorecard

| Axis | Score (5.0) | Evidence |
|---|---:|---|
| API consistency/clarity | 4.4 | Single reducer contract and one effect DSL (`EffectTask`) |
| Effect modeling | 4.6 | `run/merge/concatenate/cancel/cancellable/debounce/throttle(leading+trailing)/animation` |
| Concurrency safety | 4.1 | `@MainActor` store adapter + actor runtime + `Sendable` constraints |
| Deterministic testing | 4.5 | `TestStore` timeout race model + compile-contract + deinit/stress tests |
| SwiftUI ergonomics | 4.5 | `@Observable`, dynamic member access, bindable-only contract |

**Weighted total: 4.44 / 5.00 (Grade A)**

**요약(KR)**: 전체 점수는 A 등급이며, v2.4에서 effect 모델링 점수가 추가로 개선되었습니다.

## 4. SwiftUI Philosophy Gate

Checklist:

1. Single source of truth: state transitions only via `send -> reduce(into:)`
2. Declarative/value-driven navigation model compatibility
3. Minimized observation scope
4. Explicit binding contract (`@BindableField` only)
5. View purity (state rendering + action dispatch only)

Decision: **Conditional Pass**

1. Passed: 1, 3, 4
2. Conditional: 2, 5 (app-level and bridge-level enforcement still required)

**요약(KR)**: 프레임워크 레벨 요건은 대부분 충족했지만 네비게이션 브리지/앱 레이어 규약까지 포함한 완전 통과는 후속 정렬이 필요합니다.

## 5. SOLID Gate

Checklist:

1. SRP: reducer = transition, runtime = effect lifecycle, store = orchestration
2. OCP: combinator extension without reducer contract changes
3. LSP: any feature can conform to the same reducer contract
4. ISP: runtime/testing/macro concerns are separated
5. DIP: dependency injection by protocol should be used at feature layer

Decision: **Conditional Pass**

1. Passed: 1, 2, 3, 4
2. Conditional: 5 (framework cannot force app DI conventions)

**요약(KR)**: 구조적 분리는 잘 되어 있으나 DIP는 팀 컨벤션/리뷰 체계가 동반되어야 완전 통과가 가능합니다.

## 6. External Framework Comparison

Targets: `TCA`, `ReactorKit`, `ReSwift`, `SwiftRex`

| Framework | Strengths | Weaknesses | Best-fit scenario |
|---|---|---|---|
| InnoFlow v2.4 | SwiftUI ergonomics, low adoption cost, clear runtime model | Less built-in scheduling depth than TCA | SwiftUI-first products with practical UDF |
| TCA | Deep effect/testing model and tooling | Higher API learning cost | Large-scale apps with strict composition needs |
| ReactorKit | Intuitive Action/Mutation/State flow | Rx-centric runtime coupling | Existing Rx-heavy codebases |
| ReSwift | Minimal and predictable Redux core | Effect/testing conventions left to team | Small or heavily customized stacks |
| SwiftRex | Powerful middleware/effect extensibility | Higher initial design complexity | Teams needing deep middleware orchestration |

Gap summary:

1. Effect depth: `TCA`, `SwiftRex` remain stronger in advanced scheduling surfaces.
2. SwiftUI ergonomics and lightweight adoption: `InnoFlow`, `TCA` are stronger.
3. API simplicity: `InnoFlow`, `ReSwift` are stronger.

## 7. Public API Snapshot (Current)

```swift
public protocol Reducer<State, Action> {
    associatedtype State: Sendable
    associatedtype Action: Sendable
    func reduce(into state: inout State, action: Action) -> EffectTask<Action>
}

public struct EffectID: Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: StaticString
    public init(_ rawValue: StaticString)
    public init(stringLiteral value: StaticString)
}

public struct EffectTask<Action: Sendable>: Sendable {
    public static var none: Self { get }
    public static func send(_ action: Action) -> Self
    public static func run(
        priority: TaskPriority? = nil,
        _ operation: @escaping @Sendable (Send<Action>) async -> Void
    ) -> Self
    public static func merge(_ effects: Self...) -> Self
    public static func concatenate(_ effects: Self...) -> Self
    public static func cancel(_ id: EffectID) -> Self
    public func cancellable(_ id: EffectID, cancelInFlight: Bool = false) -> Self
    public func debounce(_ id: EffectID, for interval: Duration) -> Self
    public func throttle(_ id: EffectID, for interval: Duration) -> Self
    public func throttle(
        _ id: EffectID,
        for interval: Duration,
        leading: Bool = true,
        trailing: Bool = false
    ) -> Self
    public func animation(_ animation: Animation? = .default) -> Self
}

@MainActor
@Observable
public final class Store<R: Reducer> {
    public private(set) var state: R.State
    public init(reducer: R, initialState: R.State)
    public func send(_ action: R.Action)
    public func cancelEffects(identifiedBy id: EffectID) async
    public func cancelAllEffects() async
}
```

## 8. InnoRouter Compatibility Assessment

Current conclusion:

1. Architectural compatibility: high (`NavStack<Route>` state-driven model fits well).
2. Integration risk: high while FlowBridge still expects old contracts.
3. Current release policy: allow temporary breakage and align via dedicated Bridge v2 release.

One-line conclusion:

1. **InnoFlow and InnoRouter are architecture-compatible, but a v2 bridge update is mandatory for contract-level compatibility.**

**요약(KR)**: 아키텍처 궁합은 높지만 브리지 계약은 별도 v2 릴리스로 반드시 정렬해야 합니다.

## 9. Breaking Change List

1. Removed `Reducer<State, Action, Mutation, Effect>`
2. Removed `Reduce`
3. Removed `EffectOutput`
4. Removed `Mutation` + `handle(effect:)` pipeline
5. Restricted binding to `BindableProperty` key paths
6. Enforced v2 reducer signature in `@InnoFlow` macro
7. Internalized effect runtime representation (`EffectTask.Operation`)
8. Redefined `EffectID` as `StaticString`-based identifier
9. Made store cancellation APIs `async`

## 10. Migration Checklist

### 10.1 Feature Migration

1. Replace `reduce(state:action:)` with `reduce(into:action:)`
2. Remove mutation enum and update state directly inside reducer
3. Move async work into `EffectTask.run`
4. Restrict bindings to `@BindableField` properties
5. Assign explicit effect IDs for long-running cancellable effects

### 10.2 Bridge Migration (Follow-up Track)

1. Remove v1 reducer assumptions from FlowBridge
2. Document state-driven vs effect-driven navigation patterns
3. Standardize deep-link processing with async `EffectTask` pipelines

## 11. Validation Scenarios

1. Macro contract rejects v1 reducer signatures
2. Cancellation APIs (`cancelEffects`, `cancelAllEffects`) are deterministic
3. Non-bindable key path binding fails at compile time
4. Combinator contracts:
   - `debounce`: latest-only
   - `throttle`: fixed window with configurable `leading`/`trailing`
   - `leading+trailing`: trailing emits only when there is at least one extra in-window event
5. Animation modifier contract:
   - `animation` applies to effect-emitted actions in both `.send` and `.run` paths
6. Store deinit cancels long-running effects without late emission
7. Responsibility separation remains clean (reducer/runtime/store/testing)
8. Timeout and cancellation behavior is deterministic under repeated test runs
9. InnoRouter push/pop/replace and deep-link sync are validated in bridge v2 track

## 12. Remaining Risk Status

1. Effect runtime internals exposed as public API: **Resolved**
2. `EffectID @unchecked Sendable` safety risk: **Resolved**
3. Cancellation API nondeterminism: **Resolved**
4. Cancellation boundary complexity (`pendingCancellableRunsByID` family): **Resolved**
5. Macro string overfitting risk: **Resolved**
6. Test coverage gaps (`ScopedStore`, binding contract, deinit edge): **Resolved**
7. Missing built-in combinators: **Resolved**
8. Missing animation effect modifier: **Resolved**
9. InnoRouterFlowBridge version mismatch: **Open (follow-up)**

---

This document is an implementation-backed decision report for InnoFlow v2.4.  
InnoRouterFlowBridge v2 remains a separate delivery track.
