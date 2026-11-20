# Scheduled-run admission in 6.0

Scheduled lanes remain Store-local. Optional-child lifetime wrappers additionally
namespace lanes by their captured child owner. Admission and physical execution
are separate: cancellation prevents new actions immediately, while a running
serial/drop operation keeps its slot until the operation actually returns.

## Cancellation and ordering

Admission checks the scheduled node's exact frozen execution context. This matters
when a concatenate waits on unrelated work before discovering a scheduled node:
an ID cancellation accepted during that wait must prevent the node from reserving
capacity or replacing a newer lane.

A live latest lane also rejects an older sequence. Same-sequence requests retain
arrival-order latest semantics. Sequence cancellation tokens cover deferred work
after newer requests have finished; the scheduler does not retain an unbounded
history of every ID ever used.

Serial promotion publishes the next reservation synchronously, but does not start
it until the driver attaches its task. Promotion and attachment share one start
boundary, so a request produces one started transition. Cancelling a pending
reservation returns queue capacity immediately, whether the cancellation comes
through an ID it carries or through its dispatch: a pending request that can
no longer proceed never counts toward capacity or the snapshot's pending
count, even before its cancellation reaches the scheduler, and it is released
through the same terminal transition as an explicit cancellation. Completing an
old or already removed ticket cannot remove a newer lane.

A `latest` request accepted in a reduction turn holds its lane as the open
`latest` lane under its ID until the request is admitted or can no longer
proceed: a lane it displaced keeps its identity, a lane that was closed gets
one when the request opens it, and a request with another policy is rejected
as conflicting.

The reduction turn that returns an effect decides each lane request it reaches
without awaiting against the lane state of that turn, with the same rule
admission applies (one side-effect-free decision function serves both). A
request the lane rejects, or whose own tree already cancelled its lane ID,
completes without awaiting, so the turn keeps accepting the cancellations
behind it, and the interpreter later reports exactly that outcome without
consulting the lane again. A request the lane admits awaits its run, so the
interpreter admits it against the lane it meets then. A request whose outcome
depends on the order of `merge` children (another branch requests the same
lane, cancels or requests the cancellation of one of its IDs, or requests the
cancellation of an ID carried by a request that holds the lane: a `latest`
lane's running request, the request a held lane waits for, or a serial lane's
pending request) is not decided in the turn at all; its admission decides it.

## Lifecycle observations

EffectAdmission includes started, queued(position:), rejected(reason),
cancelledBeforeStart, and superseded. Cancelled-before-start means cancellation
preceded start admission. Superseded identifies a request displaced by a newer
latest request, or a deferred older request that cannot displace the live lane.

Scheduler lifecycle observations belong to the affected request. Superseding a
request invokes that request's callback rather than the new request's callback.
Repeated cancellation and cleanup do not repeat the same terminal transition.
Runtime diagnostics remain payload-free. TestStore's testing-only effect ledger
can use these events for dispatch-specific assertions.

Cancellation still suppresses reducer actions. A cancelled request does not send
a final onAdmission action back through a closed execution context merely to
announce its cancellation. Terminal lifecycle records remain observable through
diagnostics and the testing ledger.

## Migration

The pending capacity of serial(maxPending:) is now UInt. queueFull(maxPending:)
carries the same unsigned type. Nonnegative integer literals continue to compile.
Code holding an Int configuration must validate it and convert it explicitly, for
example by testing UInt(exactly: configuration) before building the policy.
A negative literal is a compile-time error, and invalidCapacity is removed.

Exhaustive switches over EffectAdmission must handle cancelledBeforeStart and
superseded. Exhaustive switches over EffectAdmissionRejection must remove the
invalidCapacity branch. Public enum case additions are classified as major-version
API changes; this migration belongs to 6.0.

## Evidence boundary

The pre-change standalone scheduler probe reproduced deferred old latest work
cancelling the newer request, both with and without an explicit prior cancellation.
The direct scheduler probe also accepted sequence 1 after sequence 2 and cancelled
the newer ticket. Regression fixtures use explicit gates and ticket attachment,
with the same deferred-request scenario executed through Store and TestStore.
Focused Linux-mirror results do not replace the pinned Apple-toolchain matrix,
sanitizers, or exact-SHA Release Preflight evidence.
