# Phase ownership and deterministic tests

## PhaseMap

Use `PhaseMap` for meaningful domain phases. In the [LoadFeature example](../assets/consumer/Sources/FlowSkillExample/Features.swift), `@InnoFlow(phaseManaged: true, strictPhaseTotality: true)` applies the static map after the base reducer. The base reducer updates payload/error data, not `phase`; do not add a second `.phaseMap(...)` wrapper.

`PhaseTransitionGraph` validates topology; it does not own transitions or implement transport/session reconnection. PhaseMap's default trigger matching is partial. `strictPhaseTotality` requires phase management and checks directly declared phase source/target coverage, not predicate or payload-domain exhaustiveness. `requireComplete(...)` is a separate explicit trigger-completeness assertion. Same-phase actions are ignored by the phase layer; illegal transitions assert in debug builds. Model retry/cancel transitions deliberately.

## Exhaustive TestStore

Link/import `InnoFlowTesting` and Swift `Testing`; isolate Store/TestStore tests on `@MainActor`.

- Default exhaustivity is `.on`. Every state mutation belongs in its `send`/`receive` assertion closure. Omitting the closure asserts unchanged state.
- Consume effect actions with `receive`; consume output using exact value, predicate, or the generated Output case path. Outputs are not ordinary follow-up actions.
- End with `await store.finish()`. `assertNoBufferedActions()` is only an intermediate queue checkpoint. `assertNoMoreActions()` was removed in 6.0.
- Testing sends return `TestStoreDispatch`, not runtime `FlowTask` or the removed draft name `TestFlowTask`. A dispatch's `finish` diagnoses its own unverified work without consuming it; global `store.finish()` verifies the entire store.
- Use `.off` only for intentional partial verification, not to make unexpected behavior pass. Under `.off`, assertions start from actual post-reducer state and output waiting can progress intermediate actions; this differs from exhaustive matching.
- Project a parent TestStore with `scope` for child assertions. If a child action also changes parent/sibling state, assert through the parent; the exhaustive root contract still applies.

## Time and cancellation

Inject deterministic dependency closures and `ManualTestClock`. `TestStore` accepts `clock: clock`; runtime `Store` accepts `clock: .manual(clock)`. Advance using `try await clock.advance(by: ..., onceSleepersReach: ...)` or await registered sleepers before cancellation. Do not insert sleeps or repeated `Task.yield()` to guess scheduler readiness.

Registration waits have no built-in wall-clock deadline: ensure the operation can actually register and give the test suite an appropriate time limit. A cancelled clock sleep releases its registration; use passing sibling/success controls when asserting cancellation. Keep domain error mapping separate from accepted host cancellation.

The [consumer suite](../assets/consumer/Tests/FlowSkillExampleTests/ConsumerTests.swift) covers macro authoring, binding, success/failure/retry, active CancellationError mapping, typed output, parent scoping/output lifting, synchronous output capture, manual time, individual dispatch cancellation, and FlowScope ownership. It compiles SwiftUI helpers without exercising Simulator/device lifecycle.

For more involved testing, `TestStoreInvariant`, `TestStoreScenario`, and `TestStoreExplorer` are testing-only tools. Scenario `advance` requires `onceSleepersReach`. Their advanced behavior is not qualified by this fixture.

Sources: [testing and phase guide](https://github.com/InnoSquadCorp/InnoFlow/blob/1176de1e4783b638c03a9334f43cc49378957148/CLAUDE.md), [search tutorial](https://github.com/InnoSquadCorp/InnoFlow/blob/1176de1e4783b638c03a9334f43cc49378957148/Sources/InnoFlow/InnoFlow.docc/SearchFeatureTutorial.md), [ManualTestClock](https://github.com/InnoSquadCorp/InnoFlow/blob/1176de1e4783b638c03a9334f43cc49378957148/Sources/InnoFlowTesting/ManualTestClock.swift).
