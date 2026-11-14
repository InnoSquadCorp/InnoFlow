# Public surface cleanup design (7.0 candidate)

Status: proposal, not implemented. Nothing in this document changes the 6.x
public API. Every item below removes or renames a public declaration, so it
needs the major-version review that `CLAUDE.md` requires before any code
moves.

This document is the surface pass that follows the runtime, projection,
macro and testing corrections recorded under `[Unreleased]` in
`CHANGELOG.md`. Those corrections kept every public signature; the behavior
they changed is listed in `MIGRATION.md`. What remains is surface that is
correct but larger than the model it expresses.

## Goals and non-goals

Goals:

- One spelling per concept. Where two spellings mean the same thing, keep the
  one the documentation already calls canonical.
- A surface small enough to hold in one's head: a feature author should be
  able to list the ways to select state or to assert a test step.
- No behavior change. Every removal has a mechanical replacement that keeps
  the same semantics.

Non-goals:

- New capabilities. Nothing here adds a feature.
- Runtime changes. The effect runtime, projection registry and macro output
  are out of scope; they were corrected in 6.x.
- Kotlin and TypeScript surface. Those packages version independently.

## Inventory

Counts are from the working tree this document was written against.

| Area | Public declarations today | Concept count |
| --- | --- | --- |
| `select` on `Store` and `ScopedStore` | 5 overloads each, 10 total | 3 (key path, declared dependencies, closure) |
| SwiftUI `binding` on `Store` and `ScopedStore` | 3 spellings each, 6 total | 1 |
| Phase modeling | `PhaseMap`, `PhaseTransitionGraph`, `validatePhaseTransitions`, `requireComplete`, `strictPhaseTotality` | 2 (ownership, topology) |
| `InnoFlowTesting` assertions with legacy `file:` twins | about two dozen public declarations take `file: StaticString` next to a four-coordinate form | 1 per assertion |
| Cancellation entry points | `cancelEffects(identifiedBy:)` and `cancelAllEffects()` are `async` and no longer suspend | 1 |

## Proposals

### 1. `select`: five overloads to three

Today:

```text
store.select(\.count)
store.select(dependingOn: \.child.title) { $0.uppercased() }
store.select(dependingOnAll: \.a, \.b) { a, b in a + b }
store.select { $0.child.title }
store.select(memoize: true) { $0.child.title }
```

`dependingOn:` is the one-element case of `dependingOnAll:`; the parameter
pack already accepts a single key path. `memoize:` is a mode of the closure
form, not a different selection.

Proposal:

- Keep `select(_ keyPath:)`.
- Keep one declared-dependency form, spelled `select(dependingOn:)` and taking
  a parameter pack. Remove `dependingOnAll:` as a separate label.
- Keep one closure form with `memoize: Bool = false`. Remove the overload that
  exists to make `memoize:` required. On `Store` that overload also requires
  `State: Equatable`, so the merged form has to keep that requirement for
  `memoize: true` and this part is not a pure rename.

Migration is a rename (`dependingOnAll:` to `dependingOn:`) and no change for
the other call sites. Risk: overload resolution between the pack form and the
closure form for a call with one key path and a trailing closure. That must be
proven with a compile fixture before the proposal is accepted; if it cannot be
made unambiguous, keep `dependingOn:` single and `dependingOnAll:` variadic
and remove only the redundant `memoize:` overload.

### 2. `binding`: three spellings to one

Today `binding(_:to:)`, `binding(_:send:)` and the unlabeled trailing-closure
form are documented as semantically identical, with `to:` canonical.

Proposal: keep `binding(_:to:)`. Deprecate `send:` and the unlabeled form in
the last 6.x minor with a rename Fix-It, remove them in 7.0.

This reverses a deliberate 6.x decision ("continue to resolve without
deprecation"), so it needs an explicit yes. The argument for it: three
spellings of one call make code review and search harder and buy nothing. The
argument against: it is churn for existing apps with no functional gain. If
the answer is no, this item is dropped and the contract text stays as is.

### 3. Phase modeling: name the two layers once

`PhaseMap` owns transitions; `PhaseTransitionGraph` validates topology. The
surface around them grew by accretion: `validatePhaseTransitions(...)` wraps a
reducer with a graph, `phaseMap(_:)` wraps it with a map, `derivedGraph`
converts one to the other, `requireComplete(...)` checks triggers at runtime,
and `strictPhaseTotality` checks declarations at compile time.

Proposal:

- Keep `PhaseMap` as the only way to make a reducer own a phase.
- Keep `PhaseTransitionGraph` as a value for documentation and export
  (Mermaid, DOT) and as the result of `derivedGraph`.
- Remove `validatePhaseTransitions(...)` as an authoring path. A feature that
  wants topology validation declares a `PhaseMap`; a feature that only wants
  a graph for documentation builds one without wrapping its reducer.

Inside this repository `validatePhaseTransitions` is used only by its own
tests and fixtures; the sample app and the guides author phases through
`PhaseMap`. It is still public API with unknown external use, so a usage
survey comes first: if a shipped feature validates a phase it does not own
through a map, the removal is not mechanical and this item should be deferred
rather than forced.

### 4. Testing: drop the `file:` twins

Canonical assertions carry `fileID`, `filePath`, `line` and `column`. Each
also has a legacy overload taking `file: StaticString` and `line:`, kept for
call sites that pass a location explicitly.

Proposal: remove the `file:` overloads in 7.0. Explicit-location callers move
to the four-coordinate form; the common call site, which passes nothing, does
not change.

Deprecate first in the last 6.x minor so the compiler lists the affected call
sites.

### 5. Cancellation entry points

`Store.cancelEffects(identifiedBy:)` and `Store.cancelAllEffects()` are
`async` for source compatibility and complete without suspending since the
runtime moved onto the MainActor.

Proposal: in 7.0 make them synchronous. Callers delete `await`. `TestStore`
keeps its `async` forms only if its own bookkeeping still needs them; if not,
it follows.

This is the one item with a behavioral reading: a synchronous signature
states in the type system what is currently only a documented guarantee.

## Order and gating

1. Usage survey for item 3 and the compile fixture for item 1. Both can be
   done on 6.x without touching public API.
2. Decision on item 2.
3. Deprecations (items 2 and 4) in a 6.x minor.
4. Removals and item 5 in 7.0, with `MIGRATION.md` entries and consumer
   fixtures updated in the same change.

Each step is its own change. None of them should ride along with a runtime
fix.

## What this does not fix

- The number of cancellation sources a run consults (dispatch, owner,
  identifier, scheduled request, store lifetime). They are distinct by
  design and already funnel through one check.
- `InnoFlowInspector` has almost no test coverage. Whether it stays a product
  or becomes an example is a product decision, not a surface cleanup.
