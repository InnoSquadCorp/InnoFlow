# Framework Comparison

This document positions InnoFlow against adjacent Swift state-management
libraries. It is not a replacement for choosing a framework by team fit.

## TCA

TCA remains the broadest ecosystem choice when a team wants a mature dependency
system, navigation helpers, extensive documentation, and a large community.

InnoFlow is narrower: reducer-first state, explicit dependency bundles, macro
ergonomics, `PhaseMap`, projection caches, and lightweight instrumentation.
Choose InnoFlow when the project wants a smaller core and explicit ownership
boundaries over an all-in-one application architecture.

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
