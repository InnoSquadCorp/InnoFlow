# InnoFlow Release Notes

## Unreleased Release Hardening

This hardening pass removes retired evaluation artifacts, tightens the public
surface around reducer builders and effect cancellation, raises supported
platform floors for Swift 6.0 modernization, and makes canonical sample
validation stricter. It also finalizes the 4.0.0 public split between the core
`InnoFlow` product and the SwiftUI integration product `InnoFlowSwiftUI`.

### Changed

1. Removed public underscored reducer-builder implementation wrappers from the
   supported API surface. Public feature authoring remains
   `var body: some Reducer<State, Action>` composed from `Reduce`,
   `CombineReducers`, `Scope`, and the other public reducer combinators.
2. Moved SwiftUI-only helpers into `InnoFlowSwiftUI`: `Store.binding`,
   `ScopedStore.binding`, `Store.preview`, and
   `EffectTask.animation(Animation?)`. SwiftUI apps should depend on both
   `InnoFlow` and `InnoFlowSwiftUI`; non-UI feature/domain targets can depend
   on `InnoFlow` alone.
3. Removed `EffectContext.isCancelled`; effects should use
   `try await context.checkCancellation()` or the async
   `await context.isCancellationRequested()` probe.
4. Raised root and canonical sample package floors to iOS 18, macOS 15,
   tvOS 18, watchOS 11, and visionOS 2 (Swift 6.0 standard library) so the
   framework can adopt typed throws, `sending` parameters, and other Swift
   6.0 modernization without availability branches. Apps that still need
   iOS 17 / macOS 14 support must stay on 3.x.
5. Removed the sample package's compiled `InnoNetworkWebSocket` dependency and
   kept concrete transport integration as a non-compiled app-boundary snippet.
6. Enabled the Swift 6 package contract, pinned `swift-syntax` exactly to
   `603.0.1`, added a ThreadSanitizer CI job, and hardened principle gates so
   README core patterns, core SwiftUI-import boundaries, and Swift macro/plugin
   diagnostic corruption cannot drift silently.
7. Added OSS contribution templates for security reports, conduct, issues, and
   pull requests.
8. Hardened effect cancellation so non-awaited `.merge` / `.concatenate`
   wrapper tasks are tracked and cancelled with their store boundary.
9. Preserved every active cancellation boundary through nested `.cancellable`
   wrappers so cancelling an outer id also reaches already-started inner runs.
10. Shared cancellation-boundary sequencing between `Store` and `TestStore`,
   including idempotent finish accounting for cancelled in-flight tokens.
11. Tightened phase-managed macro diagnostics so unrelated member accesses in a
    `phaseMap` body no longer suppress missing-phase warnings.
12. Reduced collection hot-path overhead in `ForEachReducer` and
    collection-scoped store cache pruning.
13. Enabled tag-triggered release gates to run principle validation with release
    tag enforcement.

### Known toolchain workarounds

