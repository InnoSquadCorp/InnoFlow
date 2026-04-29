# Instrumentation Cookbook

`StoreInstrumentation` observes effect runtime events without changing reducer
or effect semantics. Keep adapters thin: convert InnoFlow events into the
logging, tracing, or metrics backend owned by the app.

## Capture Events In Tests

```swift
actor EventBuffer<Action: Sendable> {
  private(set) var events: [StoreInstrumentationEvent<Action>] = []

  func append(_ event: StoreInstrumentationEvent<Action>) {
    events.append(event)
  }
}

let buffer = EventBuffer<Feature.Action>()

let store = Store(
  reducer: Feature(),
  instrumentation: .sink { event in
    Task { await buffer.append(event) }
  }
)
```

Use `.sink` when tests or diagnostics need the raw event stream.

## Write OSLog Entries

```swift
import OSLog

let logger = Logger(subsystem: "com.example.app", category: "Feature")

let store = Store(
  reducer: Feature(),
  instrumentation: .osLog(logger: logger)
)
```

Use `.osLog` for lightweight local diagnostics and Console inspection.

## Add Instruments Signposts

```swift
import OSLog
import os

let signposter = OSSignposter(
  logger: Logger(subsystem: "com.example.app", category: "FeatureTiming")
)

let store = Store(
  reducer: Feature(),
  instrumentation: .signpost(
    signposter: signposter,
    name: "Feature.effect",
    includeActions: false
  )
)
```

Keep `includeActions` false unless action payloads are safe to show in traces.
The signpost adapter opens intervals for effect runs and emits inline events
for action emissions, drops, and cancellations.

## Fan Out To Multiple Adapters

```swift
let instrumentation: StoreInstrumentation<Feature.Action> = .combined(
  .osLog(logger: logger),
  .signpost(signposter: signposter, name: "Feature.effect"),
  .sink { event in
    metrics.record(event)
  }
)
```

Use `.combined` when the app wants both human-readable logs and backend-owned
metrics or traces.

## Adapter Boundaries

- InnoFlow owns the runtime event vocabulary.
- The app owns backend naming, tags, sampling, and privacy policy.
- Optional ecosystem packages can wrap `.sink` later without changing core.
