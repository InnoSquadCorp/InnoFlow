# ADR: PhaseMap Totality Validation

## Status

Accepted

## Context

`PhaseMap` deliberately treats unmatched phase/action pairs as legal no-ops. That keeps the runtime
decorator lightweight and avoids turning InnoFlow into a strict FSM runtime.

Some teams still want stronger guarantees that the triggers they consider part of a feature
contract are actually declared in the phase map.

The framework cannot infer every possible `Action` value automatically, especially for payload
cases and predicate-based transitions.

## Decision

Keep `PhaseMap` **partial by default** at runtime.

- unmatched actions remain legal no-ops
- `nil` guard results remain legal no-ops
- same-phase resolutions remain legal no-ops

Add an **opt-in validation helper** for tests and debug-oriented contract checks:

- feature authors explicitly list the triggers they consider contractually important
- `phaseMap.validationReport(expectedTriggersByPhase: ...)` reports which expected triggers are not
  covered by declared `From`/`On` rules
- the helper does not change reducer runtime semantics

## Consequences

- strict teams can validate expected triggers without changing production behavior
- `PhaseMap` stays small and predictable as a post-reduce phase ownership layer
- totality remains a validation concern, not a runtime requirement
- the helper only validates the triggers the caller explicitly supplies

## Rejected alternatives

### 1. Make totality a runtime requirement

Rejected because it would turn partial-by-default no-op semantics into a stricter FSM runtime
contract and would break the current ergonomics of `PhaseMap`.

### 2. Compile-time exhaustive checking

Rejected because the framework cannot enumerate all meaningful `Action` values, especially for
payload-bearing and predicate-based transitions.

### 3. No validation support at all

Rejected because teams with stricter phase contracts still need a lightweight way to assert that
important triggers are declared.
