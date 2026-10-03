# Effect execution consumer

This independent Core-only package enables NonisolatedNonsendingByDefault.
Its executable verifies main-queue separation for run, perform, and scheduled
operations, a legacy-shaped Sendable operation function value, UInt serial
capacity, exhaustive new admission cases, and on-demand lane snapshot reads.

Set INNOFLOW_CONSUMER_PACKAGE_PATH to select an alternate candidate package,
including a documented platform-validation mirror. Negative variants selected
by INNOFLOW_EFFECT_CONSUMER_NEGATIVE intentionally fail compilation:
capacity (negative UInt literal), admission (old exhaustive enum switch), and
removed-case (invalidCapacity). scripts/check-effect-execution-consumer.sh checks
the specific diagnostic for each failure, so an unrelated build failure cannot
masquerade as a successful negative control.

The fixture belongs outside the root package target graph. Exact pinned Apple
Swift 6.3/6.4 CI results remain required for release validation.
