# InnoFlow

[English](./README.md) | [한국어](./README.kr.md) | 日本語 | [简体中文](./README.cn.md)

> この文書は日本語の入口ガイドです。常に最新なのは [English README](./README.md) です。

InnoFlow は、ビジネス/ドメイン状態遷移に集中した SwiftUI ファーストの一方向アーキテクチャフレームワークです。

## 基本方針

- 公式な feature authoring は `var body: some Reducer<State, Action>` です。
- 合成は `Reduce`, `CombineReducers`, `Scope`, `IfLet`, `IfCaseLet`, `ForEachReducer` を中心に行います。
- `PhaseMap` は phase-heavy feature 向けの canonical runtime phase-transition layer です。
- `PhaseTransitionGraph` は generic automata runtime ではなく、opt-in validation layer です。
- binding は `@BindableField` と projected key path を通して明示的に接続します。
- ルーティング、transport、session lifecycle、構築時の依存グラフはアプリ境界の外側で所有します。

## インストール

```swift
dependencies: [
  .package(url: "https://github.com/InnoSquadCorp/InnoFlow.git", from: "3.0.1")
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
- [Phase-Driven Modeling](./PHASE_DRIVEN_MODELING.md)
- [Release Notes](./RELEASE_NOTES.md)
- [Framework Evaluation](./FRAMEWORK_EVALUATION.md)
- [Canonical Sample README](./Examples/InnoFlowSampleApp/README.md)

## ドキュメント方針

- 英語文書を canonical source of truth として維持します。
- 日本語/韓国語/中国語の文書は、入口ガイドと概要に重点を置きます。
- 詳細な authoring guidance と API 契約は、まず英語文書を更新します。

## `PhaseMap` を使うべきケース

- `phase` enum が既に存在する
- legal transition が feature contract の一部である
- reducer の複数 branch に `state.phase = ...` が散らばっている

strict totality enforcement、`SelectedStore` の 4+ dependency 最適化、optional metrics package などは、現時点ではコア要件ではなく条件付き roadmap 項目です。
