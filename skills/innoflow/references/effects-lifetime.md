# Effects, output, and ownership

These are the tagged 6.0.0 contracts. For another stable 6.0.x patch, inspect relevant fixes and test the affected consumer.

## Effects and errors

For a single throwing operation, prefer `.perform(operation:success:failure:)` and explicit result actions. While the host remains active, every thrown error, including a directly thrown `CancellationError`, maps to the failure action. Accepted task/dispatch/runtime cancellation is silent. The error's type alone is not an explicit cancellation request.

Use `.run` for custom async action sequences or context-controlled clocks, with `send` and `EffectContext`. Its `(send, context)` closure is nonthrowing: handle throwing calls inside it with `do/catch`; do not put an unhandled `try await` directly in that closure. Catch domain failures and send a failure action when the UI/domain needs recovery. Do not treat `.run` as having the same error mapping as `.perform`, or use fire-and-forget `Task.detached` to mutate Store state.

`.cancellable(id, cancelInFlight: true)` owns work by an effect ID. A stable ID can intentionally replace prior work; avoid sharing it across unrelated tasks. `.cancel(id)` cancels that work. Effect IDs and `DispatchID` serve different purposes; DispatchID is correlation metadata.

## Dispatch and lexical scope

| Need | Contract |
| --- | --- |
| Wait for one action tree | `let task = store.send(action); await task.finish()` follows descendant effects/actions |
| Cancel just that tree | `task.cancel()` then `await task.finish()`; completed state mutations are not rolled back |
| Own a group of dispatches | Create with `withFlowScope`, register with `await scope.track(...)`; scope exit cancels and joins only registered unfinished work |
| Abandon an untracked handle | Dropping it does not imply cancellation; choose explicit ownership |

`FlowScope` cannot be constructed directly. Scope closure on normal return, error, or caller cancellation leaves sibling/untracked work independent. Cooperative cancellation still requires the operation to return; a lane or scope cannot force arbitrary external work to stop.

The [consumer tests](../assets/consumer/Tests/FlowSkillExampleTests/ConsumerTests.swift) verify individual cancellation with a surviving sibling, scope cleanup with untracked work, and dispatch finish after manual time advances.

## Typed output

Emit one-shot app/coordinator intent through nested `Output` and `Self.output(...)`; navigation state and restorable UI data remain outside that event stream or in persistent `State` as appropriate.

Store-wide `outputs()` is live and non-replaying: subscribe before sending. For one action tree, `store.send(action, capturingOutputs: bufferingPolicy)` installs capture before enqueue, including synchronous output, and returns `OutputFlowTask`. Choose a buffer policy for expected volume; the stream is single-consumer and ends with the dispatch tree. Cancelling its awaiting task cancels that dispatch. Breaking iteration while retaining the stream requires an explicit `cancel()` to abandon work. Consume and assert outputs in `TestStore` separately from actions.

## Scheduled runs and diagnostics

Use `.run(id:policy:onAdmission:operation:)` when dispatches contend for a Store-local resource. `.latest` cooperatively replaces work; `.dropWhileRunning` can reject as busy; `.serial(maxPending:)` has a bounded `UInt` queue. Observe admission and handle rejection/supersession rather than assuming every request ran. Serial means execution ordering, not transactions, retry, rollback, or exactly-once delivery. Running serial/drop lanes retain their physical slot until the operation returns.

`StoreDiagnostics(capacity:)` is opt-in, bounded, and payload-free. Keep sensitive domain data out of diagnostic labels or custom logging. Inspector and scheduler admission are not exercised by the small fixture; consult their exact tagged contracts and add task-specific tests.

Sources: [EffectTask and perform](https://github.com/InnoSquadCorp/InnoFlow/blob/188c2732d26350cf01afadade3dac89a2b73b68f/Sources/InnoFlowCore/EffectTask.swift), [FlowTask](https://github.com/InnoSquadCorp/InnoFlow/blob/188c2732d26350cf01afadade3dac89a2b73b68f/Sources/InnoFlowCore/FlowTask.swift), [FlowScope](https://github.com/InnoSquadCorp/InnoFlow/blob/188c2732d26350cf01afadade3dac89a2b73b68f/Sources/InnoFlowCore/FlowScope.swift), [orchestration ADR](https://github.com/InnoSquadCorp/InnoFlow/blob/188c2732d26350cf01afadade3dac89a2b73b68f/docs/adr/ADR-effect-admission-and-flow-lifetime.md), [instrumentation cookbook](https://github.com/InnoSquadCorp/InnoFlow/blob/188c2732d26350cf01afadade3dac89a2b73b68f/docs/INSTRUMENTATION_COOKBOOK.md).
