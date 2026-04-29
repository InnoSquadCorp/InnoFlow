# ADR: Reducer Sendable Policy

## Status

Accepted

## Context

Swift Concurrency requires deliberate decisions about which types must be `Sendable`. InnoFlow
takes a strong stance for some of those types and a deliberately softer stance for others:

- `State` must be `Sendable`
- `Action` must be `Sendable`
- effects produced by `EffectTask<Action>` are `Sendable`
- the `Reducer` protocol itself **does not require** conformance to `Sendable`

This is a visible difference from frameworks that require their reducer protocol to be
`Sendable`. The framework's principle gates already enforce the absence of `@unchecked Sendable`
in shipped sources, but the rule about reducers themselves has only been explained verbally.
This ADR records why the asymmetry exists.

## Context observations

- The store runs reducer composition on the main actor. `Store` is `@MainActor`, the action
  queue drains on the main actor, and `reduce(into:action:)` executes there.
- Effects are the boundary that crosses isolation domains. Once the reducer hands work to
  `EffectTask`, the runtime moves it onto an actor and back. The values that travel across
  that boundary — actions, state snapshots used by selections, and effect payloads — must be
  `Sendable`.
- Reducer values themselves do not cross isolation domains while a feature is executing. They
  are constructed by the application layer, handed to the store, and consulted on the main
  actor.

## Options Considered

### 1. Require `Reducer: Sendable`

Pros:

- uniform policy: every public type in the framework requires `Sendable`
- prevents reducer authors from holding non-`Sendable` collaborators by reference
- closer to what teams familiar with other architecture frameworks expect

Cons:

- forces every collaborator a reducer composes — including ones that never cross isolation
  domains during normal operation — to be either `Sendable` or wrapped behind a `Sendable`
  facade
- makes it harder to compose reducers that internally hold actor references or main-actor-only
  collaborators, even when the reducer body only runs on the main actor anyway
- the constraint pays for safety the framework already has from running reducers on the main
  actor

### 2. Do not require `Reducer: Sendable` (current behavior)

Pros:

- reducer composition stays expressive: a reducer can hold a main-actor-only collaborator
  without needing to launder it through a `Sendable` facade
- the values that actually cross isolation domains — `State`, `Action`, effects — keep their
  strong `Sendable` guarantees, so the safety story for the parts that move stays intact
- the store's `@MainActor` isolation is a real boundary, not a documentation artifact, and
  reducer-internal collaborators benefit from it

Cons:

- reducer authors must understand that effects are the place where `Sendable` matters; types
  used inside the reducer body do not automatically gain a `Sendable` requirement
- the asymmetry must be communicated explicitly so authors do not assume reducer values can
  be sent across isolation domains

### 3. Conditional conformance / opt-in `Sendable` reducers

Pros:

- lets advanced authors mark a reducer `Sendable` when they want to share it across
  isolation domains

Cons:

- the framework does not need to share reducer values across isolation domains today, so the
  feature would have no caller
- adds a second policy lane that authors would have to learn about

## Decision

Choose option 2: keep the asymmetric policy.

`State`, `Action`, and effect payloads must be `Sendable`. Reducer types themselves do not
need to conform to `Sendable`. The store's `@MainActor` isolation is the runtime guarantee
that makes the asymmetry safe.

## Consequences

- the `Sendable` requirement lives where it is load-bearing: on the values that actually move
  between isolation domains
- reducer composition can hold main-actor-only collaborators without forcing every
  collaborator into a `Sendable` mold
- principle gates continue to forbid `@unchecked Sendable` in shipped sources, so authors
  cannot pretend a non-`Sendable` value is safe to send
- documentation must keep stating, where authors learn the reducer model, that the
  `Sendable` boundary is on `State`/`Action`/effects, not on reducers themselves
- if a future feature needs to share reducer values across isolation domains, that feature
  introduces its own conformance constraint rather than retroactively requiring it framework
  wide

## Rejected alternatives

A blanket `Reducer: Sendable` requirement is rejected because it pays the cost of
isolation-crossing safety on a value that never crosses an isolation domain. An opt-in
conformance lane is rejected because there is currently no caller that needs reducer values
to move between isolation domains.
