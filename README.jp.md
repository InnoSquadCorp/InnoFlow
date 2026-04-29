# InnoFlow

[English](./README.md) | [한국어](./README.kr.md) | 日本語 | [简体中文](./README.cn.md)

> この文書は日本語の companion guide です。常に最新なのは [English README](./README.md) です。

InnoFlow は、ビジネス/ドメイン状態遷移に集中した SwiftUI ファーストの一方向アーキテクチャフレームワークです。

## 基本方針

- 公式な feature authoring は `var body: some Reducer<State, Action>` です。
- 合成は `Reduce`, `CombineReducers`, `Scope`, `IfLet`, `IfCaseLet`, `ForEachReducer` を中心に行います。
- `PhaseMap` は phase-heavy feature 向けの canonical runtime phase-transition layer です。
- `PhaseTransitionGraph` は generic automata runtime ではなく、opt-in validation layer です。
- binding は `@BindableField` と projected key path を通して明示的に接続します。
- ルーティング、transport、session lifecycle、構築時の依存グラフはアプリ境界の外側で所有します。

境界ドキュメント:

- [Cross-Framework Boundaries](./docs/CROSS_FRAMEWORK.md)
- [Dependency Patterns](./docs/DEPENDENCY_PATTERNS.md)

## インストール

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

## 主要リンク

- [English README](./README.md)
- [Architecture Contract](./ARCHITECTURE_CONTRACT.md)
- [Cross-Framework Boundaries](./docs/CROSS_FRAMEWORK.md)
- [Dependency Patterns](./docs/DEPENDENCY_PATTERNS.md)
- [Phase-Driven Modeling](./PHASE_DRIVEN_MODELING.md)
- [Release Notes](./RELEASE_NOTES.md)
- [Framework Evaluation](./FRAMEWORK_EVALUATION.md)
- [Canonical Sample README](./Examples/InnoFlowSampleApp/README.md)

## クイックスタート

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

SwiftUI では projected key path を使って binding を明示的に接続します。

```swift
Stepper(
  "Step: \(store.step)",
  value: store.binding(\.$step, to: CounterFeature.Action.setStep)
)
```

`binding(_:to:)` は `binding(_:send:)` の argument-label alias です。両方の overload が存在するので、label は省略しないでください。

## 合成サーフェス

- `Reduce`: 基本 reducer primitive
- `CombineReducers`: 宣言順の reducer 合成
- `Scope`: 常に存在する child state/action の持ち上げ
- `IfLet`: optional child state
- `IfCaseLet`: enum-backed child state
- `ForEachReducer`: collection child state
- `SelectedStore`: 読み取り専用の派生モデル。1〜6 個の明示的な key path には `dependingOn:` overload を使い、より大きな明示的 dependency set には `select(dependingOnAll:)` を使います。dependency を宣言できない場合の `select { ... }` は always-refresh fallback です

## サンプルカタログ

公式サンプルアプリは 10 個のデモを持ちます。

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

`RouterCompositionDemo` は navigation 境界、`BidirectionalWebSocketDemo` は transport 境界、`AuthenticationFlowDemo` と `OfflineFirstDemo` は explicit DI bundle パターンの参照サンプルです。

## Cross-framework メモ

- reducer は business intent を出し、具体的な route stack は app/coordinator が所有します。
- transport、reconnect、session lifecycle は reducer 外の adapter 境界に置きます。
- 構築時の dependency graph は app 側で作り、reducer には `Dependencies` bundle だけを渡します。
- 詳細な方針は [Cross-Framework Boundaries](./docs/CROSS_FRAMEWORK.md)、DI の詳細は [Dependency Patterns](./docs/DEPENDENCY_PATTERNS.md) を参照してください。

## ドキュメント方針

- 英語文書を canonical source of truth として維持します。
- 日本語/韓国語/中国語の文書は、概要、quick start、sample catalog、boundary docs への導線を含みます。
- 詳細な authoring guidance と API 契約は、まず英語文書を更新します。

## `PhaseMap` を使うべきケース

- `phase` enum が既に存在する
- legal transition が feature contract の一部である
- reducer の複数 branch に `state.phase = ...` が散らばっている

strict totality enforcement、optional metrics package などは、現時点ではコア要件ではなく条件付き roadmap 項目です。
