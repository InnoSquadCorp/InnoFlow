# SIL Crash Reproducer

This package isolates the Swift 6.3 release-build crash that requires
`@_optimize(none)` on `Store` and `TestStore` isolated deinits.

Run:

```bash
swift build --package-path Repro/SILCrashRepro -c release
```

On affected Swift 6.3 toolchains, the release build crashes in the SIL
`EarlyPerfInliner` while visiting an `@MainActor isolated deinit` on a generic
store that holds builder-composed reducer types. The closest upstream tracker is
[swiftlang/swift#88173](https://github.com/swiftlang/swift/issues/88173).

When moving to Swift 6.4 or newer, rerun this reproducer and try removing
`@_optimize(none)` from:

- `Sources/InnoFlow/Store.swift`
- `Sources/InnoFlowTesting/TestStore.swift`

If the reproducer and the main release build both pass without the workaround,
the workaround can be retired.
