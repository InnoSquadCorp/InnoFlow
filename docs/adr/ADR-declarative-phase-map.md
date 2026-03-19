# ADR: Declarative PhaseMap

## Status

Accepted

## Context

`PhaseTransitionGraph` already exists as a topology validator. It can document legal phase edges,
validate runtime transitions through `validatePhaseTransitions(...)`, and perform static reachability
analysis through `validationReport(...)` and `assertValidGraph(...)`.

What it does **not** own is the actual transition logic. In larger reducers that logic tends to
spread across `switch action` branches:

- actions directly mutate `state.phase`
- conditional phase resolution is embedded inside imperative reducer code
- the graph remains declarative, but the phase ownership story is not

That creates two practical problems:

1. phase transitions are harder to read than the rest of the reducer composition surface
2. complex features repeat the same “match action, inspect state, assign next phase” structure

At the same time, expanding `PhaseTransitionGraph` itself into a guard-bearing runtime would blur
the existing boundary between:

- graph topology validation
- reducer-owned domain semantics

## Decision

Introduce `PhaseMap` as a declarative phase-transition layer that wraps a base reducer as a
**post-reduce decorator**.

The contract is:

- base reducers own non-phase state mutation and effects
- `PhaseMap` owns the declared phase key path
- phase transitions are resolved after the base reducer runs, using the final reducer state plus the action payload
- `PhaseMap` exposes `derivedGraph` so features can continue to validate topology with `PhaseTransitionGraph`

`PhaseTransitionGraph` itself stays topology-only. Guard-bearing graph metadata remains out of
scope.

## Consequences

- canonical phase-driven features become more declarative:
  - `Reduce` handles data mutation and effects
  - `PhaseMap` handles legal phase movement
- phase ownership becomes explicit; base reducers should not mutate the declared phase directly once
  `PhaseMap` is active
- graph validation remains available through `phaseMap.derivedGraph`
- `validatePhaseTransitions(...)` remains for backward compatibility, but new docs and canonical
  samples should prefer `PhaseMap`
- guard semantics live at the reducer layer, not inside `PhaseTransitionGraph`

## Rejected alternatives

### 1. Keep imperative reducer-only phase changes

Pros:

- no new API surface

Cons:

- leaves phase ownership implicit
- repeats action-to-phase mapping logic in reducer bodies
- weakens the declarative authoring story compared to the rest of InnoFlow

### 2. Add guard support directly to `PhaseTransitionGraph`

Pros:

- richer graph expressiveness

Cons:

- turns the graph into reducer-semantic metadata
- creates a second executable source of truth
- pushes InnoFlow toward a general FSM runtime

### 3. Add a sibling `PhaseMap` reducer inside `CombineReducers`

Pros:

- simple composition story on paper

Cons:

- introduces ambiguous execution ordering relative to the base reducer
- makes pre-reduce vs post-reduce semantics harder to reason about

The adopted decorator form avoids that ambiguity by fixing the behavior as post-reduce.
