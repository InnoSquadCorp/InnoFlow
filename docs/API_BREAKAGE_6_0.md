# InnoFlow 6.0.0 API Breakage Classification

## Baseline and result

The 6.0.0 release candidate was compared with the public `5.1.1` tag using:

```bash
swift package diagnose-api-breaking-changes 5.1.1 \
  --products InnoFlow InnoFlowCore InnoFlowSwiftUI InnoFlowTesting
```

The command exited with status 1, as expected for this major release. The API
digester reported:

- `InnoFlow`: no breaking changes
- `InnoFlowCore`: 164 diagnostics
- `InnoFlowSwiftUI`: 1 diagnostic
- `InnoFlowTesting`: 21 diagnostics

The number of diagnostics is not the number of independent consumer
migrations. One generic signature change expands into many type, accessor,
builder, composition, and package-internal diagnostics.

## Consumer-facing major changes

1. `Reducer` now has a primary `Output` associated type. `Reduce`, reducer
   builders, composition operators, stores, and effect walking therefore carry
   that type. Features without outputs migrate to
   `some Reducer<State, Action, Never>`; output-producing features use their
   concrete output type and `ReducerEffect<Action, Output>`.
2. `Store.send(_:)` and `ScopedStore.send(_:)` return `FlowTask`. Ordinary
   statement-style calls remain source-compatible, while stored or passed
   method values explicitly typed as returning `Void` must be adjusted.
3. `TestStore` now checks typed outputs during exhaustive finishing.
   `TestStoreFinishResult` gains `unhandledOutputs`, and callers use
   `receiveOutput(_:)` to consume them.
4. `TestStore.assertNoMoreActions()` and its scoped forwarding overload are
   removed after their 5.x deprecation window. Use `finish()` or
   `assertNoBufferedActions()` according to lifecycle intent.
5. `StoreInstrumentationEvent` gains the `outputDelivered` case,
   `EffectTimingRecorder.Phase` gains `runFailed` and `outputDelivered`, and
   `StoreInstrumentationMetricsSnapshot` gains output-delivery counters.
   Exhaustive switches over either public event enum must handle the new cases.
   The new dispatch-capture and strict-phase APIs are additive.

The ordered 6.0 hardening pass also adds run-admission policies, `FlowScope`,
`DispatchID` correlation and bounded diagnostics, TestStore invariants and
scenarios, and macro-synthesized Output case paths. These APIs are additive;
they do not add another migration beyond the five changes above. Adoption is
explicit, and existing cancellation, action, output, and persistence ownership
continues to apply until a consumer opts into the new APIs.

These changes are intentional and are covered by [MIGRATION.md](../MIGRATION.md).

## Diagnostics that are not additional source migrations

- Most `EffectDriver`, `StoreEffectBridge`, queue, throttle, and walker entries
  describe `package` implementation details inheriting the new `Output` type.
  They are not callable from an external package.
- `StoreInstrumentation.signpost` and `osLog` gained a defaulted
  `includeCancellationIDs` argument. The digester models this as a rename, but
  existing source calls remain valid and retain the safer redacted default.
- The digester reports `EffectTask.animation(_:)` as removed because the
  extension moved from the no-output type alias to `ReducerEffect`. Existing
  `EffectTask<Action>.animation(_:)` source still resolves, and typed-output
  effects now preserve their `Output`. Runtime and compile-contract tests cover
  both forms.
- Dispatch correlation adds defaulted `dispatchID` parameters to public
  instrumentation entry initializers. The digester represents the old
  signatures as removed, but existing source calls still compile because every
  added argument has a default. `CompileContractTests` covers those legacy call
  shapes.
- The scheduler adds a `scheduled` finish-activity kind and driver requirements
  inside `InnoFlowTesting`; those symbols are package implementation details.
  They account for diagnostics without creating an external migration.

## Release decision

The nonzero comparison is accepted only for 6.0.0 as a semantic-major release.
No diagnostic identifies an undocumented external removal beyond the five
consumer-facing migrations above. Patch and minor releases must not reuse this
classification to waive new breakage; they require a fresh comparison and no
unexplained consumer-facing diagnostics.
