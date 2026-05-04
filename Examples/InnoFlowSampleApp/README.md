# InnoFlowSampleApp

Canonical reference app for `InnoFlow`.

This sample replaces the previous split examples and demonstrates the recommended patterns in one
app shell:

- `Basics`: reducer fundamentals, bindable state, queue-based follow-up actions
- `Orchestration`: parent-child orchestration, cancellation fan-out, long-running pipelines
- `Phase-Driven FSM`: documented business lifecycle with `PhaseMap`, `phaseGraph = phaseMap.derivedGraph`, `ForEachReducer`, and explicit dependency bundles
- `App-Boundary Navigation`: direct composition at the app/coordinator boundary with pure SwiftUI navigation state
- `Authentication Flow`: explicit dependency bundles, multi-step auth phases, and bindable fields
- `List-Detail Pagination`: scoped collections, selection, and incremental loading
- `Offline-First`: debounced persistence, repository ownership, and optimistic draft state
- `Realtime Stream`: long-lived subscription effects driven by `EffectContext.sleep`
- `Form Validation`: multiple `@BindableField` values, cross-field validation, submit-or-reset flow, and diagnostics-friendly form state
- `Bidirectional WebSocket`: scripted cross-framework transport integration where a websocket adapter owns connection lifecycle, retryable peer-close policy, reconnect budget, and reconnect semantics while the reducer owns business reactions

Stable hub accessibility identifiers:

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

UI smoke tests cover both direct-launch demo mode (`INNOFLOW_SAMPLE_DEMO`) and hub navigation
through these identifiers.

Each feature view also keeps a local `#Preview`, tested controls keep stable accessibility
identifiers, and major interactions include explicit VoiceOver labels or hints when the control text
alone would be too terse. The sample hub rows, modal dismiss action, and long-running or
cancellation-heavy controls are the primary accessibility contract for smoke tests and manual
VoiceOver review.

The sample remains iOS-first as an interactive shell. visionOS support is currently package-level
plus documentation-level guidance; immersive or spatial orchestration stays outside the canonical
sample and belongs to the app boundary instead.

`PhaseDrivenFSM` is the canonical `PhaseMap` reference. Reach for the same pattern when a feature
already has a phase enum, legal transitions are part of the contract, and reducer branches are
starting to scatter imperative `state.phase = ...` updates.

Cross-framework references:

- [`docs/CROSS_FRAMEWORK.md`](../../docs/CROSS_FRAMEWORK.md) for navigation / transport / DI ownership
- [`docs/DEPENDENCY_PATTERNS.md`](../../docs/DEPENDENCY_PATTERNS.md) for reducer-facing dependency bundles

## Structure

```text
InnoFlowSampleApp/
├── InnoFlowSampleApp.xcworkspace
├── InnoFlowSampleApp.xcodeproj
├── InnoFlowSampleApp/
│   ├── Assets.xcassets
│   ├── InnoFlowSampleAppApp.swift
│   └── InnoFlowSampleApp.xctestplan
├── InnoFlowSampleAppPackage/
│   ├── Package.swift
│   ├── Sources/InnoFlowSampleAppFeature/
│   └── Tests/InnoFlowSampleAppFeatureTests/
└── InnoFlowSampleAppUITests/
```

## Run

1. Open [`InnoFlowSampleApp.xcworkspace`](./InnoFlowSampleApp.xcworkspace)
2. Select the `InnoFlowSampleApp` scheme
3. Run on an iOS 17 or newer simulator

Most feature work lives in
[`InnoFlowSampleAppPackage/Sources/InnoFlowSampleAppFeature`](./InnoFlowSampleAppPackage/Sources/InnoFlowSampleAppFeature).

Tests live in
[`InnoFlowSampleAppPackage/Tests/InnoFlowSampleAppFeatureTests`](./InnoFlowSampleAppPackage/Tests/InnoFlowSampleAppFeatureTests).
