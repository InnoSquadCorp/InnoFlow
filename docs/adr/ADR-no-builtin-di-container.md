# ADR: No Built-in Dependency Injection Container

## Status

Accepted

## Context

Reducers in InnoFlow need access to clocks, network clients, persistence services, analytics
sinks, and similar collaborators. Other architecture frameworks in the Swift ecosystem solve this
in different ways:

- runtime resolvers backed by a global container (Factory, Resolver)
- compile-time generated graphs (Needle)
- ambient property-wrapper resolvers (`@Dependency`, `swift-dependencies`)
- explicit constructor parameters bundled into a value type (the InnoFlow approach)

InnoFlow has consistently chosen the last form: each reducer receives a `Dependencies` bundle
through its initializer, and the bundle is constructed by the surrounding application layer.
External documentation already states this rule (`ARCHITECTURE_CONTRACT.md`,
`docs/DEPENDENCY_PATTERNS.md`), but the rationale has only been described as "construction-time
graphs stay outside InnoFlow." This ADR records the trade-off analysis behind that rule so future
contributors can evaluate it on its merits rather than as an inherited convention.

## Options Considered

### 1. Ship a built-in runtime resolver

Pros:

- single import to wire collaborators
- consistent with how some Swift teams already think about DI

Cons:

- introduces a global mutable registry that competes with explicit reducer initializers
- moves dependency mistakes from compile time to runtime
- couples reducer testing to whatever fakes the container resolves, rather than to values the
  test passes in
- makes reducer composition harder to reason about because effects can resolve different
  collaborators based on construction order

### 2. Generate a compile-time graph

Pros:

- catches missing or ambiguous bindings at build time
- removes the runtime registry from the failure surface

Cons:

- adds a code generator and an additional build step
- couples the framework to a specific graph generator and its evolution
- still hides the wiring decision behind a generated artifact rather than the call site

### 3. Ambient property-wrapper resolution (`@Dependency`)

Pros:

- low ceremony at the use site
- well-known mental model for teams coming from other frameworks

Cons:

- reintroduces an ambient registry that the reducer reaches into
- makes dependency overrides depend on scope rules of the resolver, not on initializer arguments
- weakens the link between a reducer and its collaborators by hiding it from the type signature

### 4. Explicit construction-time bundles (current behavior)

Pros:

- the reducer's collaborators appear directly in its initializer signature
- tests inject fakes by passing values, not by overriding registry scopes
- removes an entire category of runtime resolution failures
- aligns with the unidirectional-flow contract: side-effect surfaces are explicit
- delegates DI policy to a dedicated module (InnoDI) when teams want a richer container, without
  embedding that policy in the framework

Cons:

- bundle types must be assembled by the app layer; large graphs require manual plumbing
- shared collaborators flowing into many reducers must be threaded through application setup code
- there is no built-in cycle detection or scope manager; teams that need those rely on InnoDI
  or roll their own helpers

## Decision

Choose option 4: keep dependency injection as construction-time bundles, and do not ship a
built-in resolver in InnoFlow.

`Dependencies` bundles enter reducers through ordinary initializers. The framework does not own
the dependency graph, does not host a global registry, and does not synthesize bindings.

Teams that want richer container behavior compose InnoFlow with InnoDI or a comparable layer.
That separation keeps InnoFlow's surface area focused on state, actions, effects, and reducer
composition.

## Consequences

- reducer collaborators stay visible in the initializer signature, which keeps the unidirectional
  flow story coherent with the rest of the framework
- tests pass values directly; there is no resolver scope to configure per test
- the framework does not need cycle detection, scope managers, or a registry lifetime contract
- application layers that need a graph manager adopt InnoDI or another module on top of InnoFlow
- if future requirements demand a built-in registry, this ADR must be revisited rather than
  silently relaxed; ad-hoc resolvers should not appear inside the framework

## Rejected alternatives

The runtime resolver, generated graph, and ambient property-wrapper options are rejected for the
reasons listed above. Each of them moves dependency wiring away from the call site, which
conflicts with InnoFlow's broader contract that side effects and collaborator boundaries stay
explicit.
