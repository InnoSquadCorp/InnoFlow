# Independent consumer benchmark

This package is outside the root product dependency graph. Build it in release mode and invoke the executable with one scenario and a positive iteration count. INNOFLOW_BENCHMARK_PACKAGE can select an independently frozen candidate checkout. Each scenario validates its result before emitting JSON.

- S1: one synchronous send, no UI observers
- S2: one send and ten synchronous descendant actions (eleven reductions)
- S3: 1,000 retained collection projections, one row update; one-shot Observation callbacks rearmed for the changed row
- S4: 100 dependency-scoped selections and an unrelated state update
- S5: real SwiftUI BindableField binding update; unsupported platforms exit 2 with an explicit status
- S6: TestStore send/receive round trip
- S7: 1,000 retained key-path selections with distinct dependencies and an unrelated state update
- S8: 1,000 retained collection projections and a structural change that shifts every row offset
- R1: one run effect emitting one action, awaited to completion
- R2: one `cancelInFlight` replacement per iteration, awaited to completion
- diagnostics/output: bounded diagnostics and direct testing-output controls

S7, S8, R1 and R2 are local scaling probes. They are not part of the S1-S6 trend cohort or its comparison.

`run-local.sh` builds this package in release mode with the active `swift` and prints the median nanoseconds per iteration for each scenario. It exists for relative before/after measurements on one machine; it produces no release, adoption or regression evidence.

Set up stores/projections before the timed interval. Retain all observer handles. Alternate baseline/candidate order; preserve exact commits, toolchain, host, iteration counts and raw samples. Do not benchmark concurrently with builds or unrelated CPU-heavy work. Do not interpret a Linux lock adapter as Apple unfair-lock evidence, or compare its absolute latency with Apple-silicon targets. TCA comparison and Apple targets require the same Apple host/toolchain.
