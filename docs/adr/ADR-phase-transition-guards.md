# ADR: Phase Transition Guards

## Status

Accepted

## Context

`PhaseTransitionGraph` currently models directed phase topology and supports:

- declared adjacency
- runtime transition validation through `validatePhaseTransitions(...)`
- static topology analysis through `validationReport(...)` and `assertValidGraph(...)`

Requests to add guard-bearing transitions would move the type toward a richer state-machine model:

- `from -> to` edges with predicates
- debug-only guard metadata
- or full guard execution as part of transition validation

That change would increase expressive power, but it would also blur the current boundary between:

- topology validation owned by `PhaseTransitionGraph`
- domain semantics owned by reducer code

## Options Considered

### 1. Keep topology validation only

Pros:

- keeps `PhaseTransitionGraph` small and predictable
- preserves separation between reducer semantics and graph structure
- avoids embedding executable business rules into validation metadata

Cons:

- cannot describe conditional transitions directly on the graph

### 2. Add debug-only guard metadata

Pros:

- richer diagnostics without committing to a full runtime

Cons:

- still introduces a second source of truth for transition rules
- pushes the graph API toward reducer semantics anyway

### 3. Add full guard support

Pros:

- closest to a general FSM/statechart model
- enables more ambitious static analysis later

Cons:

- materially changes the role of `PhaseTransitionGraph`
- increases API and implementation complexity
- makes reducer behavior and graph metadata harder to keep aligned

## Decision

Choose option 1: keep `PhaseTransitionGraph` as a topology validation tool only.

Guard-bearing transitions remain intentionally out of scope.

Reducers continue to own the actual domain conditions that decide when a transition happens. The
graph remains responsible for validating whether a resulting phase transition is legal once that
domain logic has executed.

## Consequences

- `PhaseTransitionGraph` stays small, explicit, and phase-topology focused.
- Runtime and static validation continue to work without turning InnoFlow into a general state-machine runtime.
- Future FSM expansion requires a new ADR rather than incremental drift.
- If teams need richer conditional modeling, the first follow-up should be testing or diagnostic helpers around reducer logic, not new guard execution inside the graph type.
