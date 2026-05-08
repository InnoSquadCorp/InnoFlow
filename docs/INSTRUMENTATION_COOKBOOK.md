# Instrumentation Cookbook

`StoreInstrumentation` observes effect runtime events without changing reducer
or effect semantics. Keep adapters thin: convert InnoFlow events into the
logging, tracing, or metrics backend owned by the app.

## Effect Run Failures

`StoreInstrumentation.didFailRun` surfaces non-cancellation errors thrown from
`EffectTask.run(sequence:)` (and the `transform` overload) that previously
terminated the effect silently. Cancellation still propagates without firing
the hook so cooperative shutdown paths stay clean.

```swift
let instrumentation: StoreInstrumentation<Feature.Action> = .init(
  didFailRun: { event in
    metrics.increment(
      "feature.effect.failed",
      tags: [
        "errorType": event.errorTypeName,
        "cancellationID": event.cancellationID?.description ?? "<none>"
      ]
    )
    logger.error(
      "effect failed: \(event.errorTypeName) — \(event.errorDescription)"
    )
  }
)
```

`RunFailedEvent` carries the error as `errorDescription` and `errorTypeName`
(both `String`) instead of `any Error`, so adapters cannot accidentally cross
the Swift 6 `Sendable` boundary by capturing the original error reference.

## Capture Events In Tests

```swift
actor EventBuffer<Action: Sendable> {
  enum Timeout: Error {
    case timedOut
  }

  private(set) var events: [StoreInstrumentationEvent<Action>] = []
  private var nextWaiterID = 0
  private var waiters:
    [Int: (count: Int, continuation: CheckedContinuation<[StoreInstrumentationEvent<Action>], Error>)] = [:]

  func append(_ event: StoreInstrumentationEvent<Action>) {
    events.append(event)
    resumeReadyWaiters()
  }

  func waitForEvents(
    count: Int,
    timeout: Duration = .seconds(1)
  ) async throws -> [StoreInstrumentationEvent<Action>] {
    if events.count >= count {
      return events
    }

    let waiterID = nextWaiterID
    nextWaiterID += 1

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        waiters[waiterID] = (count, continuation)
        Task {
          try await Task.sleep(for: timeout)
          await failWaiter(waiterID, with: Timeout.timedOut)
        }
      }
    } onCancel: {
      Task {
        await failWaiter(waiterID, with: CancellationError())
      }
    }
  }

  private func resumeReadyWaiters() {
    let readyWaiterIDs = waiters
      .filter { events.count >= $0.value.count }
      .map(\.key)

    for waiterID in readyWaiterIDs {
      waiters.removeValue(forKey: waiterID)?.continuation.resume(returning: events)
    }
  }

  private func failWaiter(_ waiterID: Int, with error: Error) {
    waiters.removeValue(forKey: waiterID)?.continuation.resume(throwing: error)
  }
}

let buffer = EventBuffer<Feature.Action>()

let store = Store(
  reducer: Feature(),
  instrumentation: .sink { event in
    Task { await buffer.append(event) }
  }
)

store.send(.load)
let events = try await buffer.waitForEvents(count: 2)
#expect(events.count == 2)
```

Use `.sink` when tests or diagnostics need the raw event stream, and wait on
the buffer instead of sleeping so assertions only run after the async sink has
observed the expected events.

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
