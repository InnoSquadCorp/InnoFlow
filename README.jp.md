# InnoFlow

[English](./README.md) | [한국어](./README.kr.md) | 日本語 | [简体中文](./README.cn.md)

> この文書は日本語の companion guide です。常に最新なのは [English README](./README.md) です。

InnoFlow は、ビジネス/ドメイン状態遷移に集中した SwiftUI ファーストの一方向アーキテクチャフレームワークです。

この文書と下記のインストール例は、6.0.0 候補の API 契約を説明します。
候補を固定した時点の公開安定版は 5.1.1 でした。6.0.0 タグと GitHub Release の
公開状態は GitHub で別途確認してください。

## 基本方針

- 公式な feature authoring では 3 つ目の reducer generic を明示します。
  app-boundary output がなければ `Never`、送出する場合は feature の typed
  `Output` を使用します。
- 標準合成形ではない labeled/multi-payload の `Action` case は、canonical な
  `<caseName>CasePath` の手動宣言または `@InnoFlowCasePathIgnored` で警告の意図を明示します。
- 合成は `Reduce`, `CombineReducers`, `Scope`, `IfLet`, `IfCaseLet`, `ForEachReducer` を中心に行います。
- `PhaseMap` は phase-heavy feature 向けの canonical runtime phase-transition layer です。
- `PhaseTransitionGraph` は generic automata runtime ではなく、opt-in validation layer です。
- binding は `@BindableField` と projected key path を通して明示的に接続します。
- `TestStore.exhaustivity` のデフォルトは `.on` で、すべての状態遷移と effect action を漏れなく検証します。テストは `finish()` で終了し、未検証の作業を残した deinit はポリシーに従って失敗、警告、または無通知で処理されます。実行の cancellation が先に受理されていない場合、`EffectTask.run` から漏れた cancellation 以外のエラーは、このポリシーに関係なく元の action assertion 位置で一度失敗します。
- `Store.send(_:)` は、その dispatch から派生した effect tree だけを完了またはキャンセルできる `FlowTask` を返します。
- reducer は一度限りの app-boundary command を typed `Output` として送出でき、復元・描画する値は引き続き `State` に置きます。
- 特定 dispatch の output が必要な場合、`send(_:capturingOutputs:)` は enqueue
  前に single-consumer の `OutputFlowTask` stream を設定し、store-wide
  `outputs()` broadcast とは分離します。
- captured output を待つ consumer Task のキャンセルは、その dispatch だけを停止します。
  正常終了や broadcast 購読解除は effect を停止しません。capture を保持したまま
  `break` で抜ける場合、処理を停止するには `cancel()` を明示的に呼びます。
- output のない子 reducer と effect helper は `promoteOutput(to:)` で再利用できます。
  実際の output 型は引き続き `mapOutput(_:)` で明示的に変換します。
- `TestStore.receiveOutput` は predicate と `CasePath` による非 `Equatable` output の検証も
  サポートし、すべての形式が exhaustivity と合計 timeout を守ります。
- `strictPhaseTotality: true` は直接宣言された `Phase` source/target の欠落を
  compile error にし、動的 trigger semantics は `requireComplete(...)` で検証します。
- `Store` は effect の cancellation と run failure を MainActor 境界で順序付けます。cancellation が先に受理された場合、非協調的な処理が後から投げたエラーを `didFailRun` として再分類しません。
- ルーティング、transport、session lifecycle、構築時の依存グラフはアプリ境界の外側で所有します。

境界ドキュメント:

- [Cross-Framework Boundaries](./docs/CROSS_FRAMEWORK.md)
- [Dependency Patterns](./docs/DEPENDENCY_PATTERNS.md)

## Why InnoFlow over TCA?

TCA は dependency system、navigation pattern、testing convention、大きな
ecosystem まで含む広い application architecture が必要な場合に強い選択肢です。
InnoFlow はより小さい境界を保ちたい場合に選びます。reducer は business
transition だけを所有し、dependency は constructor-injected bundle として明示し、
navigation/transport は app boundary に残し、SwiftUI 専用の convenience API は
optional product の `InnoFlowSwiftUI` に置きます。

