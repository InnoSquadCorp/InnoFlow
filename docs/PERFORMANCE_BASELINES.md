# Performance Baselines

InnoFlow keeps performance checks deliberately narrow. Baselines should catch
large runtime regressions without turning normal CI variance into noise.

## Gates

- `EffectTimingBaselineGate` is a release-mode capture integrity check for
  effect scheduling. It records non-blocking mean/p95 timing regressions but
  only fails CI when the timing recorder capture or comparison is malformed.
- `PhaseMapPerfTests` are opt-in local benchmarks for phase dispatch shape.
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
