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
``EffectContext``, so stream implementations can use ``EffectContext/sleep(for:)`` and
``EffectContext/checkCancellation()`` to stay aligned with the store clock and cancellation
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

The helper calls ``EffectContext/checkCancellation()`` between elements. Runtime emission gates
still protect late actions that race with cancellation or store release.
