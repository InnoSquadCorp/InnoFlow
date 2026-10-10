# InnoFlow

[![Release](https://img.shields.io/github/v/release/InnoSquadCorp/InnoFlow)](https://github.com/InnoSquadCorp/InnoFlow/releases) [![License](https://img.shields.io/github/license/InnoSquadCorp/InnoFlow)](LICENSE) [Swift Package Index](https://swiftpackageindex.com/InnoSquadCorp/InnoFlow) · [CI and public operations](docs/automation-policy.md)

[English](README.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Deutsch](README.de.md) | [简体中文](README.zh-Hans.md) | [日本語](README.ja.md) | [Русский](README.ru.md)

Однонаправленное управление состоянием с ориентацией на SwiftUI для бизнес-переходов и состояния предметной области. Начните с редьюсера, Store и детерминированных тестов; добавляйте оркестрацию по мере необходимости.

## InnoFlow 6.0.2

README описывает **опубликованный API 6.0.2**, выпущенный **2026-10-08** из `1176de1e4783b638c03a9334f43cc49378957148`. [Исходники версии](https://github.com/InnoSquadCorp/InnoFlow/tree/6.0.2) · [Примечания](RELEASE_NOTES.md) · [Миграция](MIGRATION.md).

В ветке разработки есть последующие изменения CI, структуры тестов, проверки и документации. На момент обновления `Sources/` совпадает с 6.0.2; последующие изменения инструментов не опубликованы. В разработке `STABLE_VERSION` равен 6.0.2, а неизменяемый тег сохраняет прежние метаданные кандидата. Размещённый DocC соответствует развёрнутой ревизии; для установленной версии сверяйтесь с тегом. Семь README содержат одинаковое вводное руководство; подробные материалы — на английском.

## Установка

Swift **6.3+**, языковой режим Swift **6**; iOS **18+**, macOS **15+**, tvOS **18+**, watchOS **11+**, visionOS **2+**. Диапазон SwiftSyntax: `>=603.0.0, <605.0.0`; lock-файлы используют 604.0.0. Подбирайте Xcode/SDK под целевую платформу. Заявленные минимумы не доказывают выполнение на каждой старой среде.

Добавьте пакет и явно выберите продукты. `from:` допускает будущие совместимые версии; проверьте реальный `Package.resolved`. Для воспроизведения этого выпуска используйте `exact: "6.0.2"`.

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

| Продукт | Назначение |
| --- | --- |
| `InnoFlowCore` | Runtime без плагина и предусмотренный путь восстановления; без зависимости от SwiftUI. |
| `InnoFlow` | Фасад для макросов, реэкспортирует Core. Для `@InnoFlow` импортируйте напрямую. |
| `InnoFlowSwiftUI` | Необязательные помощники binding, preview, представления и задач view; реэкспортируют Core. |
| `InnoFlowInspector` | Необязательный диагностический UI; зависит только от Core. Предпочтительно подключать под DEBUG. |
| `InnoFlowTesting` | Harness и ручные часы только для тестов; реэкспортируют Core. Не включайте в поставляемые targets. |


## Счётчик

При работе с макросом объявляют вложенные `State`, `Action` и `body`. Третий параметр редьюсера — `Never` без выходных событий или типизированный `Output`. Используйте `Reduce`, `CombineReducers`, `Scope`, `IfLet`, `IfCaseLet`, `ForEachReducer` и `ForEachIdentifiedReducer`. Макрос генерирует `reduce`; обычные публичные компоненты не реализуют его вручную.

Одиночный дочерний payload без метки создаёт `<caseName>CasePath`, случаи коллекций `id:action:` — `CollectionActionPath`. Для неподдерживаемых Action-payload с метками или несколькими значениями объявляйте канонический статический путь внутри `Action`; если путь не нужен или находится в extension, используйте `@InnoFlowCasePathIgnored`.

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

Поместите оба объявления в target приложения. `@BindableField` и `store.binding(\.$step, to:)` — каноническая запись. `send:` и binding с завершающим замыканием поддерживаются без deprecation. `BindableProperty` — низкоуровневое хранилище. Разрешайте `@Environment` во view и внедряйте зависимости в функцию.

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

## Тестирование

По умолчанию `TestStore.exhaustivity` равен `.on`: проверяйте каждое изменение состояния, принимайте все действия эффектов и типизированные выходы, затем вызывайте `await store.finish()`. Отсутствие проверочного замыкания означает отсутствие изменения состояния. `.off` предназначен только для намеренно частичных тестов; ошибки эффектов всё равно приводят к сбою. `assertNoBufferedActions()` проверяет промежуточную очередь; `assertNoMoreActions()` удалён в 6.0.

Счётчик и тест привязаны к исполняемому harness документации; установочные фрагменты собираются и разбираются как manifests. Переводы используют одинаковый код. [Полное руководство](docs/USER_GUIDE.md) различает контекстные примеры и полный код; [реестр блоков](docs/contracts/doc-swift-fence-review.tsv) фиксирует проверяющие инструменты. Успех не доказывает поведение UI на устройстве.

Принимайте действия через `receive(...)`, а выходы через `receiveOutput(...)`.

Manifest выше показывает выбор продуктов. Для тестов счётчика в приложении также добавьте target приложения в зависимости тестов и используйте `@testable import YourSwiftUIApp` для доступа к `CounterFeature`. Harness документации компилирует фичу и тест вместе в одном тестовом target.

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

## Постепенное внедрение

- **Level 1:** `Reduce`, `Store`, `@BindableField`, `TestStore`; счётчику или форме не нужны граф фаз или run lane.
- **Level 2:** композиция дочерних функций, идентифицированные коллекции, `SelectedStore` и типизированный временный `Output`. Явно преобразуйте через `mapOutput(_:)`; `promoteOutput(to:)` доступен только для `Never`. `outputs()` — поток без повторного воспроизведения: подпишитесь до dispatch или примените `send(_:capturingOutputs:)` для атомарного захвата одним потребителем с явной политикой буфера.
- **Level 3:** `FlowTask`, `withFlowScope`, время жизни необязательного ребёнка, допуск выполнения, `PhaseMap`, диагностика и Inspector. `.latest`, `.dropWhileRunning` и ограниченный `.serial(maxPending:)` управляют допуском внутри Store; обрабатывайте отказы. Последовательное выполнение не гарантирует транзакции, повторные попытки, rollback или доставку ровно один раз.

Для одного среза используйте `select(dependingOn:)`, для нескольких — `select(dependingOnAll:)`, обычные замыкания — always-refresh fallback. `select(memoize: true)` пропускает обновление только при неизменном полном Equatable-снимке родителя; мелкие зависимости замыкания не выводятся. Семантический `id` для повторного использования живой проекции должен включать захваченные входы. Для истёкших проекций используйте `optionalState` / `optionalValue`, для строгой предпосылки — `requireAlive()`.

`@InnoFlow(phaseManaged: true)` применяет `PhaseMap` после reduction и владеет key path фазы. Несовпадающие пары phase/action по умолчанию допустимы как no-op. `strictPhaseTotality: true` проверяет прямые объявления фаз; `requireComplete(...)` — объявленные примерные триггеры, а не произвольные предикаты или все области payload. `PhaseTransitionGraph` проверяет топологию, не управляет навигацией или транспортом.

## Ответственность и время жизни

Редьюсеры владеют состоянием предметной области. App/coordinator владеет конкретными стеками навигации, жизненным циклом транспорта/сессии и построением графа зависимостей. Явно внедряйте Sendable-bundles; Flow не предоставляет DI-контейнер, сетевой клиент или router. См. [шаблоны зависимостей](docs/DEPENDENCY_PATTERNS.md) и [границы frameworks](docs/CROSS_FRAMEWORK.md).

`Store.send(_:)` возвращает `FlowTask` для dispatch и его потомков. `finish()` ожидает завершения; `cancel()` отменяет только это дерево без отката уже применённого состояния. Потеря handle не отменяет работу. `withFlowScope` владеет только отслеживаемыми dispatch. Отмена эффектов кооперативна: используйте `EffectContext` и внедрённые часы; `ManualTestClock` поддерживает детерминированные временные тесты.

Помощники SwiftUI поддерживают sheet, navigation destination, alert, confirmation dialog и доступные popover; full-screen cover отсутствует на macOS. `innoFlowTask` связывает dispatch с исчезновением view или изменением ID. Inspector и `StoreDiagnostics` необязательны, ограничены и не содержат payload; не добавляйте данные предметной области в диагностические метки. Рендеринг, навигация, пространственные окна и immersive-оркестрация остаются задачами приложения.

## Канонический пример

[Канонический пример](Examples/InnoFlowSampleApp/README.md) содержит десять демо и использует текущий checkout по локальному пути. Интерактивная оболочка ориентирована на iOS; сборки других платформ не означают immersive-пример или полную UI-паритетность. [Настройка](Examples/SETUP_GUIDE.md).

Используйте системные элементы, Dynamic Type, метки VoiceOver и стабильные `accessibilityIdentifier`. Smoke-тесты охватывают следующие ID и не являются полным аудитом доступности:

`sample.basics`, `sample.orchestration`, `sample.phase-driven-fsm`, `sample.router-composition`, `sample.authentication-flow`, `sample.list-detail-pagination`, `sample.offline-first`, `sample.realtime-stream`, `sample.form-validation`, `sample.bidirectional-websocket`.

## Документация и выбор Flow

- [Подробное руководство](docs/USER_GUIDE.md), [индекс и границы версий](docs/DOCUMENTATION.md)
- [Начало и API](https://innosquadcorp.github.io/InnoFlow/documentation/innoflow/), [API тестов](https://innosquadcorp.github.io/InnoFlow/testing/documentation/innoflowtesting/)
- [Моделирование фаз](PHASE_DRIVEN_MODELING.md), [ограничения SwiftUI](docs/SWIFTUI_DX_6_0.md), [инструментирование](docs/INSTRUMENTATION_COOKBOOK.md)
- [Архитектурный контракт](ARCHITECTURE_CONTRACT.md), [миграция](MIGRATION.md), [доверие к макросам и восстановление](docs/MACRO_OPERATIONS.md)
- [AI skill](skills/README.md): точная база consumer 6.0.2; установка SwiftPM и skill выполняются отдельно.

Выбирайте Flow, когда приложению подходят небольшая граница доменного состояния и внедрение через конструктор. TCA предлагает более широкую интегрированную архитектуру и экосистему. [Сравнение](docs/FRAMEWORK_COMPARISON.md) описывает позиционирование, а не универсальное превосходство в производительности.

## Разработка и проверки

Используйте изолированный checkout и Swift 6.3+; см. [участие](CONTRIBUTING.md) и [правила](CLAUDE.md). Разрешены локальные статические проверки, целевые тесты и consumer-fixtures. Все **28 обязательных** release-preflight проверок выполняются только в CI, включая четыре среды OS 27. Старые iOS 18.5 / tvOS 18.5 / watchOS 11.5 / visionOS 2.5 необязательны и не запускаются автоматически; недоступные свидетельства — не PASS. Минимумы развёртывания неизменны. [Процедура](RELEASING.md).

Swift 6.3 требует документированного обхода ошибки компилятора в release-deinit Store/TestStore; см. [отслеживание toolchain](docs/SWIFT_TOOLCHAIN_TRACKING.md). Локальный успех не сертифицирует выпуск или все платформы.

```bash
./scripts/principle-gates.sh --static
./scripts/check-doc-copyable-examples.rb
python3 skills/innoflow/scripts/validate_consumer.py --scratch-path /tmp/innoflow-skill-validation
```

## Поддержка

[Поддержка](SUPPORT.md) · [Участие](CONTRIBUTING.md) · [Управление](GOVERNANCE.md) · [Кодекс поведения](CODE_OF_CONDUCT.md) · [Безопасность](SECURITY.md) · [Лицензия MIT](LICENSE).

Поддержите разработку через [GitHub Sponsors](https://github.com/sponsors/InnoSquadCorp) или [Patreon](https://www.patreon.com/15188938/join).
