# Framework Comparison

This document positions InnoFlow against adjacent Swift state-management
libraries. It is not a replacement for choosing a framework by team fit.

## TCA

TCA remains the broadest ecosystem choice when a team wants a mature application
architecture rather than only a reducer runtime. Its public surface centers on
`@Reducer` features, `@ObservableState` state, `Store`/`TestStore`, dependency
values, and first-party guidance for tree- and stack-based navigation. That is
the right tradeoff when the team wants one opinionated package to cover state,
effects, dependencies, navigation, testing, and ecosystem conventions.

InnoFlow is intentionally narrower. The core product contains reducer-first
business transitions, explicit dependency bundles, `PhaseMap`, projection
caches, cooperative effect cancellation, and lightweight instrumentation.
SwiftUI-only conveniences such as `Store.binding`, `Store.preview`, and
`EffectTask.animation(Animation?)` live in `InnoFlowSwiftUI`, so non-UI feature
modules can keep depending on `InnoFlow` alone.

Choose InnoFlow over TCA when the project wants explicit ownership boundaries
more than an all-in-one architecture:

- concrete navigation stacks stay in the app shell or another navigation
  library
- transport/session lifecycle stays behind adapters
- dependency graph construction happens outside reducers and enters as explicit
  constructor-injected bundles
- phase-heavy flows can document legal transitions with `PhaseMap` without
  turning the framework into a general FSM runtime
- read-only view models use `SelectedStore` projection caches instead of
  expanding mutable child scopes

## ReactorKit

ReactorKit is familiar to teams with RxSwift-heavy apps and reactor-style view
ownership.

InnoFlow fits Swift Concurrency and SwiftUI-first codebases better. Effects,
manual clocks, selected projections, and macro-generated case paths are designed
around modern Swift rather than reactive streams.

## ReSwift

ReSwift is simple and Redux-like, but leaves many modern SwiftUI concerns to the
application.

InnoFlow adds scoped stores, selected stores, reducer composition primitives,
effect cancellation, phase modeling, and test helpers while keeping dependency
construction outside the core.

## SwiftRex

SwiftRex offers a richer Redux-inspired composition model, including middleware
concepts.

InnoFlow favors fewer primitives and more compiler-checked feature authoring:
`@InnoFlow`, `@BindableField`, `CasePath` routing, `PhaseMap`, and store
instrumentation are the main extension points.

## InnoFlow Position

InnoFlow is strongest when a SwiftUI feature needs:

- reducer-owned business transitions
- deterministic effects with explicit cancellation
- read-only projection caches for expensive view state
- phase-heavy flows documented through `PhaseMap`
- lightweight logs, metrics, or Instruments signposts
- app-owned navigation, transport, and dependency construction

It should not replace a navigation framework, a transport client, a DI
container, or a full observability SDK.
