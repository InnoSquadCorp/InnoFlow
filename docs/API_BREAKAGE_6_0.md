# InnoFlow 6.0.0 API Breakage Classification

## Baseline and result

The 6.0.0 release candidate was compared with the public `5.1.1` tag using:

```bash
swift package diagnose-api-breaking-changes 5.1.1 \
  --products InnoFlow InnoFlowCore InnoFlowSwiftUI InnoFlowTesting
```

The post-R68 comparison exited with status 1, as expected for this major
release. The API digester reported:

- `InnoFlow`: no breaking changes
- `InnoFlowCore`: 203 diagnostics (164 before the selector identity change)
- `InnoFlowSwiftUI`: 1 diagnostic
- `InnoFlowTesting`: 21 diagnostics

The number of diagnostics is not the number of independent consumer
migrations. One generic signature change expands into many type, accessor,
builder, composition, and package-internal diagnostics.

The separate public-only symbol-graph inventory for this local candidate
filters declarations to the four products' own `Sources/<module>/` files and
compares precise identifiers, declarations, generic constraints, signatures,
availability, and access level. Generate both exact `5.1.1` and candidate
graphs with `swift package dump-symbol-graph --skip-synthesized-members --minimum-access-level public`, then run
`scripts/report-public-api-inventory.rb` against the two `symbolgraph`
directories. Skipping synthesized members avoids counting inherited/default
implementation copies as independent source declarations; a graph dump without
that flag produces different totals. The table below was reproduced on Xcode
27 for the local candidate but is not the final frozen-candidate report:

| Product | 5.1.1 → candidate declarations | Added | Removed | Same-identifier changed |
| --- | ---: | ---: | ---: | ---: |
| InnoFlow | 3 → 4 | 1 | 0 | 0 |
| InnoFlowCore | 380 → 510 | 193 | 63 | 6 |
| InnoFlowSwiftUI | 9 → 10 | 2 | 1 | 0 |
| InnoFlowTesting | 75 → 108 | 36 | 3 | 0 |

The 63 removed Core identifiers group by owner as: `EffectTask` 18,
`Store`/`ScopedStore` 12, reducer/composition types 19, and
instrumentation/metrics 14. The six changed same-identifier declarations are
the `Output` generic propagation through `Reducer`, `Reduce`,
`CombineReducers`, `ReducerBuilder`, `phaseMap(_:)`, and
`validatePhaseTransitions(...)`. The SwiftUI removal is the relocated
`EffectTask.animation(_:)` extension. Testing removes the two deprecated
`assertNoMoreActions` forms and replaces one timing-entry initializer with a
defaulted dispatch ID. No removed owner family is left unclassified by this
review; the final candidate must regenerate the inventory and inspect any
new or changed entry before approval. Additions group under the documented
typed-output/dispatch, selection, scheduler/scope, diagnostics/phase, and test
scenario APIs; a count match alone is not approval of their runtime semantics.

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
6. Closure-based `Store.select` and `ScopedStore.select` now create independent
   handles per call by default, including dependency-aware and memoized forms.
   A defaulted `id: String?` parameter opts into weak reuse of a live handle
   when the ID includes all captured inputs that determine its meaning.
   Key-path-only selections keep stable caching. Stored closure-selection
   method values must adapt to the added parameter because Swift does not
   apply default arguments to function values.

Of the 39 additional `InnoFlowCore` diagnostics, 38 describe those eight
`select` signature changes: the digester pairs old/new parameter positions
and reports renamed overloads. The remaining diagnostic is the new
package-only `ProjectionDependencyKey.memoizedCustom` case; it is not an
external consumer API. Existing ordinary calls still compile through the
defaulted argument; the changed closure-selection identity and stored
method-value type are the actual migration work.

The ordered 6.0 hardening pass also adds run-admission policies, `FlowScope`,
`DispatchID` correlation and bounded diagnostics, TestStore invariants and
scenarios, and macro-synthesized Output case paths. These APIs are additive;
they do not add another migration beyond the six changes above. Adoption is
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
- `EffectTimingRecorder.Entry.init` adds a defaulted `dispatchID` argument.
  The old positional call remains valid; the external 5.1.1/6.0 consumer
  compiles and runs that exact call shape against both versions.

## Release decision

The updated nonzero comparison is classified for 6.0.0 as a semantic-major
release. An independent local SwiftPM consumer now builds/runs the same counter
and key-path selection result from exact annotated `5.1.1` and this 6.0
candidate. Its 6.0 variant also checks independent closure captures and
same-callsite semantic-ID reuse. The expanded external fixture checks the
same state transition, effect completion/cancellation, and scoped parent
lifetime behavior against each exact version: three testing-product tests pass
on each side. The 6.0-only variant additionally captures and consumes a typed
output (`selected(42)`) before dispatch completion. These are focused source
and runtime controls, not proof that every consumer-specific migration is
safe. The final candidate-bound four-product inventory and owner approval
remain open. Patch and minor
releases must not reuse this classification to waive new breakage; they require
a fresh comparison and no unexplained consumer-facing diagnostics.
