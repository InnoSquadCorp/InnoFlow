# Effect Timing Baseline

Use `EffectTimingRecorder` when you need a lightweight regression signal for
effect scheduling behavior across release builds.

The committed fixture lives at
`Tests/InnoFlowTests/Fixtures/EffectTimings.baseline.jsonl`. The dedicated
release gate in `EffectTimingBaselineGate` replays a fixed workload, records a
fresh JSONL capture, and compares that capture to the committed baseline with
`scripts/compare-effect-timings.sh`.

That release gate blocks on capture integrity only and reports metric
regressions as non-blocking trend output. Use
`scripts/report-effect-timing-trend.sh` when you want the same mean signal plus
stricter p95 reporting for maintainer review.
For the broader maintainer policy on when to refresh or interpret baselines,
see `docs/PERFORMANCE_BASELINES.md`.

This article explains:

- when the baseline gate is the right tool
- how to attach the recorder to a `Store`
- how to read the JSONL output
- how comparison works
- how to regenerate the committed baseline fixture

## When To Use It

Use the timing baseline when you need to verify that runtime instrumentation can
still capture broad scheduling signals such as:

- release-only scheduling drift after optimizer or actor-hop changes
- unexpectedly longer effect runs for the same fixed workload
- regressions where `.run` pipelines stop draining as expected

Do not use it for feature-level latency budgets, user-visible SLA checks, or
fine-grained microbenchmarks. The baseline is intentionally coarse. It exists
to answer "did the runtime get materially worse for the same synthetic probe?"
not "did this feature get 4% faster?"

For reducer-construction and dispatch microbenchmarks, use the local-only
`ReducerCompositionPerfTests` tooling instead.

## Attach The Recorder To A Store

`EffectTimingRecorder` is store instrumentation. Build the recorder, combine it
with any other instrumentation, then pass that instrumentation into the `Store`
initializer.

```swift
import InnoFlow
import InnoFlowTesting

let recorder = EffectTimingRecorder()
let witness = EffectInstrumentationWitness()

let store = Store(
  reducer: EffectTimingBaselineProbeFeature(),
  instrumentation: .combined(
    recorder.instrumentation() as StoreInstrumentation<EffectTimingBaselineProbeFeature.Action>,
    witness.instrumentation()
  )
)

store.send(.start)
let entries = await recorder.entries()
try await recorder.dumpJSONL(to: outputURL)
```

The baseline probe uses both instruments for different reasons:

- `EffectTimingRecorder` captures structured timestamps for JSONL output.
- `EffectInstrumentationWitness` confirms the workload actually reached the
  expected run-started/run-finished pairs before comparison begins.

That combination keeps the fixture capture deterministic without forcing the
timing recorder itself to own assertion logic.

## JSONL Shape

The recorder writes one JSON object per line. Each record includes:

- `sequence`: monotonically increasing run identifier
- `phase`: timing phase such as `runStarted` or `runFinished`
- `timestampNanos`: monotonic timestamp in nanoseconds
- `effectID`: optional effect identifier
- `actionLabel`: optional action label

For the baseline comparison, only matched `runStarted` / `runFinished` pairs
matter. The comparison script groups records by `sequence`, discards incomplete
pairs, then computes a run duration:

```text
durationNanos = runFinished.timestampNanos - runStarted.timestampNanos
```

The committed fixture currently contains 10 matched runs because the probe
feature performs 10 identical start/reset cycles.

## How Comparison Works

`scripts/compare-effect-timings.sh` reads two JSONL files:

- a committed baseline fixture
- a fresh capture from the current run

It computes one scalar metric from each distribution:

- `p95` for standalone script comparisons
- `mean` for the dedicated release-gate trend

The release gate reports `mean` because a 10-run fixture makes `p95` collapse to
the slowest single run, which proved too noisy on CI runners. The standalone
script still supports `p95` when you want a stricter local percentile check.

The comparison is relative, not absolute:

```text
ratio = (currentMetric - baselineMetric) / baselineMetric
```

If `ratio` exceeds the configured tolerance, the script exits `1` and prints a
structured regression payload on stderr. Usage errors, malformed JSONL, and
incomplete captures exit `2`.

The gate contract itself is documented in
`Tests/InnoFlowTests/Fixtures/EffectTimings.baseline.meta.json`, which records
the fixed run count, metric, tolerance, and baseline-refresh posture.

## Regenerate The Baseline

When CI hardware changes or the fixed probe workload changes materially,
regenerate the committed baseline instead of loosening the gate blindly.

From the repository root:

```bash
INNOFLOW_WRITE_EFFECT_BASELINE=Tests/InnoFlowTests/Fixtures/EffectTimings.baseline.jsonl \
swift test --package-path . \
  --build-path .build-effect-baseline-refresh \
  -c release \
  -Xswiftc -warnings-as-errors \
  --filter EffectTimingBaselineGate
```

`INNOFLOW_WRITE_EFFECT_BASELINE` switches the gate into export mode. In that
mode the test still runs the probe workload and validates that it produced the
expected matched runs, but instead of comparing with the committed fixture it
writes the freshly recorded JSONL to the path you provide.

After regeneration:

1. Inspect the diff in `EffectTimings.baseline.jsonl`.
2. Re-run `scripts/compare-effect-timings.sh` manually if you want a direct
   sanity check against the previous fixture.
3. Run `scripts/report-effect-timing-trend.sh` if you want non-blocking mean
   and p95 deltas from a fresh capture. That script still exits hard for
   malformed or incomplete data, so a broken capture does not masquerade as an
   ordinary slowdown.
4. Run the dedicated release gate again in compare mode before merging.

## Manual Comparison

To compare a fresh dump directly:

```bash
./scripts/compare-effect-timings.sh \
  --baseline Tests/InnoFlowTests/Fixtures/EffectTimings.baseline.jsonl \
  --current /tmp/current-effect-timings.jsonl \
  --metric mean \
  --tolerance 1.0
```

Use `mean` when you want behavior close to the release-gate trend. Use `p95` when
you want a stricter local check on the slow tail.

To print both signals without turning them into a blocker:

```bash
./scripts/report-effect-timing-trend.sh
```

## Related Material

- <doc:GettingStarted>
- <doc:PhaseDrivenModeling>
- [Cross-Framework Boundaries](https://github.com/InnoSquadCorp/InnoFlow/blob/main/docs/CROSS_FRAMEWORK.md)
- [Dependency Patterns](https://github.com/InnoSquadCorp/InnoFlow/blob/main/docs/DEPENDENCY_PATTERNS.md)
- [Performance Baselines](https://github.com/InnoSquadCorp/InnoFlow/blob/main/docs/PERFORMANCE_BASELINES.md)
