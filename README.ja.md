# InnoFlow

[![Release](https://img.shields.io/github/v/release/InnoSquadCorp/InnoFlow)](https://github.com/InnoSquadCorp/InnoFlow/releases) [![License](https://img.shields.io/github/license/InnoSquadCorp/InnoFlow)](LICENSE) [Swift Package Index](https://swiftpackageindex.com/InnoSquadCorp/InnoFlow) · [CI and public operations](docs/automation-policy.md)

[English](README.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Deutsch](README.de.md) | [简体中文](README.zh-Hans.md) | [日本語](README.ja.md) | [Русский](README.ru.md)

SwiftUI を中心に、ビジネス・ドメインの状態遷移を扱う単方向状態管理フレームワークです。Reducer、Store、決定的なテストから始め、機能に必要なときにオーケストレーションを加えてください。

## InnoFlow 6.0.2

この README は **2026-10-08** に `1176de1e4783b638c03a9334f43cc49378957148` から公開された **6.0.2 API** を説明します。[バージョン別ソース](https://github.com/InnoSquadCorp/InnoFlow/tree/6.0.2) · [リリースノート](RELEASE_NOTES.md) · [移行](MIGRATION.md)。

開発ブランチには後続の CI、テスト構成、検証ツール、文書変更があります。この更新時点の `Sources/` は 6.0.2 と同一で、後続のツール変更は未公開です。開発の `STABLE_VERSION` は 6.0.2、変更不可のタグには当時の候補メタデータが残ります。ホストされた DocC はデプロイされたリビジョンを説明するため、導入版の確認にはタグのソースを使ってください。七つの README は同じ入門内容を扱い、詳細ガイドは英語です。

## インストール

Swift **6.3+**、Swift **6 言語モード**が必要です。最低対応版は iOS **18+**、macOS **15+**、tvOS **18+**、watchOS **11+**、visionOS **2+**。SwiftSyntax は `>=603.0.0, <605.0.0`、リポジトリのロックは 604.0.0 です。対象に合う Xcode/SDK を選んでください。宣言された最低対応版は、すべての旧ランタイムでの実行検証を意味しません。

パッケージを追加し、製品を明示的に選びます。`from:` は将来の互換版も許可するため、実際の `Package.resolved` を確認してください。このリリースを再現する場合は `exact: "6.0.2"` を使います。

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

| 製品 | 用途 |
| --- | --- |
| `InnoFlowCore` | プラグイン不要のランタイムと意図的な復旧経路。SwiftUI には依存しません。 |
| `InnoFlow` | マクロ記述の入口で Core を再公開。`@InnoFlow` には直接 import が必要です。 |
| `InnoFlowSwiftUI` | 任意のバインディング、プレビュー、表示、ビュー所有タスク補助。Core を再公開します。 |
| `InnoFlowInspector` | 任意の診断 UI。Core のみに依存し、DEBUG での利用を推奨します。 |
| `InnoFlowTesting` | テスト専用ハーネスと手動クロック。Core を再公開し、出荷ターゲットには含めません。 |


## カウンター機能

マクロ利用者は入れ子の `State`、`Action`、`body` を宣言します。第三の Reducer ジェネリックは出力なしなら `Never`、出力があれば型付き `Output` です。`Reduce`、`CombineReducers`、`Scope`、`IfLet`、`IfCaseLet`、`ForEachReducer`、`ForEachIdentifiedReducer` で合成します。マクロが `reduce` を生成するため、通常の公開機能では手書きしません。

ラベルなしの単一子 payload は `<caseName>CasePath`、コレクション `id:action:` は `CollectionActionPath` を生成します。非対応のラベル付き・複数 Action payload は `Action` 内に標準の静的パスを宣言します。パス不要、または extension 内の場合は `@InnoFlowCasePathIgnored` を使います。

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

両方の宣言をアプリターゲットに置きます。`@BindableField` と `store.binding(\.$step, to:)` が標準です。`send:` と末尾クロージャの binding も非推奨化せずサポートします。`BindableProperty` は低レベルの格納型です。`@Environment` はビューで解決し、依存性は機能へ注入します。

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

## テスト

`TestStore.exhaustivity` は既定で `.on` です。すべての状態変更を検証し、effect の全アクションと型付き出力を受信して、`await store.finish()` を呼びます。検証クロージャの省略は状態変更なしを意味します。`.off` は意図的な部分テストだけに使い、ランタイム effect エラーは引き続き失敗します。`assertNoBufferedActions()` は途中のキュー確認で、`assertNoMoreActions()` は 6.0 で削除済みです。

以下のカウンターとテストは実行可能な文書ハーネスに結び付いています。インストール断片は manifest として組み立てて解析します。翻訳は同じコードを共有します。[詳細ガイド](docs/USER_GUIDE.md) は文脈が必要な例と完全なコードを区別し、[コード台帳](docs/contracts/doc-swift-fence-review.tsv) は検証器への対応を記録します。成功しても実機 UI 動作の証明にはなりません。

Effect アクションは `receive(...)`、出力は `receiveOutput(...)` で受信します。

上の manifest は製品の選択を示します。このカウンターのアプリテストでは、アプリのターゲットもテスト依存関係に追加し、`@testable import YourSwiftUIApp` で `CounterFeature` にアクセスしてください。文書ハーネスは機能とテストを同じテストターゲットでコンパイルします。

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

## 段階的な導入

- **Level 1:** `Reduce`、`Store`、`@BindableField`、`TestStore`。カウンターやフォームに phase graph や run lane は不要です。
- **Level 2:** 子の合成、ID 付きコレクション、`SelectedStore`、型付き一時的 `Output`。`mapOutput(_:)` で明示的に変換し、`promoteOutput(to:)` は `Never` に限定します。`outputs()` はライブで再生しないため dispatch 前に購読します。原子的な単一消費者キャプチャには明示的バッファ方針で `send(_:capturingOutputs:)` を使います。
- **Level 3:** `FlowTask`、`withFlowScope`、任意の子の寿命、実行受付、`PhaseMap`、診断、Inspector。`.latest`、`.dropWhileRunning`、上限付き `.serial(maxPending:)` は Store 内の受付を管理します。拒否を処理してください。直列実行はトランザクション、再試行、ロールバック、厳密に一度の配信を保証しません。

一つの状態部分には `select(dependingOn:)`、複数には `select(dependingOnAll:)`、通常のクロージャには always-refresh fallback を使います。`select(memoize: true)` は Equatable な親全体のスナップショットが同じ場合のみ更新を省略し、細かい依存性を推論しません。生きたクロージャ投影を再利用する意味的 `id` にはキャプチャ入力を含めます。失効した投影には `optionalState` / `optionalValue`、厳密な前提条件には `requireAlive()` を使います。

`@InnoFlow(phaseManaged: true)` は reduction 後に `PhaseMap` を適用して phase キーパスを所有します。未一致の phase/action は既定で許可された no-op です。`strictPhaseTotality: true` は直接の phase 宣言を確認し、`requireComplete(...)` は宣言されたサンプルトリガーを検証します。任意の述語や payload 領域全体は証明しません。`PhaseTransitionGraph` はトポロジーだけを検証し、ナビゲーションや転送を所有しません。

## 所有権と寿命

Reducer はドメイン状態を所有します。アプリ・coordinator が具体的なナビゲーションスタック、転送・セッション寿命、依存グラフ構築を所有します。Sendable な依存 bundle を明示的に注入してください。Flow は DI コンテナ、ネットワーククライアント、ルーターを提供しません。[依存パターン](docs/DEPENDENCY_PATTERNS.md) と [フレームワーク境界](docs/CROSS_FRAMEWORK.md) を参照してください。

`Store.send(_:)` はその dispatch と子孫の `FlowTask` を返します。`finish()` は終了を待ち、`cancel()` はそのツリーのみを取り消して、適用済み状態を巻き戻しません。ハンドルの破棄はキャンセルではありません。`withFlowScope` は追跡した dispatch のみを所有します。Effect のキャンセルは協調的です。`EffectContext` と注入クロックを使い、`ManualTestClock` で決定的な時間テストを行います。

SwiftUI 補助は sheet、navigation destination、alert、confirmation dialog、対応環境の popover を扱います。full-screen cover は macOS 非対応です。`innoFlowTask` は dispatch を消失や ID 変更に結び付けます。Inspector と `StoreDiagnostics` は任意、有界、payload なしです。診断ラベルにドメイン payload を入れないでください。描画、ナビゲーション、空間ウィンドウ・immersive の制御はアプリの責務です。

## 公式サンプル

[公式サンプル](Examples/InnoFlowSampleApp/README.md) には十個のデモがあり、ローカルパスで現在の checkout を使います。対話型シェルは iOS 優先です。他プラットフォームのビルドは immersive サンプルや完全な UI 同等性を意味しません。[設定](Examples/SETUP_GUIDE.md)。

システムコントロール、Dynamic Type、VoiceOver ラベル、安定した `accessibilityIdentifier` を使います。Smoke テストは以下の ID を対象とし、完全なアクセシビリティ監査ではありません。

`sample.basics`, `sample.orchestration`, `sample.phase-driven-fsm`, `sample.router-composition`, `sample.authentication-flow`, `sample.list-detail-pagination`, `sample.offline-first`, `sample.realtime-stream`, `sample.form-validation`, `sample.bidirectional-websocket`.

## 文書と Flow の選択

- [詳細ユーザーガイド](docs/USER_GUIDE.md)、[文書索引と版の境界](docs/DOCUMENTATION.md)
- [入門と API](https://innosquadcorp.github.io/InnoFlow/documentation/innoflow/)、[テスト API](https://innosquadcorp.github.io/InnoFlow/testing/documentation/innoflowtesting/)
- [Phase モデリング](PHASE_DRIVEN_MODELING.md)、[SwiftUI 制約](docs/SWIFTUI_DX_6_0.md)、[計測](docs/INSTRUMENTATION_COOKBOOK.md)
- [アーキテクチャ契約](ARCHITECTURE_CONTRACT.md)、[移行](MIGRATION.md)、[マクロ信頼と復旧](docs/MACRO_OPERATIONS.md)
- [AI skill](skills/README.md): 正確な 6.0.2 消費者基準。SwiftPM と skill のインストールは別です。

小さなドメイン状態境界とコンストラクタ注入がアプリに合う場合に Flow を選んでください。TCA はより広い統合アプリ設計とエコシステムを提供します。[比較](docs/FRAMEWORK_COMPARISON.md) は位置付けであり、普遍的な性能優位の主張ではありません。

## 開発と検証

隔離 checkout と Swift 6.3+ を使い、[貢献案内](CONTRIBUTING.md) と [規則](CLAUDE.md) を読んでください。ローカル静的検査、対象を絞ったテスト、消費者 fixture は許可されています。四つの OS 27 ランタイムを含む全 **28 必須** release preflight は CI のみで実行します。旧 iOS 18.5 / tvOS 18.5 / watchOS 11.5 / visionOS 2.5 は任意で自動実行しません。利用できなかった証拠は PASS ではなく、最低対応版は不変です。[手順](RELEASING.md)。

Swift 6.3 の Store/TestStore deinit には release モードのコンパイラ回避策があります。[ツールチェイン追跡](docs/SWIFT_TOOLCHAIN_TRACKING.md) を参照してください。ローカル成功はリリース認証や全プラットフォーム検証ではありません。

```bash
./scripts/principle-gates.sh --static
./scripts/check-doc-copyable-examples.rb
python3 skills/innoflow/scripts/validate_consumer.py --scratch-path /tmp/innoflow-skill-validation
```

## サポート

[サポート](SUPPORT.md) · [貢献](CONTRIBUTING.md) · [ガバナンス](GOVERNANCE.md) · [行動規範](CODE_OF_CONDUCT.md) · [セキュリティ](SECURITY.md) · [MIT ライセンス](LICENSE)。

[GitHub Sponsors](https://github.com/sponsors/InnoSquadCorp) または [Patreon](https://www.patreon.com/15188938/join) で開発を支援できます。
