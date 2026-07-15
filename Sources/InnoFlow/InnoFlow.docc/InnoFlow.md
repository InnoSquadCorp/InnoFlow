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
SwiftUI app targets that use the `@InnoFlow` macro should use `InnoFlow` plus
`InnoFlowSwiftUI`; runtime-only domain targets can depend on `InnoFlowCore`
alone. `InnoFlowSwiftUI` and `InnoFlowTesting` reexport `InnoFlowCore`, but
macro declarations stay in `InnoFlow`.

`Store` executes actions through a single FIFO dispatch queue. Immediate follow-up actions from
``/InnoFlowCore/EffectTask/send(_:)`` are queued rather than reducer-reentrant, async emissions from
``/InnoFlowCore/EffectTask/run(priority:_:)-(_,(Send<Action>)->Void)`` re-enter the same queue after their suspension boundary,
``/InnoFlowCore/EffectTask/concatenate(_:)-(EffectTask<Action>...)`` preserves declaration order, and
``/InnoFlowCore/EffectTask/merge(_:)-(EffectTask<Action>...)`` emits in
child completion order.

For larger features, model orchestration explicitly: parent actions coordinate child actions,
long-running progress pipelines are composed with
``/InnoFlowCore/EffectTask/concatenate(_:)-(EffectTask<Action>...)``, and batch work
shares cancellation IDs for fan-out cancellation from the store boundary.

`TestStore.exhaustivity` defaults to `.on`: every state mutation belongs in the
matching `send` or `receive` assertion, every effect action must be received,
and an omitted assertion closure means no state change. Set `.off` only for an
intentionally partial test, use `finish()` at the terminal boundary, and use
`assertNoBufferedActions()` for an intermediate queue checkpoint.

The separately generated
[InnoFlowTesting API reference](https://innosquadcorp.github.io/InnoFlow/testing/documentation/innoflowtesting/)
documents the complete testing-support symbol surface.

Conditional child composition stays explicit:

- use ``/InnoFlowCore/Scope`` for always-present child state
- use ``/InnoFlowCore/IfLet`` for optional child state
- use ``/InnoFlowCore/IfCaseLet`` for enum-backed child state
- use ``/InnoFlowCore/ForEachReducer`` for collection-backed child state

`IfLet` and `IfCaseLet` accept an optional `onMissing:` policy that controls
behavior when a child action arrives while child state is unavailable. The
default `.assertOnly` matches the existing contract (debug `assertionFailure`,
release silent no-op). Use `.ignore` to drop the action without an assertion in
either build (useful for late-arriving effects from a dismissed flow), and
`.crash` to trap with `preconditionFailure` in every build (useful when the
late action is treated as a programming bug).

For read-only derived values, use ``/InnoFlowCore/SelectedStore`` so large SwiftUI views can observe an `Equatable`
projection without pulling an entire mutable child scope into the view tree. Use
`select(dependingOn:)` for a single explicit state slice and the variadic
`select(dependingOnAll:)` for two or more slices; both forms keep selective invalidation regardless
of arity. Plain `select { ... }` remains the always-refresh fallback because general closures do
not expose their dependencies.

For lifecycle-aware reads outside SwiftUI view bodies, prefer
``/InnoFlowCore/SelectedStore/optionalValue`` and ``/InnoFlowCore/ScopedStore/optionalState``
(or gate on the matching `isAlive` flag). `ScopedStore.state` and
projection dynamic-member reads keep a cached snapshot fallback for SwiftUI observer races, while
both stores' `requireAlive()` accessors trap with `preconditionFailure` when the projection is
dead. Treat `nil` from the optional accessors as "regenerate the projection." See
ARCHITECTURE_CONTRACT.md - *Projection lifecycle contract*.

Time-sensitive `.run` effects should use ``/InnoFlowCore/EffectContext``. That keeps `StoreClock` in control of
debounce/throttle operators and explicit delays inside the effect body.
When a dependency already exposes an `AsyncSequence`, use the sequence-based `EffectTask.run`
overloads to consume stream elements without adding a custom effect operation.

Dependency graphs still belong outside `InnoFlow`. When a reducer needs services, construct an
explicit `Dependencies` bundle in the app or coordinator layer and pass it into the feature.
The repo-level boundary guide for navigation, transport, and DI ownership lives in
[docs/CROSS_FRAMEWORK.md](https://github.com/InnoSquadCorp/InnoFlow/blob/main/docs/CROSS_FRAMEWORK.md),
and the reducer-side dependency patterns live in
[docs/DEPENDENCY_PATTERNS.md](https://github.com/InnoSquadCorp/InnoFlow/blob/main/docs/DEPENDENCY_PATTERNS.md).

When a feature has meaningful domain phases, prefer ``/InnoFlowCore/PhaseMap`` as the canonical phase-transition
layer. `PhaseMap` runs after the base reducer, owns the declared phase key path, and exposes
``/InnoFlowCore/PhaseTransitionGraph`` through `derivedGraph` so topology validation stays explicit without
turning InnoFlow into a general FSM runtime.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:AsyncSequenceEffects>
- <doc:EffectTimingBaseline>
- <doc:PhaseDrivenModeling>
- <doc:PhaseDrivenWalkthrough>
- <doc:VisionOSIntegration>

### Core Symbols

- ``/InnoFlowCore/Store``
- ``/InnoFlowCore/Reducer``
- ``/InnoFlowCore/PhaseMap``
- ``/InnoFlowCore/PhaseTransition``
- ``/InnoFlowCore/PhaseTransitionGraph``
