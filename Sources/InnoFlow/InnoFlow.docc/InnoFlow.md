# ``InnoFlow``

InnoFlow is a reducer-first state management framework for SwiftUI.

## Overview

Use InnoFlow when you want:

- Explicit `State` and `Action` modeling
- Deterministic effect handling
- Testable reducer behavior
- Clear ownership of business state transitions

InnoFlow is the right layer for **domain and feature lifecycle**.
Concrete navigation stacks, transport/session lifecycle, and dependency graph construction
stay in the app layer or in other dedicated libraries.

`Store` executes actions through a single FIFO dispatch queue. Immediate follow-up actions from
``EffectTask/send(_:)`` are queued rather than reducer-reentrant, async emissions from
``EffectTask/run(priority:_:)-(_,(Send<Action>)->Void)`` re-enter the same queue after their suspension boundary,
``EffectTask/concatenate(_:)-(EffectTask<Action>...)`` preserves declaration order, and ``EffectTask/merge(_:)-(EffectTask<Action>...)`` emits in
child completion order.

For larger features, model orchestration explicitly: parent actions coordinate child actions,
long-running progress pipelines are composed with ``EffectTask/concatenate(_:)-(EffectTask<Action>...)``, and batch work
shares cancellation IDs for fan-out cancellation from the store boundary.

Conditional child composition stays explicit:

- use ``Scope`` for always-present child state
- use ``IfLet`` for optional child state
- use ``IfCaseLet`` for enum-backed child state
- use ``ForEachReducer`` for collection-backed child state

For read-only derived values, use ``SelectedStore`` so large SwiftUI views can observe an `Equatable`
projection without pulling an entire mutable child scope into the view tree. When that projection
comes from one to six explicit state slices, prefer `select(dependingOn:..., transform:)`. Use
`select(dependingOnAll:)` for larger explicit dependency sets. Plain `select { ... }` remains the
always-refresh fallback because general closures do not expose their dependencies.

Time-sensitive `.run` effects should use ``EffectContext``. That keeps `StoreClock` in control of
debounce/throttle operators and explicit delays inside the effect body.

Dependency graphs still belong outside `InnoFlow`. When a reducer needs services, construct an
explicit `Dependencies` bundle in the app or coordinator layer and pass it into the feature.
The repo-level boundary guide for navigation, transport, and DI ownership lives in
[docs/CROSS_FRAMEWORK.md](https://github.com/InnoSquadCorp/InnoFlow/blob/main/docs/CROSS_FRAMEWORK.md),
and the reducer-side dependency patterns live in
[docs/DEPENDENCY_PATTERNS.md](https://github.com/InnoSquadCorp/InnoFlow/blob/main/docs/DEPENDENCY_PATTERNS.md).

When a feature has meaningful domain phases, prefer ``PhaseMap`` as the canonical phase-transition
layer. `PhaseMap` runs after the base reducer, owns the declared phase key path, and exposes
``PhaseTransitionGraph`` through `derivedGraph` so topology validation stays explicit without
turning InnoFlow into a general FSM runtime.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:EffectTimingBaseline>
- <doc:PhaseDrivenModeling>
- <doc:PhaseDrivenWalkthrough>
- <doc:VisionOSIntegration>

### Core Symbols

- ``Store``
- ``Reducer``
- ``PhaseMap``
- ``PhaseTransition``
- ``PhaseTransitionGraph``
