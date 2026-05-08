# Swift Toolchain Workaround Tracker

This file lists every Swift toolchain workaround currently committed to the repository, together with the issue link, the verification path, and the trigger for retesting. The principle gates already emit a warning when a newer toolchain is detected ([`scripts/principle-gates.sh`](../scripts/principle-gates.sh) — `warn_if_optimize_none_workaround_should_be_retested`); this document makes the work item visible without requiring contributors to grep.

When a workaround is removed, delete the matching row, the corresponding source comment, and any version-gated branch. Do not silently leave dead code paths.

## Active workarounds

### `@_optimize(none)` on `Store.deinit`

- **Location:** [`Sources/InnoFlowCore/Store.swift`](../Sources/InnoFlowCore/Store.swift) (around the `isolated deinit` block)
- **Symptom:** Swift 6.3 release optimization crashes in `EarlyPerfInliner` (`isCallerAndCalleeLayoutConstraintsCompatible`) when scanning the generic `R.Action`-typed `Store` for inlining candidates.
- **Upstream issue:** [swiftlang/swift#88173](https://github.com/swiftlang/swift/issues/88173)
- **Why this is the right surface:** the deinit is **not** a hot path (lifetime markRelease + bridge.shutdown only), so the lost optimization is negligible. Lifecycle semantics (`@MainActor isolated deinit`) are unchanged.
- **Retest trigger:** Swift 6.4 GA, or earlier when the linked issue closes.
- **Retest steps:**
  1. Remove `@_optimize(none)` and the trailing `https://github.com/swiftlang/swift/issues/88173` block.
  2. Run `swift build -c release` and `swift test -c release` — the original crash reproduces during release builds, not debug.
  3. Run `./scripts/principle-gates.sh` end-to-end on the same toolchain to make sure the wider matrix passes.
  4. If it still reproduces, restore the attribute and update this row's *Retest trigger* to the next reasonable Swift version.
  5. If it does not reproduce, also remove the matching workaround on `TestStore.deinit` (next row) and the warning emitter `warn_if_optimize_none_workaround_should_be_retested` in `scripts/principle-gates.sh`.

### `@_optimize(none)` on `TestStore.deinit`

- **Location:** [`Sources/InnoFlowTesting/TestStore.swift`](../Sources/InnoFlowTesting/TestStore.swift)
- **Symptom:** Same SIL `EarlyPerfInliner` crash as `Store.deinit`. Mirrored attribute keeps the test runtime aligned with the production runtime.
- **Upstream issue:** [swiftlang/swift#88173](https://github.com/swiftlang/swift/issues/88173)
- **Retest trigger / steps:** identical to `Store.deinit`. Remove the two attributes together — `Store` and `TestStore` should always agree on whether the workaround is required.

## How the principle gates surface this

[`scripts/principle-gates.sh`](../scripts/principle-gates.sh) reads `swift --version`, parses major/minor, and prints

```
[principle-gates] Warning: Swift X.Y detected; retest removing @_optimize(none) from Store/TestStore deinits (swiftlang/swift#88173).
```

when the toolchain is at or above 6.4. The warning is intentionally non-blocking — the workaround stays in source until a maintainer manually verifies the upstream fix.

## Adding a new workaround

When introducing a new compiler-quirk workaround:

1. Add a comment block at the source site with a one-line summary, the issue link, and a `Retest when` marker.
2. Add a row to this file with the *Location*, *Symptom*, *Upstream issue*, *Why this is the right surface*, *Retest trigger*, *Retest steps*. Future-you needs all of those.
3. If the toolchain version that fixes the bug is known, extend `warn_if_optimize_none_workaround_should_be_retested` (or write a sibling function) so the gates emit a warning at the right time.
4. Mention the workaround in the next [`CHANGELOG.md`](../CHANGELOG.md) entry under "Notes".

## Future automation

A weekly or monthly nightly job that boots the latest Swift toolchain, deletes every `@_optimize(none)` workaround locally, and reports failures could automate the retest. That work is intentionally out of this PR — CI workflow changes have a larger blast radius and need separate review. Track the idea here so it does not get lost.
