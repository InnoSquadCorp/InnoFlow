# ADR: StoreActionQueue Burst Policy

## Status

Accepted

## Context

`StoreActionQueue` ([`Sources/InnoFlowCore/StoreActionQueue.swift`](../../Sources/InnoFlowCore/StoreActionQueue.swift)) is the single in-flight action buffer between effect emissions and reducer reentry. It is intentionally minimal:

- a `[StoreQueuedAction<Action>]` buffer plus a `head` cursor
- a `beginDrain()` reentrancy guard
- prefix compaction during long drains
- a 64 KiB post-drain retained-storage budget

In the steady state every drain cycle ends with the queue empty. An empty
`Array` can still retain its peak allocation, however, so the old
`removeAll(keepingCapacity: true)` behavior allowed one exceptional burst to
pin that capacity for the lifetime of a Store. The queue can also grow without
a semantic cap **inside a single drain cycle** when producers outpace reducer
work.

Real workloads that can hit this window:

- a market-data WebSocket forwarding hundreds of price ticks per second through `await send(.tick(...))`
- a bulk-import pipeline that translates every parsed row into an action
- a sensor fan-out where multiple actors emit independent updates into the same store

In all of these the queue can balloon for the duration of a single drain even though `finishDrain()` always brings it back to zero afterwards. We have repeatedly considered whether the queue should adopt a back-pressure policy (drop oldest, collapse equal payloads, hard cap with a configurable instrumentation event) so that misuse does not silently retain unbounded memory mid-cycle.

## Options Considered

### 1. Keep the queue policy-free and retain peak storage indefinitely

Pros:

- avoids allocation churn after an exceptional burst
- aligns with the broader InnoFlow rule that domain meaning lives in reducers, not runtime primitives — the queue cannot decide which action is "old" or "redundant" without leaking domain knowledge
- keeps the queue implementation minimal
- already supplies the right primitives upstream — `EffectTask.throttle`, `EffectTask.debounce`, batching reducers, or per-token sums in `Reduce` — so a domain that can produce burst traffic can also describe how to compress it

Cons:

- one exceptional burst can pin a large allocation until Store deinit
- action emission totals do not reveal actual queue pressure

### 2. Built-in action dropping or collapsing

Considered: drop oldest, collapse `Equatable` duplicates, hard cap with a `Sendable` instrumentation event.

Pros:

- one place to enforce a global memory ceiling
- arguably less work for downstream owners

Cons:

- "old" / "duplicate" are domain decisions; the queue cannot tell whether two `tick(price:)` actions can collapse without understanding the price-tick contract
- adding a hard cap in the runtime hides the back-pressure mistake instead of surfacing it (the dropped action is silently absent from the reducer trace)
- expands the queue's public surface so every change has to argue against this policy table
- the failure mode (mid-cycle memory growth) is fundamentally bounded by the cycle: once the reducer drains, memory falls back to baseline. A runtime cap protects only the worst-case runaway, but the steady-state already self-bounds

### 3. Keep lossless semantics, bound retained storage, and expose pressure

Pros:

- preserves FIFO delivery and every action
- releases exceptional allocation after a drain while reusing normal capacity
- distinguishes producer backlog from contiguous-storage high-water
- gives production metrics enough signal to place domain back-pressure

Cons:

- a burst may still allocate above the budget while it is in flight
- unusually large but repeated bursts may allocate again on each drain

## Decision

Choose option 3: **the queue stays lossless and domain-policy-free, but memory
retention is runtime policy.** Consumed prefixes are compacted during long
drains. `finishDrain()` retains no more than an estimated 64 KiB of contiguous
queue storage; larger allocations are released. Every drain emits one
`ActionQueueEvent` with processed count, pending/storage high-water marks,
retained capacity/bytes, and the capacity-release decision.

## Consequences

- `StoreActionQueue` clears on every `finishDrain()` call and cannot retain an
  exceptional allocation above the byte budget across cycles.
- `InnoFlowTesting.ActionQueue` mirrors the same 64 KiB estimated retained
  storage budget when its buffer becomes empty, so burst-heavy tests do not
  pin exceptional allocations for the lifetime of a `TestStore`.
- The queue still has no in-flight hard cap. It never drops, reorders, or
  collapses an action.
- High-volume domains (real-time price feeds, sensor fan-out, bulk imports) must opt into back-pressure explicitly:
  - `EffectTask.throttle(id:for:leading:trailing:)` for sampling
  - `EffectTask.debounce(id:for:)` for collapsing trailing edges
  - a domain reducer that aggregates many events into one action
  - or splitting the high-volume effect into its own store with its own cancellation boundary
- Observe `actionQueuePendingHighWaterMark`,
  `actionQueueStorageHighWaterMark`, and `actionQueueCapacityReleases` from
  `StoreInstrumentationMetricsCollector.snapshot()` and add domain-level
  back-pressure where the pending rate is highest.
- `StoreActionQueue.swift` carries a one-line pointer to this ADR so future contributors land in this discussion before reopening the policy question.
