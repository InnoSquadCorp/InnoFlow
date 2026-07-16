# Async Sequence Effects

Consume an `AsyncSequence` inside `EffectTask.run` when a feature needs to turn a stream of
domain events into actions.

## Overview

Use the sequence overload when an existing API already exposes an `AsyncSequence`:

```swift
return .run { context in
  websocket.messages(context: context)
}
.cancellable(EffectID(connectionID), cancelInFlight: true)
```

Each sequence element is emitted as the feature action. The sequence is created from the active
``/InnoFlowCore/EffectContext``, so stream implementations can use
``/InnoFlowCore/EffectContext/sleep(for:)`` and
``/InnoFlowCore/EffectContext/checkCancellation()`` to stay aligned with the store clock and cancellation
boundaries.

When the stream element is not already an action, use the transforming overload:

```swift
return .run(
  sequence: { context in
    notifications.events(context: context)
  },
  transform: { event in
    event.isRelevant ? .eventReceived(event) : nil
  }
)
```

Returning `nil` from the transform drops that element without ending the effect.

## Cancellation

Long-lived streams should still be scoped with `.cancellable(...)` or cancelled from the store
boundary. Dynamic identifiers are supported:

```swift
let streamID = EffectID(session.id)

return .run(sequence: makeEvents, transform: Action.event)
  .cancellable(streamID, cancelInFlight: true)
```

The helper calls ``/InnoFlowCore/EffectContext/checkCancellation()`` between elements. Runtime emission gates
still protect late actions that race with cancellation or store release.

## Failure Arbitration

A non-cancellation error escaping an active sequence is forwarded once to the
host failure channel: `StoreInstrumentation.didFailRun` for `Store`, or the
originating action assertion for `TestStore`. The host serializes that decision
against its MainActor cancellation boundary. If cancellation is accepted
first, a later domain error from an iterator that ignores cancellation is
discarded and the run is not reclassified as failed.