詳しい比較は [Framework Comparison](./docs/FRAMEWORK_COMPARISON.md) を参照してください。

## インストール

```swift
dependencies: [
  .package(url: "https://github.com/InnoSquadCorp/InnoFlow.git", from: "6.0.0")
]
```

```swift
.target(
  name: "YourDomain",
  dependencies: ["InnoFlowCore"]
),

.target(
  name: "YourSwiftUIApp",
  dependencies: ["InnoFlow", "InnoFlowSwiftUI"]
),

.testTarget(
  name: "YourAppTests",
  dependencies: ["InnoFlowCore", "InnoFlowTesting"]
)
```

runtime-only の non-UI feature/domain target は `InnoFlowCore` だけに依存できます。
`@InnoFlow` macro を使う target は `InnoFlow` に直接依存する必要があります。
SwiftUI app target は `InnoFlowSwiftUI` も依存に追加して、`Store.binding`,
`ScopedStore.binding`, `Store.preview`, `EffectTask.animation(Animation?)` を使います。
compiler-plugin trust、SwiftSyntax prebuilt fallback、CI flag、`InnoFlowCore`
recovery path は [`Macro Operations`](./docs/MACRO_OPERATIONS.md) を参照してください。

## 主要リンク

- [English README](./README.md)
- [Architecture Contract](./ARCHITECTURE_CONTRACT.md)
- [Cross-Framework Boundaries](./docs/CROSS_FRAMEWORK.md)
- [Macro Operations](./docs/MACRO_OPERATIONS.md)
- [Support](./SUPPORT.md)
- [Governance](./GOVERNANCE.md)
- [Contributing](./CONTRIBUTING.md)
- [Security](./SECURITY.md)
- [Dependency Patterns](./docs/DEPENDENCY_PATTERNS.md)
- [Framework Comparison](./docs/FRAMEWORK_COMPARISON.md)
- [Phase-Driven Modeling](./PHASE_DRIVEN_MODELING.md)
- [Release Notes](./RELEASE_NOTES.md)
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

SwiftUI では projected key path を使って binding を明示的に接続します。
SwiftUI view target では `import InnoFlowSwiftUI` を追加します。

```swift
Stepper(
  "Step: \(store.step)",
  value: store.binding(\.$step, to: CounterFeature.Action.setStep)
)
```

`binding(_:to:)` が正準（canonical）表記です。`binding(_:send:)` と trailing-closure 表記は意味的に同一の互換表記として deprecation なしで維持されます。新しいコードでは `to:` を使ってください。

## 合成サーフェス

- `Reduce`: 基本 reducer primitive
- `CombineReducers`: 宣言順の reducer 合成
- `Scope`: 常に存在する child state/action の持ち上げ
- `IfLet`: optional child state
- `IfCaseLet`: enum-backed child state
- `ForEachReducer`: collection child state
- `SelectedStore`: 読み取り専用の派生モデル。単一の明示的な key path には `select(dependingOn:)` を使い、2 つ以上の key path には可変長引数の `select(dependingOnAll:)` を使います。dependency を宣言できない場合の `select { ... }` は always-refresh fallback です。dynamic member read は SwiftUI の observer race に備え、debug では診断し、release では最後の snapshot を返します。非 UI コードでは dead projection を `optionalValue` の `nil` として扱うか、すべてのビルドで厳格な `requireAlive()` を使います。

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

## 6.0 の実行調整と検証

異なる dispatch が同じ Store-local resource を使う場合は、`.latest`、
`.dropWhileRunning`、bounded `.serial(maxPending:)` を使用します。複数 dispatch
の lifetime は `withFlowScope` で所有し、本番診断には opt-in かつ bounded、
payload-free な `StoreDiagnostics` を使います。テストでは `TestStoreInvariant`、
`TestStoreScenario`、macro が合成する Output case path を利用できます。これらは
永続化 transaction、retry、rollback の代替ではありません。

## `PhaseMap` を使うべきケース

- `phase` enum が既に存在する
- legal transition が feature contract の一部である
- reducer の複数 branch に `state.phase = ...` が散らばっている

strict totality enforcement、optional metrics package などは、現時点ではコア要件ではなく条件付き roadmap 項目です。
