# InnoFlow

[![Release](https://img.shields.io/github/v/release/InnoSquadCorp/InnoFlow)](https://github.com/InnoSquadCorp/InnoFlow/releases) [![License](https://img.shields.io/github/license/InnoSquadCorp/InnoFlow)](LICENSE) [Swift Package Index](https://swiftpackageindex.com/InnoSquadCorp/InnoFlow) · [CI and public operations](docs/automation-policy.md)

[English](README.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Deutsch](README.de.md) | [简体中文](README.zh-Hans.md) | [日本語](README.ja.md) | [Русский](README.ru.md)

Gestión de estado unidireccional centrada en SwiftUI para transiciones de negocio y dominio. Empieza con un reductor, un Store y pruebas deterministas; añade orquestación cuando la función lo necesite.

## InnoFlow 6.0.2

Este README describe la **API publicada de 6.0.2**, lanzada el **2026-10-08** desde `1176de1e4783b638c03a9334f43cc49378957148`. [Código de la versión](https://github.com/InnoSquadCorp/InnoFlow/tree/6.0.2) · [Notas](RELEASE_NOTES.md) · [Migración](MIGRATION.md).

La rama de desarrollo incluye cambios posteriores de CI, organización de pruebas, validación y documentación. En esta revisión, `Sources/` coincide con 6.0.2; los cambios posteriores de herramientas no están publicados. `STABLE_VERSION` es 6.0.2 en desarrollo; la etiqueta inmutable conserva sus metadatos de candidato. DocC alojado sigue la revisión desplegada: consulta el código etiquetado para tu versión instalada. Los siete README ofrecen la misma guía inicial; las guías detalladas están en inglés.

## Instalación

Swift **6.3+**, modo de lenguaje Swift **6**; iOS **18+**, macOS **15+**, tvOS **18+**, watchOS **11+**, visionOS **2+**. SwiftSyntax requiere `>=603.0.0, <605.0.0`; los archivos de bloqueo usan 604.0.0. Elige Xcode/SDK para tu destino. Los mínimos declarados no prueban que se hayan ejecutado todos los runtimes antiguos.

Añade el paquete y selecciona los productos explícitamente. `from:` permite versiones futuras compatibles; revisa el `Package.resolved` real. Usa `exact: "6.0.2"` para reproducir esta versión.

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

| Producto | Uso |
| --- | --- |
| `InnoFlowCore` | Runtime sin plugin y vía de recuperación deliberada; sin dependencia de SwiftUI. |
| `InnoFlow` | Fachada de autoría con macros; reexporta Core. Importa directamente para `@InnoFlow`. |
| `InnoFlowSwiftUI` | Ayudas opcionales de binding, previews, presentación y tareas de vista; reexporta Core. |
| `InnoFlowInspector` | UI de diagnóstico opcional; solo depende de Core. Preferible bajo DEBUG. |
| `InnoFlowTesting` | Harness y reloj manual solo para pruebas; reexporta Core. Excluir de los targets distribuidos. |


## Contador

Con macros se declaran `State`, `Action` y `body` anidados. El tercer genérico es `Never` sin salida, o el `Output` tipado. Compón con `Reduce`, `CombineReducers`, `Scope`, `IfLet`, `IfCaseLet`, `ForEachReducer` y `ForEachIdentifiedReducer`. La macro genera `reduce`; las funciones públicas habituales no lo implementan manualmente.

Los payloads hijos únicos sin etiqueta generan `<caseName>CasePath`; los casos de colección `id:action:` generan `CollectionActionPath`. Para payloads Action etiquetados o múltiples no admitidos, declara la ruta estática canónica en `Action`, o usa `@InnoFlowCasePathIgnored` si no se necesita o está en una extensión.

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

Coloca ambas declaraciones en el target de la app. `@BindableField` y `store.binding(\.$step, to:)` son la forma canónica. `send:` y los bindings con closure final siguen admitidos sin deprecación. `BindableProperty` es almacenamiento de bajo nivel. Resuelve `@Environment` en la vista e inyecta dependencias en la función.

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

## Pruebas

`TestStore.exhaustivity` vale `.on` por defecto: comprueba cada cambio de estado, recibe cada acción de efecto y salida tipada, y llama a `await store.finish()`. Omitir el closure significa que el estado no cambia. Usa `.off` solo para pruebas parciales intencionadas; los errores de efectos siguen fallando. `assertNoBufferedActions()` comprueba una cola intermedia; `assertNoMoreActions()` se eliminó en 6.0.

El contador y la prueba están vinculados al harness ejecutable de documentación; los fragmentos de instalación se ensamblan y analizan como manifests. Las traducciones comparten código idéntico. La [guía completa](docs/USER_GUIDE.md) distingue ejemplos contextuales y completos; el [registro](docs/contracts/doc-swift-fence-review.tsv) vincula bloques con verificadores. Superarlos no demuestra el comportamiento de UI en dispositivos.

Recibe acciones con `receive(...)` y salidas con `receiveOutput(...)`.

El manifest anterior ilustra la selección de productos. Para probar este contador en la app, añade también el target de la app a las dependencias de test y usa `@testable import YourSwiftUIApp` para acceder a `CounterFeature`. El harness compila la funcionalidad y el test juntos en un target de pruebas.

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

## Adopción progresiva

- **Level 1:** `Reduce`, `Store`, `@BindableField`, `TestStore`; un contador o formulario no necesita grafos de fases ni lanes.
- **Level 2:** composición de hijos, colecciones identificadas, `SelectedStore` y `Output` efímero tipado. Convierte con `mapOutput(_:)`; `promoteOutput(to:)` solo admite `Never`. `outputs()` es en vivo y no reproduce eventos: suscríbete antes del dispatch o usa `send(_:capturingOutputs:)` para captura atómica de un consumidor con política de buffer explícita.
- **Level 3:** `FlowTask`, `withFlowScope`, vida de hijos opcionales, admisión, `PhaseMap`, diagnósticos e Inspector. `.latest`, `.dropWhileRunning` y `.serial(maxPending:)` limitada gestionan admisión local al Store; maneja rechazos. La ejecución serial no garantiza transacciones, reintentos, rollback ni entrega exactamente una vez.

Usa `select(dependingOn:)` para una parte, `select(dependingOnAll:)` para varias y closures simples como always-refresh fallback. `select(memoize: true)` omite refrescos solo si no cambia toda la instantánea Equatable del padre; no infiere dependencias finas. Un `id` semántico debe incluir entradas capturadas al reutilizar una proyección viva. Para proyecciones caducadas usa `optionalState` / `optionalValue`, o `requireAlive()` como precondición estricta.

`@InnoFlow(phaseManaged: true)` aplica `PhaseMap` tras reducir y controla su key path de fase. Los pares fase/acción sin coincidencia son no-ops legales por defecto. `strictPhaseTotality: true` comprueba declaraciones directas; `requireComplete(...)` valida triggers de ejemplo declarados, no predicados arbitrarios ni dominios completos de payload. `PhaseTransitionGraph` valida topología, no navegación ni transporte.

## Propiedad y ciclos de vida

Los reductores poseen el estado de dominio. La app/coordinador posee pilas de navegación, transporte/sesión y construcción del grafo de dependencias. Inyecta bundles Sendable explícitos; Flow no proporciona contenedor DI, cliente de red ni router. Consulta [patrones de dependencias](docs/DEPENDENCY_PATTERNS.md) y [límites entre frameworks](docs/CROSS_FRAMEWORK.md).

`Store.send(_:)` devuelve `FlowTask` para ese dispatch y sus descendientes. `finish()` espera; `cancel()` cancela solo ese árbol sin deshacer estado ya reducido. Descartar el handle no cancela. `withFlowScope` posee solo dispatches registrados. La cancelación es cooperativa: usa `EffectContext` y relojes inyectados; `ManualTestClock` permite pruebas de tiempo deterministas.

Las ayudas SwiftUI cubren sheet, navigation destination, alert, confirmation dialog y popover donde exista; full-screen cover no está disponible en macOS. `innoFlowTask` vincula el dispatch a desaparición o cambio de ID. Inspector y `StoreDiagnostics` son opcionales, limitados y sin payload; no añadas payload de dominio a etiquetas diagnósticas. Renderizado, navegación y orquestación de ventanas/espacios inmersivos pertenecen a la app.

## Ejemplo canónico

La [app de ejemplo canónica](Examples/InnoFlowSampleApp/README.md) tiene diez demos y usa este checkout por ruta local. Su shell interactivo prioriza iOS; compilar otras plataformas no implica un ejemplo inmersivo ni paridad total de UI. [Configuración](Examples/SETUP_GUIDE.md).

Usa controles del sistema, Dynamic Type, etiquetas VoiceOver y `accessibilityIdentifier` estables. Las pruebas smoke cubren estos identificadores, no una auditoría completa de accesibilidad:

`sample.basics`, `sample.orchestration`, `sample.phase-driven-fsm`, `sample.router-composition`, `sample.authentication-flow`, `sample.list-detail-pagination`, `sample.offline-first`, `sample.realtime-stream`, `sample.form-validation`, `sample.bidirectional-websocket`.

## Documentación y elección de Flow

- [Guía detallada](docs/USER_GUIDE.md), [índice y límites de versión](docs/DOCUMENTATION.md)
- [Inicio y API](https://innosquadcorp.github.io/InnoFlow/documentation/innoflow/), [API de pruebas](https://innosquadcorp.github.io/InnoFlow/testing/documentation/innoflowtesting/)
- [Modelado de fases](PHASE_DRIVEN_MODELING.md), [límites SwiftUI](docs/SWIFTUI_DX_6_0.md), [instrumentación](docs/INSTRUMENTATION_COOKBOOK.md)
- [Contrato de arquitectura](ARCHITECTURE_CONTRACT.md), [migración](MIGRATION.md), [confianza y recuperación de macros](docs/MACRO_OPERATIONS.md)
- [Skill de IA](skills/README.md): baseline exacta 6.0.2; instalar SwiftPM y el skill son pasos distintos.

Elige Flow cuando encajen un límite pequeño de estado de dominio y dependencias por constructor. TCA ofrece una arquitectura integrada y un ecosistema más amplios. La [comparación](docs/FRAMEWORK_COMPARISON.md) describe posicionamiento, no rendimiento universal.

## Desarrollo y validación

Usa un checkout aislado y Swift 6.3+; consulta [contribuciones](CONTRIBUTING.md) y [reglas](CLAUDE.md). Se permiten controles estáticos locales, pruebas focalizadas y fixtures consumidores. Los **28 controles obligatorios** del preflight de release se ejecutan solo en CI, incluidos cuatro runtimes OS 27. Los antiguos iOS 18.5 / tvOS 18.5 / watchOS 11.5 / visionOS 2.5 son opcionales y no automáticos; evidencia no disponible no equivale a PASS. Los mínimos de despliegue no cambian. [Procedimiento](RELEASING.md).

Swift 6.3 necesita un workaround documentado del compilador en deinit de Store/TestStore en release; consulta [seguimiento](docs/SWIFT_TOOLCHAIN_TRACKING.md). Pasar localmente no certifica la release ni todas las plataformas.

```bash
./scripts/principle-gates.sh --static
./scripts/check-doc-copyable-examples.rb
python3 skills/innoflow/scripts/validate_consumer.py --scratch-path /tmp/innoflow-skill-validation
```

## Soporte

[Soporte](SUPPORT.md) · [Contribuciones](CONTRIBUTING.md) · [Gobernanza](GOVERNANCE.md) · [Código de conducta](CODE_OF_CONDUCT.md) · [Seguridad](SECURITY.md) · [Licencia MIT](LICENSE).

Apoya el desarrollo en [GitHub Sponsors](https://github.com/sponsors/InnoSquadCorp) o [Patreon](https://www.patreon.com/15188938/join).
