# Advanced testing

Observe phase coverage and explore reproducible state/action sequences.

## Measure transitions that actually happened

Create `PhaseCoverageRecorder(Feature.phaseMap)` and pass it explicitly as the
`phaseCoverage:` argument to `TestStore`. The recorder observes the actual
post-reduce PhaseMap result through every root, scoped, receive and automatic
reduction path. A `through:` assertion remains a useful topology assertion;
passing a map to that assertion alone never fabricates coverage.

Each `On` declaration has a zero-based trigger index in declaration order.
Coverage is measured for each declared `(source phase, target phase, trigger)`
edge. A resolver with two targets needs both outcomes to cover both edges.
Guarded `nil`, an unmatched action and an ignored self transition do not count.
An accepted `.allow` self transition counts. Coverage never calls a matcher or
resolver again, so recording cannot change resolver side effects or outcomes.

`report()` returns covered/uncovered sets and hit counts. Use
`assertPhaseCoverage(minimum: .all)` for all declared executable edges or
`.fraction(0.8)` for an inclusive fractional threshold. An empty map is fully
covered. Ignored/forbidden self edges are excluded because they cannot be
accepted. `report().mermaid()` draws unobserved edges in red with dashed arrows.
Supply unique stable phase labels for custom types whose descriptions collide.

A recorder is thread-safe and may aggregate multiple explicitly opted-in stores.
Maps reconstructed at the same source declaration site have the same coverage
identity; a different declaration site or state key path stays separate. Moving
or reordering declarations changes the identity/index, so do not persist these
indices as application IDs. If a factory creates several semantically distinct
maps at one declaration site, use a separate recorder for each configuration.

## Generate state-aware, weighted interactions

`TestStoreExplorer` takes a seed, a fresh-store factory and a pure generator.
The `choices:` initializer receives current state. The `generator:` initializer
also receives the step index and elapsed logical time. Return an ordered list
of `.send`, `.receive`, `.advance`, `.cancelEffects` or `.finish` choices. Every
choice has an integer weight; zero disables it and overflow is a diagnostic.
Action choices require a Swift source expression, such as `.increment`, for
copyable scenario output. The generator may throw; its error is returned as a
search failure. Generator/configuration errors are not advertised as reducer
reproductions and are not minimized. Runtime effect errors and `addInvariant` diagnostics are also
captured independently of exhaustivity.

The explorer uses a fixed SplitMix64 algorithm and unbiased rejection sampling.
The same seed, fresh initial conditions and stable generator produce the same
choices when dependencies and scheduling boundaries are deterministic. A seed
cannot make live network data, wall-clock reads or unsynchronized racing effects
deterministic. Inject deterministic dependencies, advance a fresh manual clock
with an explicit sleeper threshold, and receive the result before generating
choices that depend on it. `elapsedTime` includes only explicit successful
clock advances. Clock registration waits have the store's finite timeout. A threshold already
satisfied when checked, including zero sleepers, succeeds even with a zero
budget. The subsequent logical-time advance is not raced against that timeout.

A `run(maxSteps: 1_000)` searches up to the configured budget, stopping at the
first failure, cancellation or empty choice list. Exploration uses `.off` for
state assertions while leaving named invariants active. A TestStore PhaseMap
violation is reported as a diagnostic instead of a debug-process trap; the
same state/effect rejection behavior is preserved. Production reducers keep
their existing debug assertion behavior.

## Reproduce before minimizing

A failure result contains the original choices, seed, failure signature and
minimized choices. Every replay starts with a new store, dependencies and
clock from the supplied factory. The factory must reinstall the same invariants.
Delta debugging removes chunks only if every remaining choice is still enabled
by the generator at its replay state and the same failure signature recurs.
Missing prerequisites and unrelated timeouts never count as reproductions.
The result is deletion-minimal under those checks, not a claim of global
minimality or action-payload shrinking.

Clock configuration/registration failures are configuration errors, not reducer
reproductions. A runtime diagnostic observed before a later registration failure
remains the reported first failure; an invalid interaction cannot validate a
replay. Each attempt cancels its owned work and asks TestStore to join within the
store timeout before another replay. Caller cancellation can interrupt this wait.
`cleanupCompleted` reflects the physical-activity ledger, so an already idle
cancelled store is complete, while accepting cancellation of a running operation
is insufficient. If physical completion remains unverified, search/minimization
stops without accumulating more attempts. Release any explicit test gate before
leaving the test.

Check `replayValidated` before relying on a minimized failure. Nondeterministic
replays keep the original sequence and report that validation failed. Cancellation
stops search/minimization, cancels its store's work, and is not a failing invariant.

`result.scenario` is a typed `TestStoreScenario` using the fresh destination
store's manual clock. Set that store's exhaustivity to `.off` for exploration
replay. `result.scenarioSource(reducerType: "Feature")` returns copyable scenario
code containing the seed, explicit interactions and clock thresholds. It assumes
a fresh equivalently configured `store` and, for advances, `clock` in scope.
The scenario seed identifies the originating search; replay executes its stored
steps rather than drawing new random choices.

## Executable examples

The sample app's `AdvancedTestingTests` observes the successful todo-loading
edges, reports five uncovered edges, and explores the same load with a weighted
state/clock generator. `PhaseExplorationConsistencyTests` adds an intentionally
faulty reducer: a seeded search finds a negative count and minimizes the failure
to the prerequisite `.arm` followed by `.breakCount`. It replays that typed
scenario against a fresh store and verifies the same named invariant failure.
