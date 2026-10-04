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
In non-exhaustive mode, receiving an output also reduces the intermediate FIFO
actions and starts their follow-up effects. A buffered output is checked first;
only one action is advanced before outputs are checked again. The same total
deadline covers skipped values, action reduction, and waiting for either queue.
Exhaustive mode still requires explicit action assertions.
An optional payload received through a path preserves `.some(nil)` separately
from a failed or cancelled receive. Caller cancellation never reports a timeout.

`send` returns a discardable ``TestStoreDispatch`` for its root dispatch and every
descendant action and effect, including through scoped and phase helpers. Its
`cancel()` affects only that dispatch. `isFinished` describes runtime completion:
a queued action prevents completion, while a delivered but unverified output
remains a separate assertion obligation.

`await task.finish(timeout:)` is a finite, non-consuming verification in both
exhaustivity modes. It diagnoses only its dispatch's unreceived actions and
outputs without reordering either queue or affecting siblings. Receive those
values, then call it again. Timeout or caller cancellation cancels only the
selected dispatch; a cancellation-resistant operation remains unfinished until
it physically returns. A handle and a pending task verification do not retain
the store. `InnoFlowCore.FlowScope` can explicitly track a testing handle using
the same Core dispatch ownership; scope closure joins runtime cancellation and
does not replace test assertions.

Use the global `await store.finish()` for terminal verification. Exhaustive
verification reports actions and outputs from one snapshot with exact counts
and bounded previews, then cleans up remaining work. Non-exhaustive global
finish continues to drain both queues and descendants under one total deadline.

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
Its `sleep(for:)` throws `CancellationError` for an already-cancelled task,
including zero and negative durations. Uncancelled nonpositive sleeps return
without parking; positive sleeps can be synchronized using the clock's
deterministic registration waits before advancing time.
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

## Failure locations and test frameworks

Canonical assertion helpers accept `fileID`, `filePath`, `line`, and `column`,
all defaulted at the calling test. Root/scoped/phase helpers, scenario decoration,
invariants, terminal verification, and asynchronous run failures preserve the
complete origin. The legacy `file:` overload remains supported when explicitly
supplied; it uses the same value for file ID/path and column 1.

While a Swift Testing test is current, failures use `Issue.record` with the
actual `SourceLocation`. Otherwise they use XCTest's `XCTFail` when XCTest is
available. XCTest's public failure interface supports file path and line;
column precision is available through Swift Testing. Skipped assertions remain
warnings and never become XCTest failures.

Scoped output reception supports the same exact-value, predicate, and case-path
forms as root reception, with one shared root queue and total timeout. Structural
state diffs include nested collection paths, missing elements, and enum-case
changes without relying on a container's potentially redacted description.

Read <doc:AdvancedTesting> for phase coverage and reproducible seeded exploration.

## Topics

### Reducer Harness

- ``TestStore``
- ``TestStoreDispatch``
- ``ScopedTestStore``
- ``Exhaustivity``
- ``TestStoreInvariant``
- ``TestStoreScenario``
- ``PhaseCoverageRecorder``
- ``TestStoreExplorer``
- ``SplitMix64``
- ``TestEffectLedger``

### Time and Instrumentation

- ``ManualTestClock``
- ``EffectTimingRecorder``
