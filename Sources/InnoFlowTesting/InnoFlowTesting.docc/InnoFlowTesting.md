# ``InnoFlowTesting``

Deterministically verify reducer state transitions, effect actions, and timing.

## Overview

Use ``TestStore`` to send feature actions, receive actions emitted by effects,
and assert every state transition. Exhaustivity defaults to ``Exhaustivity/on``;
an omitted assertion closure means that the action must not change state.

Use `finish()` at the terminal boundary to wait for framework-owned effects and
verify that no effect actions remain. Use `assertNoBufferedActions()` only for
an intermediate queue checkpoint. ``ScopedTestStore`` applies the same contract
while asserting against the complete root state.

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

## Topics

### Reducer Harness

- ``TestStore``
- ``ScopedTestStore``
- ``Exhaustivity``

### Time and Instrumentation

- ``ManualTestClock``
- ``EffectTimingRecorder``
