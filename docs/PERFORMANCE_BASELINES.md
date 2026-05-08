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

For most apps the registry is dominated by collection scopes — `ForEachReducer` rows produce one `ScopedStore` per identifiable element. Memory therefore scales with active row count × per-row child-state size, not with the parent state size. Discard row handles on removal so the registry releases the entry; see [`docs/adr/ADR-store-action-queue-burst.md`](adr/ADR-store-action-queue-burst.md) for related ownership notes.

### Scope cache hit ratio

Collection scoping caches the per-element snapshot keyed by `Identifiable.ID`. The cache is hit when the same row receives an action and miss when the parent collection layout changed (insert/remove/reorder).

- a steady-state list with infrequent edits trends toward 100% hit ratio after warm-up
- frequent reorders or pagination boundaries force misses, which is correct behavior — the cache is invalidated only when the underlying element identity or value changed
- if hit-ratio profiling shows pathological misses, suspect feature code that recreates rows on every dispatch (mutating `[Item]` to a fresh array of equivalent values), not the scope cache itself

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
