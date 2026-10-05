# Collection lifetime and Sendable key-path contracts

This independent Core-only package checks existing IfCaseLet constructor calls,
the explicit lifetimeID overload, and a closure adapter for the old initializer
function type. The negative source must reject an unwrapped previous four-argument
initializer reference because the canonical initializer now captures source
coordinates. CasePath's cache identity remains unchanged.

The positive consumer also executes Scope, IfLet, ForEachReducer,
ForEachIdentifiedReducer, OptionalChildLifetime / optionalChild, and PhaseMap
with ordinary literals, explicitly Sendable hoisted paths (including aliases),
and Sendable struct subscript indices. Twelve separately compiled negative
consumers cover the six API boundaries with erased hoisted paths and captured
non-Sendable class indices. Each failure must be the expected Sendable diagnostic
in the consumer, not a dependency or tooling failure.

When retaining a path, preserve its marker, for example
`let path: any WritableKeyPath<State, Child> & Sendable = \.child`.
A plain `WritableKeyPath` type alias erases this marker; callers must preserve
`& Sendable` through aliases and generic helpers too.

Run scripts/check-collection-lifetime-consumer.sh. For an explicitly documented
validation mirror, set INNOFLOW_CONSUMER_PACKAGE_PATH to that package directory.
The Linux mirror does not replace the pinned Apple compiler and release checks.
