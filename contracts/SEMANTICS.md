# InnoFlow cross-platform semantics

This document defines the portable behavior used by the platform-native
implementations. Public APIs, lifecycle integration, and release versions stay
native to each platform. The Swift implementation follows `main`, whose
published API baseline is 6.0.2. Its own contracts remain the source of truth
when they differ from the Kotlin or TypeScript runtime.

## Portable reducer contract, version 1

1. An admitted action is reduced once against the latest committed state,
   unless its dispatch is cancelled or fails before reduction.
2. Reducers are synchronous and describe effects instead of running side
   effects directly.
3. Actions are serialized. An action sent by an effect re-enters the same
   reducer queue.
4. Cancellation IDs implement latest-wins work without cancelling unrelated
   work.
5. Navigation stacks, transport/session lifecycle, and dependency-graph
   construction remain outside InnoFlow.
6. Platform adapters observe state and send actions. They never introduce a
   second mutable source of truth.

The fixtures under `contracts/conformance` exercise this portable reducer
contract. They intentionally do not require the three implementations to share
source code or identical API spelling.

## Kotlin and TypeScript runtime contract, version 1

The new Kotlin and TypeScript 1.0 runtimes additionally guarantee:

1. `send` returns a task representing one root action, its effects, and the
   descendant actions sent by those effects.
2. Awaiting the task waits for that dispatch tree. Cancelling it affects that
   tree, not an unrelated root dispatch.
3. Reducer or uncancelled effect failures fail the owning task. The store stays
   available for later independent dispatches.
4. Output is typed, ephemeral, and delivered only to live observers. Data that
   must survive recreation or render later belongs in state. Kotlin reports an
   output dropped because a live collector cannot keep up through
   instrumentation.
5. Closing a store cancels active dispatches and effects and rejects later
   sends. TypeScript releases its callbacks; Kotlin output collection ends.
   Kotlin `StateFlow` keeps its last value and is non-terminating by design,
   so state collectors must have a lifecycle-owned scope.
6. The action queue defaults to 1,024 entries and has a configurable positive
   `actionCapacity`. Synchronous admission when full fails the returned task
   with `FlowQueueFullException` (Kotlin) or `FlowQueueFullError` (TypeScript).
   It never evicts an older accepted action. Kotlin effect sends suspend for
   capacity; TypeScript drains synchronously, including reentrant actions.
   Queue instrumentation exposes processed count and a pending-action
   high-water mark. The queue bound is not a global cap on active effects or
   producers suspended waiting for admission; callers must bound fan-out.
7. Cancelling an effect ID cancels every active effect using that ID, including
   runs started without latest-wins replacement. Unrelated IDs remain active.

Tasks settle immediately on failure or cancellation and suppress later
actions/outputs from that dispatch. This is logical cancellation, not forced
termination of user code: effects must cooperate with coroutine cancellation
or `AbortSignal` to release their external resources. Reducers cannot be
interrupted mid-call. Task completion is not an acknowledgement that an
asynchronous output observer has processed an event.

State values are immutable snapshots owned by the application. Reducers must
return new values rather than mutate shared objects; the runtime neither deep
copies state nor rolls back in-place mutations after a reducer failure.

These guarantees extend the portable reducer contract. They do not redefine
the Swift implementation's behavior or public API.

## Authoring model

- Swift: `@InnoFlow` remains macro-first, with `InnoFlowCore` as the explicit
  compiler-plugin-free boundary.
- Kotlin: `@InnoFlow` plus KSP generates a store factory. `FlowFeature` and
  `FlowStore` remain available without KSP. Top-level public/internal classes
  and objects directly implementing `FlowFeature` are supported, including
  default packages and escaped identifiers. Private/protected, nested,
  generic, abstract and indirect feature declarations produce diagnostics;
  they can use explicit store construction where their own shape permits it.
- TypeScript: `defineFlow` is the declaration-first boundary. No custom
  compiler transform is required; TypeScript exhaustiveness and standard
  package tooling remain intact.
