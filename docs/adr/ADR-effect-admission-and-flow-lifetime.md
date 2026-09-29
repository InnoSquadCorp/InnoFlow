# ADR: Effect admission and dispatch lifetime

## Status

Accepted for the local 6.0.0 implementation candidate.

- Date: 2026-09-05
- Decision owner: repository owner through the instruction to execute the 1–7 plan
- Baseline branch: `release/6.0.0-local`
- Baseline HEAD: `00a73ed2d2cb94114b0be5c9fbd59c187a4b67c7`
- Baseline tracked-diff SHA-256: `710f63349b2cac09b1c4680e878bebc104132e927aa98b7f4f28e41906ed46ad`
- Baseline untracked-path-list SHA-256: `29828660cd3d63898bcf8cd954372831fffeb54d4d4605141b8f53c4d364b8a9`
- Toolchain: Xcode 27.0 (27A5252f), Apple Swift 6.4, macOS SDK 27.0

## Context

`cancellable(cancelInFlight:)`, debounce, throttle, and concatenate already cover important effect-tree behavior. They do not define admission across independent root dispatches. Consumers therefore repeat busy guards and persistence queues, but those app implementations also own domain rules that a Store-local scheduler cannot replace.

The runtime needs one contract for production `Store` and `TestStore`. It must preserve the existing dispatch-scoped `FlowTask`, cancellation boundaries, typed ephemeral output, and post-reduce `PhaseMap` ownership.

## Decision

### Identity and ordering

- Every root `send` owns a dispatch identity. Descendant actions, runs, outputs, and admission events retain it.
- Dispatch identity, action admission sequence, run token, and cancellation/effect ID are distinct concepts.
- An execution lane is Store-local and keyed by the type-erased value of a typed `EffectID`. Different Stores never share a lane.
- Admission order is the order in which the Store interpreter submits scheduled runs, not the order in which asynchronous Tasks receive CPU time.

### Scheduled-run API

`ReducerEffect` gains a run overload with an `id`, an `EffectExecutionPolicy`, and an optional admission-action transform. The final spelling is:

```swift
.run(
  id: EffectID("save"),
  policy: .serial(maxPending: 8),
  onAdmission: Action.saveAdmission,
) { send, context in
  // awaited operation
}
```

This schedules one run closure. It does not wrap an arbitrary descendant tree. That boundary prevents a serial slot from waiting on a descendant that tries to enter the same lane.

### Policies

- `latest` reuses the existing cancellation boundary. A newer request cancels older eligible work and starts without waiting for uncooperative work to return. It does not promise physical non-overlap or exactly-once I/O.
- A `latest` replacement commits its lane generation and request ownership before any suspension. A stale attach, cancellation, or finish callback can clean up only its own token and cannot orphan or overwrite the current generation.
- `dropWhileRunning` rejects a request while one run occupies the lane. It does not queue.
- `serial(maxPending:)` permits one running request and at most `maxPending` queued requests. Capacity must be non-negative. Admission beyond capacity is rejected explicitly.
- Reusing a live lane with a different policy is rejected. Existing queued work is never silently reinterpreted.

Admission is observable as `started`, `queued(position:)`, or `rejected(reason:)`. A feature that sets loading state from admission must retain request identity so an older event cannot overwrite a newer state. Domain success/failure remains an Action or Output produced by the effect operation.

### Cancellation and completion

- Scheduled runs use their lane ID as a regular cancellation ID.
- Scheduled requests also index every inherited cancellation ID from their effect context. Cancelling a queued request through any such ID removes only that request and releases capacity immediately. Cancelling a running request asks the operation to stop cooperatively.
- A serial slot advances only when the run closure physically returns. A cancellation request by itself does not advance the slot.
- A queued request is a `FlowTask` activity. `finish()` and captured output do not finish until the request is rejected, cancelled, or its run physically terminates.
- Cancellation never rolls back state already reduced or external I/O already committed. InnoFlow does not synthesize a hidden cleanup Action after a dispatch becomes cancelled.

### Lifetime scopes

`FlowScope` is a lexical owner for explicit `FlowTask` and `OutputFlowTask` handles. Closing the scope cancels and joins only still-active registered dispatches. Caller cancellation begins that close while the body may still be awaiting unrelated work, and normal, throwing, and cancelled exits join the same idempotent close state before returning. Completed handles are removed promptly. A closed scope rejects and cancels a late registration. It does not call Store-wide cancellation and does not infer ownership of app-lifetime persistence.

### Diagnostics

Dispatch correlation is metadata-only by default. A bounded, opt-in history records lifecycle events and an active-work snapshot. Only submission creates active state; a late nonterminal event may be recorded after termination but cannot recreate active work. It never records Action, State, Output, or raw effect-ID payloads by default. Cancellation-requested and physically-terminated are different events.

## Failure and recovery behavior

- A rejected request never executes its operation and completes its dispatch activity.
- A failed serial operation releases its slot and the next independent request proceeds. Retry, rollback, and abort-the-queue behavior remain app policy.
- If an uncooperative operation ignores cancellation, diagnostics retain it as active. The runtime neither reports false completion nor starts the next serial operation.
- If the Store is released, queued work is cancelled and retained closures are released.
- A `FlowScope` can wait indefinitely for uncooperative work. Callers that need a user-visible timeout must model it outside the scope without claiming the work terminated.

## Compatibility classification

- New policy, admission, scope, invariant, scenario, and diagnostics types are additive.
- Adding associated cases to an existing public instrumentation enum can break exhaustive external switches. New dispatch diagnostics therefore use a separate event type; existing event constructors receive only defaulted metadata when necessary.
- The existing `EffectTask` spelling (`Output == Never`), `run`, `cancellable`, debounce, throttle, and TestStore calls keep their current meaning.
- `InnoFlowCore` remains compiler-plugin-free and SwiftUI-free.

## Contract scenarios

1. Reverse Task scheduling cannot reverse serial admission.
2. A serial queue at capacity rejects the newest request and never drops an older one silently.
3. Cancelling a queued request immediately removes it; cancelling a running uncooperative request does not start its successor.
4. `latest` can overlap an uncooperative predecessor and documents that limitation.
5. A failed serial request does not poison the lane.
6. Store and TestStore produce the same admission order and terminal classification.
7. A queued request keeps its dispatch capture open, while rejection finishes it without output.
8. A late or stale callback cannot finish a newer generation occupying the same lane.
9. Closing one `FlowScope` leaves sibling and app-owned dispatches untouched.
10. Bounded diagnostics expose truncation rather than hiding dropped history.
11. Cancelling a pending request through an inherited cancellation ID returns serial capacity without waiting for the running predecessor.
12. Caller cancellation reaches scope-owned dispatches before an unrelated body wait is released, while scope return still joins physical teardown.
13. A post-finish nonterminal diagnostic event never recreates an active dispatch.

## Consequences

The framework can remove repeated execution-control boilerplate, but consumers keep data consistency and product recovery rules. In particular, Mulbyul's revision ordering and rollback logic remain authoritative until a consumer test proves a narrower framework replacement is equivalent.

The implementation must update code, contract tests, examples, DocC, compatibility documentation, and release gates together. A library-only build is insufficient evidence for production readiness.
