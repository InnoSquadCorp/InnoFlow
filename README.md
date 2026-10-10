# InnoFlow

[![Release](https://img.shields.io/github/v/release/InnoSquadCorp/InnoFlow)](https://github.com/InnoSquadCorp/InnoFlow/releases) [![License](https://img.shields.io/github/license/InnoSquadCorp/InnoFlow)](LICENSE) [Swift Package Index](https://swiftpackageindex.com/InnoSquadCorp/InnoFlow) · [CI and public operations](docs/automation-policy.md)

[English](README.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Deutsch](README.de.md) | [简体中文](README.zh-Hans.md) | [日本語](README.ja.md) | [Русский](README.ru.md)

SwiftUI-first unidirectional state management for business and domain transitions. Start with a reducer, a Store and deterministic tests; adopt orchestration only when your feature needs it.

## InnoFlow 6.0.2

This README describes the **published 6.0.2 API**, released on **2026-10-08** at `1176de1e4783b638c03a9334f43cc49378957148`. [Versioned source](https://github.com/InnoSquadCorp/InnoFlow/tree/6.0.2) · [Release notes](RELEASE_NOTES.md) · [Migration](MIGRATION.md).

The development branch contains later CI, test organization, validation and documentation changes. At this refresh its `Sources/` matches 6.0.2; those later tooling changes are unreleased. `STABLE_VERSION` is 6.0.2 on development, while the immutable tag retains its earlier candidate metadata. Hosted DocC follows its deployment revision; use tagged source for installed-version accuracy. All seven READMEs cover the same entry-level guidance; detailed guides are in English.

## Installation

Swift **6.3+**, Swift **6 language mode**; iOS **18+**, macOS **15+**, tvOS **18+**, watchOS **11+**, visionOS **2+**. The SwiftSyntax requirement is `>=603.0.0, <605.0.0`; repository locks use 604.0.0. Match Xcode/SDK to your destination. Declared deployment support does not mean every legacy runtime was exercised.

Add the package, then choose products explicitly. `from:` permits compatible future versions; inspect your actual `Package.resolved`. Use `exact: "6.0.2"` when reproducing this release.

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

| Product | Purpose |
| --- | --- |
| `InnoFlowCore` | Plugin-free runtime and intentional recovery path; no SwiftUI dependency. |
| `InnoFlow` | Macro authoring facade; reexports Core. Import it directly for `@InnoFlow`. |
| `InnoFlowSwiftUI` | Optional binding, previews, presentation and view-owned task helpers; reexports Core. |
| `InnoFlowInspector` | Optional diagnostics UI; depends only on Core. Prefer a DEBUG-only integration. |
| `InnoFlowTesting` | Test-only harness and manual clock; reexports Core. Keep out of shipping targets. |


## Counter feature

Macro users declare nested `State`, `Action` and `body`; the third reducer generic is `Never` without output, or the typed `Output`. Compose through `Reduce`, `CombineReducers`, `Scope`, `IfLet`, `IfCaseLet`, `ForEachReducer` and `ForEachIdentifiedReducer`. The macro generates `reduce`; ordinary public features do not implement it manually.

Standard unlabeled child payloads synthesize `<caseName>CasePath`, and collection `id:action:` cases synthesize `CollectionActionPath`. For unsupported labeled/multiple Action payloads, declare the canonical static path inside `Action`, or use `@InnoFlowCasePathIgnored` when no path is needed or it lives in an extension.

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

Put both declarations in the app target. `@BindableField` and `store.binding(\.$step, to:)` are canonical. `send:` and trailing-closure bindings remain supported without deprecation. `BindableProperty` is low-level storage. Resolve `@Environment` in the view and inject dependencies into the feature.

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

## Testing

`TestStore.exhaustivity` defaults to `.on`: assert every state change, receive every effect action and typed output, then call `await store.finish()`. An omitted assertion closure means no state change. Use `.off` only for intentionally partial tests; runtime effect errors still fail. `assertNoBufferedActions()` is an intermediate queue check; `assertNoMoreActions()` was removed in 6.0.

The counter and test below are bound to the executable documentation harness; installation fragments are assembled and parsed as manifests. Identical code is shared across translations. The [full guide](docs/USER_GUIDE.md) distinguishes contextual examples from complete code, and the [fence ledger](docs/contracts/doc-swift-fence-review.tsv) records checker bindings. Passing these checks does not prove device UI behavior.

Use `receive(...)` for effect actions and `receiveOutput(...)` for output.

The manifest above illustrates product selection. For this counter’s app tests, also add your app target to the test dependencies and use `@testable import YourSwiftUIApp` to access `CounterFeature`. The documentation harness compiles the feature and test together in one test target.

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

## Adopt features progressively

- **Level 1:** `Reduce`, `Store`, `@BindableField`, `TestStore`; a counter or form needs no phase graph or run lane.
- **Level 2:** child composition, identified collections, `SelectedStore` and typed ephemeral `Output`. Use `mapOutput(_:)` explicitly; `promoteOutput(to:)` works only for `Never`. `outputs()` is live and non-replaying, so subscribe before dispatch or use `send(_:capturingOutputs:)` for atomic, single-consumer dispatch capture with an explicit buffer policy.
- **Level 3:** `FlowTask`, `withFlowScope`, optional-child lifetime, run admission, `PhaseMap`, diagnostics and Inspector. `.latest`, `.dropWhileRunning` and bounded `.serial(maxPending:)` own Store-local admission; handle rejection. Serial work is not a transaction, retry, rollback or exactly-once guarantee.

For selections, use `select(dependingOn:)` for one slice, `select(dependingOnAll:)` for several, and plain closure selection as the always-refresh fallback. `select(memoize: true)` skips refresh only when the whole Equatable parent snapshot is unchanged; it does not infer a closure's fine-grained dependencies. A semantic `id` must include captured inputs when reusing a live closure projection. Use `optionalState` / `optionalValue` for expired projections or `requireAlive()` for a strict precondition.

`@InnoFlow(phaseManaged: true)` applies `PhaseMap` after reduction and owns its phase key path. Unmatched phase/action pairs are legal no-ops by default. `strictPhaseTotality: true` checks direct phase declarations; `requireComplete(...)` verifies declared sample triggers, not arbitrary predicates or payload domains. `PhaseTransitionGraph` validates topology; it does not own navigation or transport.

## Ownership and lifetimes

Reducers own domain state. The app/coordinator owns concrete navigation stacks, transport/session lifecycle and dependency-graph construction. Inject explicit Sendable dependency bundles; Flow does not supply a DI container, networking client or router. See [dependency patterns](docs/DEPENDENCY_PATTERNS.md) and [cross-framework ownership](docs/CROSS_FRAMEWORK.md).

`Store.send(_:)` returns a `FlowTask` for that dispatch and descendants. `finish()` joins them; `cancel()` cancels only that tree, without rolling back already reduced state. Dropping a handle does not cancel it. `withFlowScope` owns only tracked dispatches. Effect cancellation is cooperative: use `EffectContext` and injected clocks; `ManualTestClock` supports deterministic timing tests.

SwiftUI helpers cover sheet, navigation destination, alert, confirmation dialog and popover where supported; full-screen cover is unavailable on macOS. `innoFlowTask` ties its dispatch to disappearance or ID changes. Inspector and `StoreDiagnostics` are opt-in, bounded and payload-free; do not add domain payloads to diagnostic labels. Rendering, navigation and spatial window/immersive orchestration remain app responsibilities.

## Canonical sample

The [canonical sample](Examples/InnoFlowSampleApp/README.md) has ten demos and consumes this checkout through a local path. Its interactive shell is iOS-first; other platform builds do not imply an immersive sample or full UI parity. [Setup](Examples/SETUP_GUIDE.md).

Use system controls, Dynamic Type, VoiceOver labels and stable `accessibilityIdentifier` values. Smoke tests cover the following identifiers; they are not a full accessibility audit:

`sample.basics`, `sample.orchestration`, `sample.phase-driven-fsm`, `sample.router-composition`, `sample.authentication-flow`, `sample.list-detail-pagination`, `sample.offline-first`, `sample.realtime-stream`, `sample.form-validation`, `sample.bidirectional-websocket`.

## Documentation and choosing Flow

- [Detailed user guide](docs/USER_GUIDE.md), [documentation index and version boundaries](docs/DOCUMENTATION.md)
- [Getting started and API](https://innosquadcorp.github.io/InnoFlow/documentation/innoflow/), [testing API](https://innosquadcorp.github.io/InnoFlow/testing/documentation/innoflowtesting/)
- [Phase modeling](PHASE_DRIVEN_MODELING.md), [SwiftUI platform limits](docs/SWIFTUI_DX_6_0.md), [instrumentation](docs/INSTRUMENTATION_COOKBOOK.md)
- [Architecture contract](ARCHITECTURE_CONTRACT.md), [migration](MIGRATION.md), [macro trust and recovery](docs/MACRO_OPERATIONS.md)
- [AI skill](skills/README.md): exact 6.0.2 consumer baseline; SwiftPM and AI-skill installation are separate.

Choose Flow when a small domain-state boundary and constructor-injected dependencies fit your app. TCA offers a broader integrated application architecture and ecosystem. The [framework comparison](docs/FRAMEWORK_COMPARISON.md) is positioning, not a universal performance claim.

## Development and validation

Use an isolated checkout and Swift 6.3+; see [contributing](CONTRIBUTING.md) and [repository rules](CLAUDE.md). Local static checks, focused tests and consumer fixtures are permitted. The full **28 required** release-preflight checks run only in CI, including four OS 27 runtimes. The four older iOS 18.5 / tvOS 18.5 / watchOS 11.5 / visionOS 2.5 runtime checks are optional and not automatic; their unavailable evidence is not a PASS. Deployment floors remain unchanged. [Release procedure](RELEASING.md).

Swift 6.3 has a documented release-mode compiler workaround in Store/TestStore deinitialization; see [toolchain tracking](docs/SWIFT_TOOLCHAIN_TRACKING.md). A local pass is not a release certificate or all-platform verification.

```bash
./scripts/principle-gates.sh --static
./scripts/check-doc-copyable-examples.rb
python3 skills/innoflow/scripts/validate_consumer.py --scratch-path /tmp/innoflow-skill-validation
```

## Support

[Support](SUPPORT.md) · [Contributing](CONTRIBUTING.md) · [Governance](GOVERNANCE.md) · [Code of conduct](CODE_OF_CONDUCT.md) · [Security](SECURITY.md) · [MIT license](LICENSE).

Support development through [GitHub Sponsors](https://github.com/sponsors/InnoSquadCorp) or [Patreon](https://www.patreon.com/15188938/join).
