# ADR: Compile-time Phase Totality Diagnostics

## Status

Accepted

## Context

`PhaseMap` is partial by default at runtime: unmatched action / phase pairs are
legal no-ops, and totality is validated separately through the opt-in
`phaseMap.validationReport(...)` helper that tests can drive
(`ADR-phase-map-totality-validation.md`).

That contract works for runtime correctness, but it leaves an authoring hazard
unguarded: a feature can declare `enum Phase { case idle, loading, loaded,
failed }`, write a `static var phaseMap` that never references `.failed`, and
ship the change without a single test catching the omission. The runtime
report only reports against expected triggers the test author thought to list.
Adding a new phase case and forgetting to wire it into the phaseMap is silent
under both the runtime contract and the existing test-time validator.

`@InnoFlow(phaseManaged: true)` already requires the type to provide a static
`phaseMap`. Once that requirement is in place, the macro has access to both
the `Phase` enum case list and the syntactic body of the `phaseMap`
declaration at expansion time. That is exactly the information needed to
diagnose Phase cases that are never referenced from the phaseMap, without
introducing any runtime cost.

## Options Considered

### 1. Keep totality strictly runtime / test-time

Pros:

- preserves the existing partial-by-default contract verbatim
- avoids any new compile-time analysis surface

Cons:

- new Phase cases that are forgotten in the phaseMap remain silent
- the existing `validationReport(...)` only catches missing triggers the
  test author explicitly enumerates, not declared-but-unwired cases

### 2. Full reachability analysis at compile time

Compute the directed transition graph from declared `From(.x) { On(...) }`
expressions, then BFS from initial cases to flag unreachable / dead phases.

Pros:

- catches truly unreachable phases, not just unreferenced names
- closest to a "real" FSM totality check

Cons:

- predicate-bearing transitions (`where:`, `targets: ... resolve:`) cannot be
  resolved statically, so the analysis would have to admit a fall-through
  category that approximates correctness rather than guaranteeing it
- requires choosing initial-phase semantics the framework currently does not
  encode (the runtime treats every declared phase as a legal starting point)
- substantially more macro code to maintain for diagnostics that overlap with
  the runtime `validationReport(...)` flows

### 3. Unreferenced-case diagnostic at compile time (current decision)

For phase-managed features (`@InnoFlow(phaseManaged: true)`), walk the
syntactic body of the static `phaseMap` getter, collect the names of every
`MemberAccessExprSyntax` (e.g. `.idle`, `.loading`, `.failed`), and warn for
any Phase enum case whose name does not appear in that set.

Pros:

- catches the high-frequency authoring hazard (declared-but-unwired phase)
- works with predicate-bearing transitions because the warning is name-based,
  not graph-based
- complements the existing runtime `validationReport(...)` rather than
  duplicating it
- the diagnostic anchors on the enum case itself, so the offending
  declaration is the file/line surfaced to the author
- pure macro-time cost; no runtime impact, no public API change

Cons:

- a Phase case referenced from a non-phaseMap context (e.g. tested directly
  in a unit test) but never wired into the phaseMap is still flagged. The
  warning is therefore advisory; severity is `warning`, not `error`, so
  authors can suppress it with a one-line `_ = State.Phase.x` reference
  inside the phaseMap getter when they truly intend to keep an unused case
- does not detect unreachable phases that *are* referenced in phaseMap (e.g.
  appear as a `to:` target but no path reaches their `From` rule)

## Decision

Choose option 3.

`@InnoFlow(phaseManaged: true)` runs an unreferenced-case diagnostic at
macro-expansion time. Severity is `warning`. The runtime `PhaseMap`
contract — partial by default, validated through `validationReport(...)`
when teams want stronger guarantees — is unchanged.

Full graph-based reachability remains out of scope for this layer for the
reasons in option 2.

## Consequences

- forgotten phase wiring becomes a compile-time signal that authors see
  immediately, rather than a runtime drift waiting for a missing-trigger
  validation report
- the diagnostic is local to phase-managed features; legacy `@InnoFlow`
  (no-arg) features keep their existing macro surface unchanged
- the warning anchors on the enum case syntax, so the file/line surfaced
  matches where the author would fix the omission
- false positives are possible for Phase cases that are intentionally
  unwired but referenced from outside the phaseMap (tests, derived state
  helpers); authors silence them by referencing the case once inside the
  phaseMap getter or by removing the case
- a future option-2-style reachability analyzer would slot in next to this
  diagnostic without changing the runtime contract; this ADR records the
  current choice as the smallest analysis that catches the dominant hazard

## Static Analysis Limits

The diagnostic is a syntactic hint, not a proof system.

- It checks whether each Phase case name is referenced from the static
  `phaseMap` declaration.
- It does not prove graph reachability from an initial phase.
- It does not evaluate `On(where:)` predicates.
- It does not prove that a dynamic `resolve` closure can return every
  declared target.
- It does not change `PhaseMap` runtime semantics; unmatched actions remain
  legal no-ops unless tests opt into stricter coverage.

Use `assertValidGraph(...)` for topology checks and `assertPhaseMapCovers(...)`
for explicit trigger coverage in tests.
