# ADR: StoreActionQueue Burst Policy

## Status

Accepted

## Context

`StoreActionQueue` ([`Sources/InnoFlowCore/StoreActionQueue.swift`](../../Sources/InnoFlowCore/StoreActionQueue.swift)) is the single in-flight action buffer between effect emissions and reducer reentry. It is intentionally minimal:

- a `[StoreQueuedAction<Action>]` buffer plus a `head` cursor
- a `beginDrain()` reentrancy guard
- `finishDrain()` clears the buffer on every drain cycle (`removeAll(keepingCapacity: true)` + `head = 0`)

In the steady state every drain cycle ends with the queue empty, which means there is no memory-accumulation risk across cycles. The only window where the buffer can grow without bound is **inside a single drain cycle**: a high-volume `EffectTask.run` that emits many actions while the reducer is still processing earlier ones.

Real workloads that can hit this window:

- a market-data WebSocket forwarding hundreds of price ticks per second through `await send(.tick(...))`
- a bulk-import pipeline that translates every parsed row into an action
- a sensor fan-out where multiple actors emit independent updates into the same store

In all of these the queue can balloon for the duration of a single drain even though `finishDrain()` always brings it back to zero afterwards. We have repeatedly considered whether the queue should adopt a back-pressure policy (drop oldest, collapse equal payloads, hard cap with a configurable instrumentation event) so that misuse does not silently retain unbounded memory mid-cycle.

## Options Considered

### 1. Keep the queue policy-free; treat back-pressure as a domain concern

Pros:

- preserves the single-cycle empty invariant: every drain returns to zero
- aligns with the broader InnoFlow rule that domain meaning lives in reducers, not runtime primitives — the queue cannot decide which action is "old" or "redundant" without leaking domain knowledge
- keeps the queue trivial to reason about (44 lines today) and predictable for fuzz/property tests
- already supplies the right primitives upstream — `EffectTask.throttle`, `EffectTask.debounce`, batching reducers, or per-token sums in `Reduce` — so a domain that can produce burst traffic can also describe how to compress it

### 2. Built-in policy options on the queue

Considered: drop oldest, collapse `Equatable` duplicates, hard cap with a `Sendable` instrumentation event.

Pros:

- one place to enforce a global memory ceiling
- arguably less work for downstream owners

Cons:

- "old" / "duplicate" are domain decisions; the queue cannot tell whether two `tick(price:)` actions can collapse without understanding the price-tick contract
- adding a hard cap in the runtime hides the back-pressure mistake instead of surfacing it (the dropped action is silently absent from the reducer trace)
- expands the queue's public surface so every change has to argue against this policy table
- the failure mode (mid-cycle memory growth) is fundamentally bounded by the cycle: once the reducer drains, memory falls back to baseline. A runtime cap protects only the worst-case runaway, but the steady-state already self-bounds

## Decision

Choose option 1: **the queue stays policy-free.** Domains that can emit burst traffic should compress at the boundary that knows the meaning of that traffic — typically `EffectTask.throttle`/`debounce`, or a custom collapsing reducer.

## Consequences

- `StoreActionQueue` continues to clear on every `finishDrain()` call. There is no across-cycle accumulation risk; mid-cycle accumulation is bounded by the reducer's draining speed.
- High-volume domains (real-time price feeds, sensor fan-out, bulk imports) must opt into back-pressure explicitly:
  - `EffectTask.throttle(id:for:leading:trailing:)` for sampling
  - `EffectTask.debounce(id:for:)` for collapsing trailing edges
  - a domain reducer that aggregates many events into one action
  - or splitting the high-volume effect into its own store with its own cancellation boundary
- If the burst window itself becomes a memory concern in production, observe `StoreInstrumentationMetricsCollector.snapshot().actionEmitted` between drain cycles and add domain-level back-pressure where the rate is highest. The runtime layer remains intentionally unaware of which actions are compressible.
- `StoreActionQueue.swift` carries a one-line pointer to this ADR so future contributors land in this discussion before reopening the policy question.
