# InnoFlow

[![Release](https://img.shields.io/github/v/release/InnoSquadCorp/InnoFlow)](https://github.com/InnoSquadCorp/InnoFlow/releases) [![License](https://img.shields.io/github/license/InnoSquadCorp/InnoFlow)](LICENSE) [Swift Package Index](https://swiftpackageindex.com/InnoSquadCorp/InnoFlow) · [CI and public operations](docs/automation-policy.md)

[English](README.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Deutsch](README.de.md) | [简体中文](README.zh-Hans.md) | [日本語](README.ja.md) | [Русский](README.ru.md)

SwiftUI-orientierte unidirektionale Zustandsverwaltung für Geschäfts- und Domänenübergänge. Beginne mit Reducer, Store und deterministischen Tests; ergänze Orchestrierung, sobald dein Feature sie braucht.

## InnoFlow 6.0.2

Diese README beschreibt die **veröffentlichte API von 6.0.2**, erschienen am **2026-10-08** aus `1176de1e4783b638c03a9334f43cc49378957148`. [Versionierter Quellcode](https://github.com/InnoSquadCorp/InnoFlow/tree/6.0.2) · [Release Notes](RELEASE_NOTES.md) · [Migration](MIGRATION.md).

Der Entwicklungsbranch enthält spätere Änderungen an CI, Teststruktur, Validierung und Dokumentation. Bei dieser Aktualisierung entspricht `Sources/` 6.0.2; spätere Werkzeugänderungen sind unveröffentlicht. `STABLE_VERSION` ist dort 6.0.2; der unveränderliche Tag bewahrt seine damaligen Kandidatenmetadaten. Gehostetes DocC folgt der bereitgestellten Revision; prüfe installierte Versionen anhand des Tags. Alle sieben READMEs behandeln denselben Einstieg; ausführliche Leitfäden sind auf Englisch.

## Installation

Swift **6.3+**, Swift-Sprachmodus **6**; iOS **18+**, macOS **15+**, tvOS **18+**, watchOS **11+**, visionOS **2+**. SwiftSyntax benötigt `>=603.0.0, <605.0.0`; die Lockdateien verwenden 604.0.0. Wähle Xcode/SDK passend zum Ziel. Deklarierte Mindestversionen beweisen keine Ausführung auf jeder älteren Runtime.

Füge das Paket hinzu und wähle Produkte ausdrücklich. `from:` erlaubt spätere kompatible Versionen; prüfe die tatsächliche `Package.resolved`. Verwende `exact: "6.0.2"` zur Reproduktion dieses Releases.

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

| Produkt | Zweck |
| --- | --- |
| `InnoFlowCore` | Runtime ohne Plugin und bewusster Wiederherstellungspfad; keine SwiftUI-Abhängigkeit. |
| `InnoFlow` | Fassade für Makros; exportiert Core erneut. Für `@InnoFlow` direkt importieren. |
| `InnoFlowSwiftUI` | Optionale Binding-, Preview-, Präsentations- und View-Task-Helfer; exportiert Core erneut. |
| `InnoFlowInspector` | Optionale Diagnose-UI, nur von Core abhängig. Vorzugsweise unter DEBUG einbinden. |
| `InnoFlowTesting` | Test-Harness und manuelle Uhr; exportiert Core erneut. Nicht in ausgelieferte Targets aufnehmen. |


## Zähler-Feature

Makronutzer deklarieren verschachtelte `State`, `Action` und `body`. Der dritte Reducer-Typparameter ist ohne Ausgabe `Never`, sonst das typisierte `Output`. Komposition erfolgt über `Reduce`, `CombineReducers`, `Scope`, `IfLet`, `IfCaseLet`, `ForEachReducer` und `ForEachIdentifiedReducer`. Das Makro erzeugt `reduce`; gewöhnliche öffentliche Features implementieren es nicht von Hand.

Einzelne unbeschriftete Kind-Payloads erzeugen `<caseName>CasePath`, Collection-Fälle `id:action:` erzeugen `CollectionActionPath`. Bei nicht unterstützten beschrifteten/mehrfachen Action-Payloads den kanonischen statischen Pfad in `Action` deklarieren; `@InnoFlowCasePathIgnored` verwenden, wenn kein Pfad nötig ist oder er in einer Extension liegt.

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

Lege beide Deklarationen im App-Target ab. `@BindableField` und `store.binding(\.$step, to:)` sind kanonisch. `send:` und Bindings mit abschließender Closure bleiben ohne Deprecation unterstützt. `BindableProperty` ist ein Speichertyp der unteren Ebene. Löse `@Environment` in der View auf und injiziere Abhängigkeiten in das Feature.

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

## Tests

`TestStore.exhaustivity` steht standardmäßig auf `.on`: jede Zustandsänderung prüfen, jede Effektaktion und typisierte Ausgabe empfangen, dann `await store.finish()` aufrufen. Eine fehlende Assertion-Closure bedeutet keine Zustandsänderung. `.off` ist nur für bewusst partielle Tests; Laufzeitfehler von Effekten bleiben Fehler. `assertNoBufferedActions()` prüft die Queue zwischendurch; `assertNoMoreActions()` wurde in 6.0 entfernt.

Zähler und Test sind an den ausführbaren Dokumentations-Harness gebunden; Installationsfragmente werden als Manifeste zusammengesetzt und geparst. Übersetzungen teilen identischen Code. Der [vollständige Leitfaden](docs/USER_GUIDE.md) trennt kontextabhängige Beispiele von vollständigem Code; das [Register](docs/contracts/doc-swift-fence-review.tsv) bindet Codeblöcke an Prüfer. Ein erfolgreicher Lauf beweist kein Geräte-UI-Verhalten.

Effektaktionen mit `receive(...)`, Ausgaben mit `receiveOutput(...)` empfangen.

Das Manifest oben zeigt die Produktauswahl. Für App-Tests dieses Zählers ergänze das App-Target als Testabhängigkeit und verwende `@testable import YourSwiftUIApp`, um auf `CounterFeature` zuzugreifen. Der Dokumentations-Harness kompiliert Feature und Test gemeinsam in einem Test-Target.

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

## Schrittweise Einführung

- **Level 1:** `Reduce`, `Store`, `@BindableField`, `TestStore`; Zähler und Formulare benötigen weder Phasengraph noch Run-Lane.
- **Level 2:** Kindkomposition, identifizierte Collections, `SelectedStore` und typisiertes kurzlebiges `Output`. Mit `mapOutput(_:)` ausdrücklich abbilden; `promoteOutput(to:)` funktioniert nur für `Never`. `outputs()` ist live und ohne Replay: vor dem Dispatch abonnieren oder `send(_:capturingOutputs:)` für atomare Erfassung mit einem Verbraucher und expliziter Pufferregel verwenden.
- **Level 3:** `FlowTask`, `withFlowScope`, Lebensdauer optionaler Kinder, Zulassung, `PhaseMap`, Diagnosen und Inspector. `.latest`, `.dropWhileRunning` und begrenztes `.serial(maxPending:)` verwalten die Store-lokale Zulassung; Ablehnungen behandeln. Serielle Ausführung garantiert weder Transaktionen, Wiederholungen, Rollback noch genau einmalige Zustellung.

Verwende `select(dependingOn:)` für einen Ausschnitt, `select(dependingOnAll:)` für mehrere und einfache Closures als always-refresh fallback. `select(memoize: true)` überspringt Aktualisierung nur bei unverändertem vollständigem Equatable-Elternsnapshot; feine Closure-Abhängigkeiten werden nicht erschlossen. Eine semantische `id` muss erfasste Eingaben für die Wiederverwendung einer lebenden Projektion enthalten. Für abgelaufene Projektionen nutze `optionalState` / `optionalValue`, für strikte Vorbedingungen `requireAlive()`.

`@InnoFlow(phaseManaged: true)` wendet `PhaseMap` nach der Reduktion an und besitzt den Phasen-Key-Path. Nicht passende Phase/Aktion-Paare sind standardmäßig erlaubte No-ops. `strictPhaseTotality: true` prüft direkte Deklarationen; `requireComplete(...)` prüft deklarierte Beispieltrigger, keine beliebigen Prädikate oder vollständigen Payload-Domänen. `PhaseTransitionGraph` validiert Topologie, nicht Navigation oder Transport.

## Verantwortung und Lebensdauer

Reducer besitzen den Domänenzustand. App/Coordinator besitzen konkrete Navigationsstapel, Transport-/Sitzungslebensdauer und Aufbau des Abhängigkeitsgraphen. Injiziere explizite Sendable-Bundles; Flow liefert weder DI-Container noch Netzwerkclient oder Router. Siehe [Abhängigkeiten](docs/DEPENDENCY_PATTERNS.md) und [Framework-Grenzen](docs/CROSS_FRAMEWORK.md).

`Store.send(_:)` liefert einen `FlowTask` für diesen Dispatch und seine Nachkommen. `finish()` wartet; `cancel()` beendet nur diesen Baum, ohne bereits reduzierten Zustand zurückzusetzen. Verwerfen des Handles ist keine Stornierung. `withFlowScope` besitzt nur registrierte Dispatches. Effektstornierung ist kooperativ: verwende `EffectContext` und injizierte Uhren; `ManualTestClock` ermöglicht deterministische Zeittests.

SwiftUI-Helfer umfassen Sheet, Navigation Destination, Alert, Confirmation Dialog und unterstützte Popover; Full-Screen Cover gibt es auf macOS nicht. `innoFlowTask` bindet seinen Dispatch an Verschwinden oder ID-Wechsel. Inspector und `StoreDiagnostics` sind optional, begrenzt und payloadfrei; keine Domänenpayloads in Diagnoselabels aufnehmen. Rendering, Navigation und räumliche Fenster-/Immersive-Orchestrierung bleiben App-Aufgaben.

## Kanonisches Beispiel

Die [kanonische Beispiel-App](Examples/InnoFlowSampleApp/README.md) enthält zehn Demos und nutzt diesen Checkout über einen lokalen Pfad. Ihre interaktive Oberfläche ist iOS-orientiert; andere Plattformbuilds bedeuten weder immersive Beispiele noch vollständige UI-Parität. [Einrichtung](Examples/SETUP_GUIDE.md).

Nutze Systemsteuerelemente, Dynamic Type, VoiceOver-Labels und stabile `accessibilityIdentifier`. Smoke-Tests prüfen diese IDs; sie sind kein vollständiges Barrierefreiheitsaudit:

`sample.basics`, `sample.orchestration`, `sample.phase-driven-fsm`, `sample.router-composition`, `sample.authentication-flow`, `sample.list-detail-pagination`, `sample.offline-first`, `sample.realtime-stream`, `sample.form-validation`, `sample.bidirectional-websocket`.

## Dokumentation und Wahl von Flow

- [Ausführlicher Leitfaden](docs/USER_GUIDE.md), [Dokumentationsindex und Versionsgrenzen](docs/DOCUMENTATION.md)
- [Einstieg und API](https://innosquadcorp.github.io/InnoFlow/documentation/innoflow/), [Test-API](https://innosquadcorp.github.io/InnoFlow/testing/documentation/innoflowtesting/)
- [Phasenmodellierung](PHASE_DRIVEN_MODELING.md), [SwiftUI-Grenzen](docs/SWIFTUI_DX_6_0.md), [Instrumentierung](docs/INSTRUMENTATION_COOKBOOK.md)
- [Architekturvertrag](ARCHITECTURE_CONTRACT.md), [Migration](MIGRATION.md), [Makrovertrauen und Wiederherstellung](docs/MACRO_OPERATIONS.md)
- [KI-Skill](skills/README.md): exakter 6.0.2-Consumer; SwiftPM- und Skill-Installation sind getrennt.

Wähle Flow, wenn eine kleine Domänenzustandsgrenze und Konstruktorinjektion zur App passen. TCA bietet eine breitere integrierte App-Architektur und ein größeres Ökosystem. Der [Vergleich](docs/FRAMEWORK_COMPARISON.md) beschreibt Positionierung, keine allgemeingültige Leistungsüberlegenheit.

## Entwicklung und Validierung

Nutze einen isolierten Checkout und Swift 6.3+; siehe [Mitwirken](CONTRIBUTING.md) und [Regeln](CLAUDE.md). Lokale statische Prüfungen, gezielte Tests und Consumer-Fixtures sind erlaubt. Alle **28 erforderlichen** Release-Preflight-Prüfungen laufen ausschließlich in CI, einschließlich vier OS 27-Runtimes. Die älteren iOS 18.5 / tvOS 18.5 / watchOS 11.5 / visionOS 2.5 sind optional und nicht automatisch; fehlende Nachweise sind kein PASS. Mindestversionen bleiben unverändert. [Release-Verfahren](RELEASING.md).

Swift 6.3 benötigt einen dokumentierten Compiler-Workaround im Release-deinit von Store/TestStore; siehe [Toolchain-Verfolgung](docs/SWIFT_TOOLCHAIN_TRACKING.md). Lokaler Erfolg zertifiziert weder das Release noch alle Plattformen.

```bash
./scripts/principle-gates.sh --static
./scripts/check-doc-copyable-examples.rb
python3 skills/innoflow/scripts/validate_consumer.py --scratch-path /tmp/innoflow-skill-validation
```

## Support

[Support](SUPPORT.md) · [Mitwirken](CONTRIBUTING.md) · [Governance](GOVERNANCE.md) · [Verhaltenskodex](CODE_OF_CONDUCT.md) · [Sicherheit](SECURITY.md) · [MIT-Lizenz](LICENSE).

Unterstütze die Entwicklung über [GitHub Sponsors](https://github.com/sponsors/InnoSquadCorp) oder [Patreon](https://www.patreon.com/15188938/join).
