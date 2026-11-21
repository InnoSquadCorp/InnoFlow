# Reading run-lane admission state

`Store.runLaneSnapshots(limit: 32)` is an opt-in MainActor read. Zero and negative
limits return an empty array. The reader receives a bounded list of current lane
reservations; the call creates no subscription or diagnostic history.

Each `EffectRunLaneSnapshot` contains an opaque `EffectRunLaneID`, the execution
policy, whether the head has start admission, the pending-request count, and
whether head cancellation was requested. The pending-request count includes
only requests that can still proceed: a request whose dispatch or ID was
cancelled is not counted, even before that cancellation reaches the scheduler. No raw EffectID, child instance ID,
action, state, or output is included. The opaque ID remains stable through serial
promotion and latest replacement while the lane is live. Closing and recreating
a lane creates a new identity. Equal user IDs in different Stores stay unrelated.

A `latest` request is accepted in the reduction turn that returns it, so the
run it replaces loses the lane at once. The lane is not listed again until the
replacement is admitted, which reopens it under the same identity. When the
replacement can no longer proceed, for example because its dispatch was
cancelled first, the lane is closed and the next request opens a new one.

These are admission snapshots. A superseded latest operation can ignore
cancellation and remain physically active after losing its lane reservation.
Use the StoreDiagnostics active-run aggregates for physical execution counts;
do not label the lane's admitted head as a complete count of running work.

An Inspector or other diagnostic view should weakly capture the Store in its
snapshot provider. For example, provide this closure to the Inspector's optional
lane-snapshot parameter:

```swift
{ [weak store] in
  store?.runLaneSnapshots(limit: 32) ?? []
}
```

The provider returns an empty list after Store release. Diagnostics do not hold
or recreate the Store. Snapshot formatting and sorting are paid only when the
reader explicitly requests a snapshot, outside action reduction and admission.
