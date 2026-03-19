# Architecture Contract

This document captures the stable framework guarantees that should not drift with scorecards or release notes.

## Core ownership

- InnoFlow owns business and domain transitions only.
- The app layer owns window, scene, route, and spatial runtime concerns. On `visionOS`, immersive-space orchestration stays in the app layer.
- Transport, reconnect, and session lifecycle stay outside InnoFlow.
- Construction-time `Dependencies` bundles enter reducers explicitly. InnoFlow does not own the dependency graph.

## Official authoring surface

- Official feature authoring uses `var body: some Reducer<State, Action>`.
- Composition happens through `Reduce`, `CombineReducers`, `Scope`, `IfLet`, `IfCaseLet`, and `ForEachReducer`.
- Binding remains explicit through `@BindableField`, and SwiftUI bindings use projected key paths such as `\.$field`.
- `Store.preview(...)` and `#Preview` are the canonical preview entry points.

## Selection and derived state

- `SelectedStore` is the official derived-read model.
- Prefer `select(dependingOn:)` when the dependency slice is explicit.
- Closure-based selection remains an always-refresh fallback when dependency reads cannot be declared soundly.
- Multi-field `dependingOn:` overloads exist for the common 2-field and 3-field cases. Larger projections remain a trigger-based backlog item, not a current framework defect.

## Phase-driven modeling

- `PhaseMap` is the canonical runtime phase ownership layer for phase-heavy features.
- `PhaseMap` is a post-reduce decorator and owns the declared phase key path.
- `phaseGraph = phaseMap.derivedGraph` remains the canonical pattern when a feature needs static topology checks and runtime phase ownership together.
- `PhaseTransitionGraph` stays topology-only and `validationReport(...)` remains the graph-level validation surface.
- `validatePhaseTransitions(...)` still exists for backward compatibility.
- Guard-bearing transitions remain intentionally out of scope for `PhaseTransitionGraph`; see `ADR-phase-transition-guards`.
- Conditional phase resolution lives in `PhaseMap`; see `ADR-declarative-phase-map`.

## Effects and runtime

- `EffectContext` is the canonical effect helper surface. Prefer `context.sleep(for:)` over raw `Task.sleep(...)` inside `.run`.
- Cancellation is cooperative. Runtime teardown continues as best-effort async cleanup.
- The runtime is designed to be deadlock-resistant and avoids coupling reducer semantics to middleware-style interception.

## Instrumentation

- `StoreInstrumentation.sink`, `.osLog`, and `.combined` are the official instrumentation surfaces.
- External metrics backends such as `swift-metrics`, Datadog, or Prometheus should integrate through those sinks instead of changing reducer semantics.

## Accessibility and sample contract

- Canonical sample interactions keep stable `accessibilityIdentifier` values for hub rows, modal dismiss actions, destructive actions, and cancellation actions.
- Prefer explicit VoiceOver semantics over relying on button text alone.
- Prefer Dynamic Type-friendly system layout over fixed sizing.
