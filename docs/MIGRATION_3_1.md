# InnoFlow 3.1 Migration Notes

InnoFlow 3.1 is source-compatible with the 3.0 line. The release mainly adds
more explicit authoring surfaces for phase-heavy features, projection liveness,
selection dependencies, and instrumentation.

## Selected Projections

Use `select(dependingOn:)` for a single explicit `Equatable` slice and
`select(dependingOnAll:)` (parameter-pack variadic) for two or more slices.

```swift
let badge = store.select(dependingOnAll: \.profile, \.permissions) { profile, permissions in
  DashboardBadge(name: profile.name, canEdit: permissions.canEdit)
}
```

The variadic form preserves explicit dependency tracking and selective
invalidation regardless of how many slices a projection consumes.

```swift
let summary = store.select(
  dependingOnAll: \.a, \.b, \.c, \.d, \.e, \.f, \.g
) { a, b, c, d, e, f, g in
  Summary(a, b, c, d, e, f, g)
}
```

`ScopedStore` exposes the same one-field `dependingOn:` and variadic
`dependingOnAll:` selection shape against child state.

## Projection Liveness

`ScopedStore.isAlive` / `optionalState` and `SelectedStore.isAlive` /
`optionalValue` expose the projection lifecycle contract without relying on a
debug assertion or a release-time cached fallback.

Use these accessors when code needs to distinguish "fresh projection" from
"parent store has gone away".

## Phase-managed Features

Existing explicit phase maps still work:

```swift
@InnoFlow
struct Feature {
  static var phaseMap: PhaseMap<State, Action, State.Phase> { ... }

  var body: some Reducer<State, Action> {
    Reduce { state, action in ... }
      .phaseMap(Self.phaseMap)
  }
}
```

For new phase-heavy features, prefer the macro-managed form:

```swift
@InnoFlow(phaseManaged: true)
struct Feature {
  static var phaseMap: PhaseMap<State, Action, State.Phase> { ... }

  var body: some Reducer<State, Action> {
    Reduce { state, action in ... }
  }
}
```

The macro requires `static phaseMap`, applies it to the synthesized reducer,
and warns when a nested `Phase` case is never referenced from the phase map.

## Instrumentation

`StoreInstrumentation` now covers the common adapter shapes:

- `.sink` for custom event collectors
- `.osLog` for local Console-readable logs
- `.signpost` for Instruments timelines
- `.combined` for fan-out

See `docs/INSTRUMENTATION_COOKBOOK.md` for examples.

## Testing

Use `assertPhaseMapCovers(...)` when trigger coverage should be a test
contract:

```swift
assertPhaseMapCovers(
  Feature.phaseMap,
  expectedTriggersByPhase: [
    .idle: [.action(.load)],
    .loading: [.casePath(Feature.Action.loadedCasePath, label: "loaded", sample: items)]
  ]
)
```

Runtime semantics remain partial by default. This helper records a test failure
only when a team explicitly opts into stronger trigger coverage.
