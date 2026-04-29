# ADR: Post-reduce Phase Decoration over Pre-reduce Action Filtering

## Status

Accepted

## Context

`PhaseMap` is implemented as a post-reduce decorator. The base reducer runs first, mutates
non-phase state and returns its effects, and only then does the phase layer resolve the next
declared phase from the action and the post-reduce state.

`ADR-declarative-phase-map.md` already records the decision to introduce `PhaseMap` and lists
"sibling reducer inside `CombineReducers`" as a rejected alternative. It does not record a
detailed comparison against the other natural shape: a **pre-reduce action filter** that decides
whether an action is permitted to reach the base reducer at all, based on the current phase and
the action's intended target phase.

That shape exists in some FSM-driven architectures and is occasionally proposed for InnoFlow as
a way to "stop illegal actions before they touch state." This ADR records why InnoFlow keeps the
post-reduce shape and treats illegal phase movement as a debug-time assertion at the decorator
layer rather than as an action-level filter.

## Options Considered

### 1. Pre-reduce action filter

Each action is checked against the current phase before the base reducer runs. If the declared
phase rules do not allow this action from this phase, the action is dropped and no further work
happens.

Pros:

- illegal actions never touch state at all
- the phase rules become a hard runtime guard rather than an after-the-fact check

Cons:

- couples non-phase state mutation to phase legality; an action that legitimately updates other
  state but happens to be filtered out for phase reasons silently drops its non-phase work
- the same action can carry both a payload effect (e.g. record an analytics event, update
  cached input) and a phase intent; the filter has to choose between dropping both or
  splitting the action, neither of which is satisfying
- conditional transitions that depend on post-action state cannot be expressed naturally,
  because the filter runs before the state has settled
- it makes the phase layer the primary owner of action dispatch ordering, which conflicts with
  the rest of InnoFlow's contract that the reducer composition surface owns dispatch

### 2. Post-reduce phase decorator (current behavior)

The base reducer runs unmodified. After it returns, the phase decorator inspects the action
and the post-reduce state, resolves the declared phase rule, and writes the new phase value.
Illegal transitions assert in debug builds; release builds keep the existing phase.

Pros:

- the base reducer stays focused on data and effects; phase rules do not leak into reducer
  bodies
- conditional transitions can use post-action state because the state has already been
  produced
- "same-phase" and "no rule matched" both collapse to no-op semantics, which keeps the
  decorator small and predictable
- the decorator can be added or removed without changing the reducer's data-mutation logic,
  which keeps phase ownership genuinely orthogonal

Cons:

- illegal phase transitions are detected after non-phase state has already changed; in debug
  builds this surfaces as an assertion, in release it silently keeps the prior phase
- features that want a hard runtime block need to express that intent in the reducer itself
  (e.g. by ignoring the action when `state.phase` is wrong) rather than relying on the phase
  layer to refuse it

### 3. Hybrid (filter and decorate)

Run a phase filter before the reducer **and** decorate after. Both layers cooperate, with the
filter blocking action delivery and the decorator writing the resulting phase.

Pros:

- combines the runtime guard of option 1 with the conditional resolution of option 2

Cons:

- introduces two phase layers with overlapping responsibilities, making the rule of "where
  does phase logic live" harder to answer
- the filter and the decorator can disagree (e.g. filter accepts but decorator finds no
  matching rule), which produces hard-to-debug edge cases
- the framework has to define which layer wins when they disagree, and any answer makes the
  other layer harder to explain

## Decision

Choose option 2: keep `PhaseMap` as a post-reduce decorator.

The base reducer owns data mutation and effects, the decorator owns the declared phase key
path, and illegal transitions surface as debug-time assertions rather than as action-level
drops. Hard runtime blocks for illegal actions remain a reducer responsibility, expressed in
ordinary `switch action` code when a feature needs them.

## Consequences

- phase rules stay orthogonal to data flow, which keeps `PhaseMap` adoptable on a
  feature-by-feature basis without rewriting reducer bodies
- conditional transitions can read post-action state, including effect-driven values, because
  resolution happens after the reducer has run
- features that need to reject an action outright still do so in the reducer body; the phase
  layer never silently swallows the action's non-phase work
- a future requirement for hard pre-reduce blocking would need a new ADR rather than a quiet
  change to `PhaseMap`'s execution position
- the post-reduce shape composes cleanly with `validatePhaseTransitions(...)` and
  `validationReport(...)` because both inspect the same declared rule set the decorator uses

## Rejected alternatives

Pre-reduce filtering and the hybrid layout are rejected for the reasons listed above. Both
forms entangle data mutation with phase admission, both introduce ambiguity about who owns
action dispatch, and both make conditional transitions harder to express.
