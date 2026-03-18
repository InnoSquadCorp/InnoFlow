# Getting Started

Create a feature with `@InnoFlow`, expose reducer composition from `body`, hold it in a ``Store``, and send actions from SwiftUI.

```swift
import InnoFlow
import SwiftUI

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

struct CounterView: View {
  @State private var store = Store(reducer: CounterFeature())

  var body: some View {
    VStack {
      Text("Count: \(store.count)")
      Button("+") { store.send(.increment) }
      Button("−") { store.send(.decrement) }
      Stepper("Step: \(store.step)", value: store.binding(\.$step, send: Action.setStep))
    }
  }
}
```

For multi-part features, compose reducers with ``Reduce``, ``CombineReducers``, ``Scope``, ``IfLet``, ``IfCaseLet``, and ``ForEachReducer`` instead of adding more authoring modes.
Use `@BindableField` for reducer-facing value fields, and pass the projected key path (`\.$field`) into ``Store/binding(_:send:)``.

- Use ``Scope`` when child state is always present.
- Use ``IfLet`` when child state is optional.
- Use ``IfCaseLet`` when child state lives behind an enum case.
- Use ``ForEachReducer`` when child state is a collection of `Identifiable` rows.
- Use ``SelectedStore`` when a view needs a read-only derived value that should refresh only when the selected `Equatable` output changes. Prefer `select(dependingOn:..., transform:)` when that value comes from one to three explicit state slices, and keep plain `select { ... }` for always-refresh fallback cases where the dependency cannot be expressed as one to three key paths.

If a feature needs constructor-time services, define an explicit nested `Dependencies` bundle and
pass it from the app/coordinator layer instead of relying on reducer-side global lookup. That keeps
dependency ownership outside `InnoFlow` while making reducer dependencies explicit and testable.

For domain phases, prefer `PhaseMap` as the canonical phase-transition layer and keep graph
validation explicit through `phaseMap.derivedGraph`; see <doc:PhaseDrivenModeling>. Prefer
`CasePath`-based `On(...)` rules first, `Equatable` actions second, and reserve `On(where:)` for
escape-hatch cases where the trigger cannot be expressed more directly.
When you want a full end-to-end sample that covers `Store`, row projections, and `TestStore`, continue with <doc:PhaseDrivenWalkthrough>.

For store-level debounce or throttle tests, inject `StoreClock.manual(...)` instead of relying on wall-clock delays. New `.run` effects should prefer `EffectContext.sleep(for:)` and `EffectContext.checkCancellation()` over `Task.sleep(...)` plus ad-hoc cancellation checks so the same store clock controls both scheduling operators and effect delays. Cancellation remains cooperative: InnoFlow drops late emissions for cancelled or released stores immediately, while runtime teardown continues as best-effort async cleanup. Long-running work should still probe `checkCancellation()` if it needs prompt shutdown.

For SwiftUI previews, use `Store.preview(...)` so preview-only setup stays explicit without changing
production store semantics.

For accessibility, keep stable `accessibilityIdentifier(...)` values on tested controls, add
explicit VoiceOver labels or hints when dense layouts are not self-explanatory, and prefer system
controls with Dynamic Type-friendly sizing over fixed custom chrome.

visionOS follows the same state-ownership rules as the rest of InnoFlow: reducers own business
transitions, while scene, window, and immersive-space orchestration stays in the app layer. See
<doc:VisionOSIntegration>.