`Store.deinit` and `TestStore.deinit` keep the `@_optimize(none)` attribute
that sidesteps the Swift 6.3 `EarlyPerfInliner` crash
([swiftlang/swift#88173](https://github.com/swiftlang/swift/issues/88173)). The
attribute affects the deinit path only — not effect execution or action
dispatch — and is tracked in
[`docs/SWIFT_TOOLCHAIN_TRACKING.md`](docs/SWIFT_TOOLCHAIN_TRACKING.md) along
with the retest steps and the gate that warns on Swift 6.4+.

## Migration Note

### What changed

- Direct references to `_EmptyReducer`, `_ReducerSequence`, `_OptionalReducer`,
  `_ConditionalReducer`, or `_ArrayReducer` are no longer supported.
- SwiftUI binding, preview, and animation helpers are imported from
  `InnoFlowSwiftUI` instead of the core `InnoFlow` target.
- Cancellation is checked through the async runtime boundary instead of a
  synchronous boolean snapshot.
- `FRAMEWORK_EVALUATION*` documents were retired; adjacent-library comparison
  now lives in `docs/FRAMEWORK_COMPARISON.md`.

### What you may need to update

- Replace direct underscore wrapper type references with public reducer
  composition.
- Add `InnoFlowSwiftUI` as a target dependency and import it from SwiftUI code
  that calls `Store.binding`, `ScopedStore.binding`, `Store.preview`, or
  `EffectTask.animation(Animation?)`.
- Replace `context.isCancelled` with `checkCancellation()` or
  `isCancellationRequested()`.
- Run canonical sample package tests with `--jobs 1` and sample Xcode builds
  with `-jobs 1` in downstream release gates.

## 4.0.0 Release

This release promotes the current InnoFlow implementation and documentation contract to 4.0.0
with the public API updates captured below.

### Changed

1. Rebaselined README, localized READMEs, architecture contract, migration notes, release notes,
   release checklist, and doc parity metadata around the current public contract.
2. Clarified `SelectedStore` guidance: `select(dependingOn:)` covers a single explicit state
   slice, the variadic `select(dependingOnAll:)` covers two or more explicit slices, and closure
   selection remains the always-refresh fallback.
3. Aligned the projection lifecycle docs with the 4.0.0 API: `ScopedStore.state` keeps its
   SwiftUI observer-race cached snapshot fallback, while `SelectedStore.value` is removed in favor
   of `optionalValue` (`nil` when dead) or `requireAlive()` (`preconditionFailure` when dead).
4. Fixed Markdown `.run` examples so throwing work is wrapped inside `do/catch` in non-throwing
   effect closures.
5. Strengthened local release-readiness gates for localized install snippets, release target docs,
   localized `SelectedStore` guidance, and bare throwing `.run` snippets.
6. Generalized `EffectID` to accept typed `Hashable & Sendable` raw values while keeping
   `StaticEffectID` as the string-literal convenience alias.
7. Added `EffectTask.run` overloads for consuming `AsyncSequence` streams directly or through an
   optional element-to-action transform.
8. Hardened store effect cancellation for non-awaited composite effects and
   nested `.cancellable` boundaries, and aligned production/test
   cancellation-boundary accounting.
9. Tightened phase-managed totality diagnostics to count only `PhaseMap` DSL
   graph declarations.
10. Reduced collection reducer and scoped-store cache overhead on repeated list
   refreshes.
11. Strengthened tag-driven release validation so 4.0.0 publication fails when
    release-target documentation and tags drift.

## Migration Note

### What changed

- The 4.0.0 surface includes the release hardening changes above plus the
  selection, effect ID, and instrumentation updates listed in this section.
- SwiftUI conveniences now live in `InnoFlowSwiftUI`, synchronous
  `EffectContext.isCancelled` is removed, and direct underscored reducer-builder
  wrapper references are no longer supported.

### What you may need to update

- Multi-slice `SelectedStore` call sites should migrate from tuple-packed
  `select(dependingOn: (\.a, \.b))` to `select(dependingOnAll: \.a, \.b)`.
- Direct `SelectedStore.value` reads should migrate to `optionalValue` when
  absence is acceptable, or `requireAlive()` when liveness is an ownership
  precondition.
- Explicit `EffectID` type annotations should use `StaticEffectID` for string identifiers or
  `EffectID<RawValue>` for typed dynamic identifiers.
- Instrumentation consumers should treat event cancellation identifiers as `AnyEffectID?`; typed
  `EffectID` values remain accepted by event initializers and `AnyEffectID.rawValue` exposes the
  erased raw value for logging.
- The runtime and diagnostic hardening in this pass does not require source
  migration.
- Consumers that pin exact tags can move to `4.0.0`.

## 3.0.3 Release

This patch release keeps InnoFlow compatible with tvOS toolchains while preserving the
runtime cleanup contract used by `Store` and `TestStore`.

### Changed

1. Avoided isolated-deinit toolchain failures on tvOS builds.
2. Preserved `Store` cleanup behavior and effect cancellation semantics.
3. Kept the public `InnoFlow` and `InnoFlowTesting` API surface unchanged.

## Migration Note

### What changed

- tvOS package consumers can build the 3.0 line without isolated-deinit toolchain failures.
- Runtime semantics, reducer authoring, and import paths are unchanged.

### What you may need to update

- Consumers that pin exact tags can move to `3.0.3`.

## 3.0.2 Release

This patch release aligns the macro target manifest with the `swift-syntax` modules already used during compilation so package consumers and maintainers get a quieter, explicit build graph.

### Changed

1. Declared the missing `swift-syntax` products required by `InnoFlowMacros`.
2. Removed Xcode and SwiftPM missing-dependency scan noise around the macro implementation target.
3. Kept the public `InnoFlow` and `InnoFlowTesting` API surface unchanged.

## Migration Note

### What changed

- `InnoFlowMacros` now explicitly declares the `swift-syntax` helper products it was already relying on indirectly.
- No reducer authoring, runtime semantics, or consumer import paths changed.

### What you may need to update

- No source update is required.
- Consumers that pin exact tags can move to `3.0.2` to pick up the macro dependency manifest fix.

## 3.0.1 Release

This patch release removes `swift-docc-plugin` from the consumer package graph while preserving DocC generation for maintainers through a docs-only flow.

### Changed

1. SwiftPM consumers now resolve only the dependencies required to build and test InnoFlow.
2. DocC generation now runs through `Tools/generate-docc.sh`, which injects the DocC plugin into a temporary package copy.
3. Release automation now publishes the matching changelog section as the GitHub Release body.

## Migration Note

### What changed

- `swift-docc-plugin` no longer ships in the main consumer package graph.
- DocC generation now runs through a docs-only maintainer flow that injects the plugin into a temporary package copy.
- `PhaseMap` is the canonical runtime phase-transition layer for phase-heavy features.
- Once `.phaseMap(...)` is active, the base reducer must stop mutating the owned phase directly.
- Generated action path names now strip one leading underscore.

### What you may need to update

- CI or local scripts that previously assumed `swift package generate-documentation` was available directly from the checked-in `Package.swift`.
- Features that still assign `state.phase = ...` inside a reducer branch after adopting `PhaseMap`.
- Sample or app code that still references underscored generated path members.
- Feature guides that present `On(where:)` as the default matching path instead of `CasePath` or equatable actions.

### Recommended search/replace

- `Action._loadedCasePath` → `Action.loadedCasePath`
- `Action._failedCasePath` → `Action.failedCasePath`
- `state.phase =` inside a `.phaseMap(...)` feature → move the transition into `PhaseMap`

## 3.0.0 Release

This release tightens the semantics around the new phase-ownership model, adds opt-in
`PhaseMap` validation coverage, and makes the breaking migration points explicit.

### Added

1. Additional `PhaseMap` coverage:
   - base reducer direct phase mutation restore semantics
   - undeclared dynamic target rejection while preserving non-phase reducer work
   - `On(where:)` fixed-target / nil-guard / same-phase guard paths
2. Opt-in phase trigger coverage validation:
   - `phaseMap.validationReport(expectedTriggersByPhase: ...)`
   - keeps `PhaseMap` partial-by-default at runtime while allowing stricter test-time contracts
3. Stronger assertion context in `PhaseMap` diagnostics:
   - current action
   - previous phase
   - post-reduce phase
   - declared targets

### Changed

1. `PhaseMap` is the canonical runtime phase-transition layer for phase-heavy features.
2. When `.phaseMap(...)` is active, base reducers must stop mutating the owned phase directly.
3. Generated action path names strip one leading underscore:
   - `Action._loadedCasePath` → `Action.loadedCasePath`
   - `Action._failedCasePath` → `Action.failedCasePath`
4. `PhaseMap` remains partial by default. Unmatched phase/action pairs stay legal no-ops unless
   tests opt into stricter validation.
5. `validatePhaseTransitions(...)` remains available for backward compatibility, but new runtime
   phase ownership should prefer `PhaseMap`.

## 2.5.0 Patch (Queued Dispatch + Ordering Contract)

This release clarifies runtime semantics by moving `Store` dispatch onto a single FIFO queue while
preserving cancellation, debounce, throttle, and animation contracts.

### Added

1. Ordering contract coverage:
   - `EffectTask.send` emits immediate follow-up actions through the queue
   - `EffectTask.run` re-enters the same queue after the async boundary
   - `EffectTask.concatenate` preserves declaration order
   - `EffectTask.merge` emits in child completion order
2. Additional `Store` runtime tests:
   - queue-based follow-up dispatch
   - reducer reentrancy prevention for immediate sends
   - async emission re-entry through the same queue
3. Documentation examples for direct `InnoFlow` + `InnoRouter` composition at the app/coordinator boundary

### Changed

1. `Store.send(_:)` no longer processes `.send` follow-up actions through reducer re-entry.
2. Effect-emitted actions now flow through the same FIFO dispatch queue as external store actions.
3. README and DocC now document queue-based action ordering and navigation ownership boundaries.

## 2.4.0 Patch (Throttle Full Control + Animation Modifier)

This release extends effect orchestration while preserving cancellation guarantees and existing store APIs.

### Added

1. Full-control throttle API:
   - `throttle(_ id:for:)` (existing leading-only shortcut)
   - `throttle(_ id:for:leading:trailing:)`
2. Animation modifier:
   - `animation(_ animation: Animation? = .default)`
   - Applies to actions emitted from nested effect paths (`.send` and `.run`).
3. Coverage expansion:
   - trailing-only throttle semantics
   - leading+trailing semantics (trailing only when an extra in-window event exists)
   - throttle cancellation integration (`cancelEffects`, `cancelAllEffects`)
   - animation composition tests

### Changed

1. `Store` and `TestStore` now track pending trailing throttle events per `EffectID`.
2. Trailing throttle state is cleaned up on ID cancellation and global cancellation.
3. Effect execution context now carries animation metadata through the shared runtime context.

## 2.3.0 Patch (Coverage + Combinators + Diagnostics)

This release focuses on runtime ergonomics and quality gates without changing `Store` public method signatures.

### Added

1. Built-in combinators on `EffectTask`:
   - `debounce(_ id:for:)`
   - `throttle(_ id:for:)` (leading-only)
2. Expanded test coverage:
   - `ScopedStore` projection and action forwarding
   - binding positive flow and compile contract rejection for non-bindable key paths
   - deinit cancellation edge case
   - CI-safe stress loops with heavy opt-in mode (`INNOFLOW_HEAVY_STRESS=1`)
3. Improved macro diagnostics:
   - exact expected reducer signature
   - concrete mismatch details
   - explicit remediation guidance

### Changed

1. Runtime semantics are now aligned for `merge` in awaited paths (concurrent execution + wait-for-all).
2. Documentation is updated with English-primary content and canonical entry-point guidance.

## 🚧 2.0.0 Preview (Breaking API Changes)

This section previews the intended API direction of **InnoFlow v2**.
v2 prioritizes ideal API design over backward compatibility, and allows breaking changes.

### Why v2?

1. Unify the effect model around a single compositional DSL
2. Tighten the consistency of the binding and reducer contracts
3. Improve async cancellation semantics and test determinism
4. Strengthen the concurrency runtime while keeping SwiftUI ergonomics intact

### Planned Breaking Changes (Preview)

1. `Reducer<State, Action, Mutation, Effect>` → `Reducer<State, Action>`
2. Remove `Reduce` and `EffectOutput`
3. Remove the `handle(effect:)` pipeline
4. Introduce `reduce(into:action:) -> EffectTask<Action>`
5. Restrict `Store.binding` to `@BindableField`-backed fields
6. Update the `@InnoFlow` macro contract to the v2 reducer form
7. Encapsulate `EffectTask.Operation` and remove it from the public surface
8. Redefine `EffectID` as a typed `Hashable & Sendable` identifier, with `StaticEffectID` as the
   string-literal convenience alias
9. Change `Store.cancelEffects` and `Store.cancelAllEffects` to `async`
10. Shift macro signature validation toward structural checks (`reduce` + `into`/`action` + `inout`)
11. Simplify cancellation-boundary runtime handling by removing `pendingCancellableRunsByID` and tightening the emission gate

### Quality Gates (SwiftUI + SOLID)

| Gate | Status | Notes |
|---|---|---|
| SwiftUI philosophy alignment | Conditional Pass | Single state path and explicit binding are satisfied; app-level navigation composition still requires discipline |
| SOLID alignment | Conditional Pass | Reducer/runtime/store boundaries are strong; DIP still depends on app-level conventions |

### Dependency Impact

| Module | Impact | Required Action |
|---|---|---|
| InnoFlow | High | Migrate all features to `EffectTask`-based reducer |
| InnoFlowTesting | High | Replace sleep-oriented async testing patterns with deterministic timeout/cancellation model |
| InnoRouterEffects | Medium | Update InnoFlow integration examples to v2 effect syntax |
| App Integrators | High | Run migration checklist and update feature templates/macros |

### InnoRouter Compatibility Note

InnoFlow and InnoRouter are highly compatible from a state-driven navigation perspective.
The supported v2 direction is direct composition at the app/coordinator boundary plus updated effect-integration examples.

### Migration Planning

See [API_DESIGN_EVALUATION.md](API_DESIGN_EVALUATION.md) for full migration and evaluation details.

1. Weighted comparison against external frameworks (TCA, ReactorKit, ReSwift, SwiftRex)
2. v1 scorecard and API gap analysis
3. v2 public API proposal and migration checklist
4. InnoRouter integration strategy and regression scenarios

---

## InnoFlow 1.0.0 Release Notes (Legacy v1 API)

We're excited to announce the initial release of **InnoFlow** - a lightweight, hybrid architecture framework for SwiftUI that combines the best of Elm Architecture with SwiftUI's native `@Observable` pattern.

## 🎉 What is InnoFlow?

InnoFlow provides a clean, testable architecture for SwiftUI apps with:
- **Unidirectional Data Flow**: `Action → Reduce → Mutation → State → View`
- **SwiftUI-Native**: Built on `@Observable` for seamless integration
- **Type-Safe**: Leverages Swift's type system for compile-time safety
- **Testable**: First-class testing support with `TestStore`
- **Lightweight**: Minimal boilerplate compared to other architectures

## ✨ Key Features

### Core Architecture
- **Store**: Observable state container that automatically updates SwiftUI views
- **Reducer**: Protocol-based feature definition with clear separation of concerns
- **Action/Mutation/Effect**: Clean separation between user actions, state changes, and side effects

### Swift Macros
- **@InnoFlow**: Automatically generates boilerplate code and protocol conformance
- **@BindableField**: Type-safe two-way bindings for SwiftUI controls

### Effect System
- Support for async operations (API calls, database access, etc.)
- Multiple effect output types: `.none`, `.single`, `.stream`
- Automatic effect cancellation

### Testing
- **TestStore**: Comprehensive testing utilities
- Action and state assertion support
- Effect testing with action verification

## 📦 Installation

### Swift Package Manager

Add InnoFlow to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/innosquad-mdd/InnoFlow.git", from: "1.0.0")
]
```

Or add it in Xcode:
1. File → Add Package Dependencies
2. Enter: `https://github.com/innosquad-mdd/InnoFlow.git`
3. Select version: `1.0.0`

## 🚀 Quick Start

### 1. Define Your Feature

```swift
import InnoFlow

@InnoFlow
struct CounterFeature {
    struct State: Equatable {
        var count = 0
        @BindableField var step = 1
    }
    
    enum Action {
        case increment
        case decrement
        case setStep(Int)
    }
    
    enum Mutation {
        case setCount(Int)
        case setStep(Int)
    }
    
    func reduce(state: State, action: Action) -> Reduce<Mutation, Never> {
        switch action {
        case .increment:
            return .mutation(.setCount(state.count + state.step))
        case .decrement:
            return .mutation(.setCount(state.count - state.step))
        case .setStep(let step):
            return .mutation(.setStep(step))
        }
    }
    
    func mutate(state: inout State, mutation: Mutation) {
        switch mutation {
        case .setCount(let count):
            state.count = count
        case .setStep(let step):
            state.step = max(1, step)
        }
    }
}
```

### 2. Use in SwiftUI

```swift
struct CounterView: View {
    @State private var store = Store(CounterFeature())
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Count: \(store.count)")
                .font(.largeTitle)
            
            HStack(spacing: 40) {
                Button("−") { store.send(.decrement) }
                Button("+") { store.send(.increment) }
            }
            
            Stepper("Step: \(store.step)", value: store.binding(
                \.step,
                send: { .setStep($0) }
            ))
        }
    }
}
```

## 📚 Documentation

- [README](README.md) - Complete guide and API reference
- [Examples](Examples/) - Sample apps demonstrating InnoFlow usage
- [Changelog](CHANGELOG.md) - Version history

## 🤝 Contributing

We welcome contributions! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## 📄 License

MIT License - See [LICENSE](LICENSE) for details.

## 🙏 Acknowledgments

InnoFlow is inspired by:
- The Elm Architecture
- TCA (The Composable Architecture)
- SwiftUI's `@Observable` pattern

---

**Made with ❤️ by InnoSquad**

For questions, issues, or feature requests, please open an issue on GitHub.
