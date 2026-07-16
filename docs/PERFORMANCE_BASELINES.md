# Performance Baselines

InnoFlow keeps performance checks deliberately narrow. Baselines should catch
large runtime regressions without turning normal CI variance into noise.

## Gates

- `EffectTimingBaselineGate` is a release-mode capture integrity check for
  effect scheduling. It records a fresh capture and compares mean timing only
  as a non-blocking timing trend, while malformed or incomplete captures remain
  blocking. Use `scripts/report-effect-timing-trend.sh` for standalone
  maintainer reporting that includes the stricter p95 metric.
- `PhaseMapPerfTests` are opt-in local benchmarks for phase dispatch shape.
- `ProjectionObserverRegistryPerfTests` are opt-in local benchmarks for observer
  fanout, always-refresh observers, and overlapping dependency buckets.
- `ReducerCompositionPerfTests` and `scripts/compare-reducer-composition-perf.sh`
  are maintainer tools for composition construction and dispatch experiments.

## Interpreting Failures

Treat a blocking baseline failure as evidence that the timing capture or
comparison pipeline is broken, not as proof that the last code edit is slow.
Metric regressions are reported as non-blocking trend output.

1. Re-run the same gate once on a quiet machine.
2. Check whether matched run counts are complete.
3. Compare the non-blocking trend output against the changed code path.
4. If the workload changed intentionally, regenerate the fixture in a dedicated
   commit and explain the reason.
5. If only CI hardware changed, regenerate only after confirming the new runner
   is stable.

Do not loosen tolerance to make noisy trend output disappear.

## Workload-specific Notes

Beyond the baseline gates, three runtime areas warrant rough budgets when planning new features:

### State diff cost

Reducer-driven state mutations propagate through `ProjectionObserverRegistry`, which compares previous vs. current state to decide whether to invalidate observers. The cost scales with the depth of `Equatable` structures rather than with collection size: each `Equatable` synthesized comparison walks every stored property.

- shallow value structs (a handful of scalars + one or two enums) compare in nanoseconds and stay below per-action profiling noise
- nested collections inside state (`[Item]`, `[ID: Item]`) move the cost to `O(item count × per-item Equatable depth)` per dispatched action
- if a feature mutates a large collection on every action, prefer `SelectedStore.select(dependingOn:)` with explicit slices to keep view-side comparison narrow

### Observer registry memory

`ProjectionObserverRegistry` stores one entry per active `ScopedStore` and `SelectedStore` projection. Each entry retains:

- the dependency key path set
- a cached snapshot for change detection
- a weak handle to the registered observer

For most apps the registry is dominated by collection scopes —
`Store.scope(collection:action:)` produces one `ScopedStore` per identifiable
element. Memory therefore scales with active row count × per-row child-state
size, not with the parent state size. Discard row handles on removal so the
registry releases the entry; see
[`docs/adr/ADR-store-action-queue-burst.md`](adr/ADR-store-action-queue-burst.md)
for related ownership notes.

### Scope cache hit ratio

Single-state scoping weakly caches a live projection by source location, state
key path, child types, and `CasePath` identity. A steady SwiftUI body that
repeats the same scope call reuses one `ScopedStore` and one parent observer;
reconstructing the `CasePath` intentionally misses the cache. Releasing every
external scope reference releases the projection. The next matching-signature
access prunes its dead cache entry before creating a current-state projection;
periodic cross-bucket maintenance during continued scoping bounds dead metadata
from other signatures, and a quiescent `Store` releases the remainder on deinit.

Collection scoping strongly caches one active row family per collection key
path, with rows keyed by `Identifiable.ID`. Child types and opaque
`CollectionActionPath` identity form the active signature across source
locations. A signature change replaces the complete family, bounding retained
row scopes to one path family while preventing stale action transforms.
Macro-generated stored static paths keep the steady-state cache hot;
generic/extension computed paths use a stable generated identity per
specialized root action type and private per-member marker, so repeated access
also keeps the active row family hot. Explicitly reconstructed paths remain
intentional signature changes. When an ID disappears, its row and offset leave
the active cache during the same parent refresh. Once external row handles are
gone, an off-screen or otherwise quiescent view does not need to scope again to
release removed-row state.

Within the active family, a row resolves in O(1) when its cached offset still
contains the same ID. If the ID moved, the resolver scans once by ID and updates
that row's offset for subsequent reads.

- a steady-state list trends toward 100% offset hits after warm-up
- insert, removal, and reorder operations miss only for rows whose cached offset no longer contains their ID
- value-only changes at a stable offset remain O(1), and rebuilding an equivalent array does not refresh collection observers

These are guidelines, not blocking gates. If a future change measurably moves any of them and the change is intentional, capture the new value as a fixture in a dedicated commit alongside `EffectTimingBaselineGate` style refresh.

## Refresh Policy

Refresh committed fixtures only when one of these is true:

- the fixed benchmark workload changed
- the supported toolchain materially changed scheduling behavior
- CI runner hardware changed and repeated runs prove the old fixture is stale
- an intentional optimization shifts the baseline and the new values were
  reviewed

Keep baseline refreshes separate from behavioral changes whenever possible.

## Local Commands

```bash
INNOFLOW_WRITE_EFFECT_BASELINE=Tests/InnoFlowTests/Fixtures/EffectTimings.baseline.jsonl \
swift test --package-path . \
  --build-path .build-effect-baseline-refresh \
  -c release \
  -Xswiftc -warnings-as-errors \
  --filter EffectTimingBaselineGate
```

```bash
INNOFLOW_PERF_BENCHMARKS=1 \
swift test --package-path . \
  --build-path .build-phase-map-perf \
  -c release \
  --filter PhaseMapPerfTests
```
