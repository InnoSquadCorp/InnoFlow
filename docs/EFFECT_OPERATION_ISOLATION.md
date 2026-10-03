# Explicit effect execution isolation

The asynchronous operation types accepted by run, scheduled run, perform, and
AsyncSequence run factories explicitly use `@concurrent @Sendable`. The same
function type is retained through effect storage, action mapping, the shared
walker, and both host drivers. User operations therefore switch away from the
caller's actor, including when a consumer enables NonisolatedNonsendingByDefault.
Synchronous reducers remain MainActor-owned through Store; this does not create a
headless Store or move state mutation out of the reducer queue.

This is an explicit execution contract, not a request to use a particular thread.
Operations may hop to another actor with await. Data captured across those
boundaries still has to satisfy Swift's Sendable and isolation rules. Send and
EffectContext service callbacks retain their own existing delivery semantics.

Swift's [SE-0461](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md)
specifies concurrent function types and their conversions. The language feature
shipped in [Swift 6.2](https://www.swift.org/blog/swift-6.2-released/), before this
package's minimum toolchain. Actual pinned Swift 6.3 and 6.4 consumer/runtime jobs
still provide release evidence; language documentation does not replace them.

## Compatibility and verification

Ordinary inline run/perform closures keep their spelling. Async operations must
not depend on inheriting the caller's actor; explicitly await actor-isolated work.
Consumer fixtures exercise direct run, perform, scheduled run, and mapped
AsyncSequence factories under the upcoming feature flag. Focused tests check both
Store and TestStore from MainActor. The pre-change consumer-only-flag probe already
passed, so this change is classified as explicit API hardening, not proof of an
existing executor defect.

The package-wide NonisolatedNonsendingByDefault flag is not enabled by this change.
Adopting it changes unrelated async API defaults and requires its own full matrix,
sanitizer, and benchmark comparison. Pinning effect operation isolation does not
require that broader adoption.

The production source gate rejects unchecked Sendable declarations, unsafe
nonisolation, assume-isolated calls, and preconcurrency imports. Its selftest covers
a safe control, every prohibited spelling, and a missing source directory.

The durable Core-only consumer is Tests/Fixtures/EffectExecutionConsumer. The
full principle-gates CI path runs its positive executable with the upcoming
feature enabled, then requires specific compile failures for the 6.0 unsigned
capacity and admission-enum migration controls. The static gate path remains
build-free.

A focused Swift 6.4 Linux evaluation also enabled the upcoming flag in the Core
module itself. Core compiled and the same external consumer still executed its
operations off the main dispatch queue. A mutation control removed only the
explicit concurrent annotations in that scratch copy: it compiled, but the
consumer's off-main precondition then failed on the main queue. This establishes
the protection against that future configuration change. It is not a failure of
the current default configuration, and it does not supply Apple-platform,
Swift 6.3, sanitizer, or comparative performance evidence for adopting the flag
package-wide.
