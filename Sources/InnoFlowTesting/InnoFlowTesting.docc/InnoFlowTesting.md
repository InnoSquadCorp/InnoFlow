# ``InnoFlowTesting``

Deterministically verify reducer state transitions, effect actions, and timing.

## Overview

Use ``TestStore`` to send feature actions, receive actions emitted by effects,
and assert every state transition. Exhaustivity defaults to ``Exhaustivity/on``;
an omitted assertion closure means that the action must not change state.

Use `finish()` at the terminal boundary to wait for framework-owned effects and
verify that no effect actions or reducer outputs remain. Consume outputs with
`receiveOutput(_:)`. Use `assertNoBufferedActions()` only for an intermediate
queue checkpoint. The former ambiguous `assertNoMoreActions()` API was removed
in 6.0. ``ScopedTestStore`` applies the same contract while asserting against
the complete root state.

Output reception supports exact values, predicates (`receiveOutput(where:)`),
and `CasePath` payload extraction. Predicates and paths support non-equatable
outputs. Exhaustive mode fails at the first mismatch; non-exhaustive mode skips
mismatches within one total timeout and optionally reports skipped assertions.
An optional payload received through a path preserves `.some(nil)` separately
from a failed or cancelled receive. Caller cancellation never reports a timeout.

If a store leaves scope with valid buffered actions or active framework-owned
effects, its synchronous deinitializer provides a final safety net: exhaustive
mode records one failure, `.off(showSkippedAssertions: true)` records one
warning, and `.off` remains silent. Deinitialization cancels remaining work but
does not wait for effects or reduce actions, so it is not a substitute for
`finish()`. A completed or failed `finish()` is not reported again unless new
work begins or arrives afterward.

Runtime failures are independent of exhaustivity. If either
`EffectTask.run(sequence:)` overload receives a non-cancellation error while
its run is still active, ``TestStore`` records one failure at the action
assertion that created the effect, including through delayed and composed
execution. Cancellation errors remain normal cooperative termination. If the
harness accepts cancellation first, a later domain error from uncooperative
work is discarded instead of being reclassified as a test failure.

For time-sensitive effects, inject ``ManualTestClock`` and advance it explicitly.
``EffectTimingRecorder`` captures instrumentation events for repeatable baseline
comparisons.

Attach ``TestStoreInvariant`` values to verify post-reduction state constraints
once across direct sends, received effects, scoped forwarding, and automatic
consumption. Use ``TestStoreScenario`` to package deterministic action and
output steps for reuse; it is test input, not production state recording or
replay. Cancelling a scenario stops before subsequent steps, cancels remaining
TestStore effects, and returns a result with the interrupted zero-based step
index and label instead of reporting normal completion. Scoped output reception
consumes the same root queue and therefore
retains root ordering, exhaustivity, and total-deadline behavior.

## Topics

### Reducer Harness

- ``TestStore``
- ``ScopedTestStore``
- ``Exhaustivity``
- ``TestStoreInvariant``
- ``TestStoreScenario``

### Time and Instrumentation

- ``ManualTestClock``
- ``EffectTimingRecorder``
