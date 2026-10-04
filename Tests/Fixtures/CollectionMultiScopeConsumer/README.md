# Direct multi-scope collection consumer

This consumer uses public InnoFlowCore API. It projects each group directly with
`Scope(state: \GroupsState.groups[index], ...)`, then uses `ForEachReducer` for
that group's rows and `OptionalChildLifetime` for each row's child. There is no
outer `ForEachReducer` scan.

The executable verifies one synchronous tick for 1/8/32/128 groups with 1/2 rows
per group. It contains no clocks or registry hooks. `makeGroupsStore` separates
installation from `tickGroups`, so a future approved harness can prepare a fresh
store outside its measured loop and check `state.ticks` afterward. The helper
accepts arbitrary group/row/iteration counts; none are production thresholds.

A possible additional comparison is 128 direct groups with 2 rows each. Its
final parameters, sample budget, arm configuration and timing boundary still
require the source-frozen cohort's independent admission. This fixture is not a
new timing result or release evidence.

On supported native platforms:

```sh
swift run --package-path Tests/Fixtures/CollectionMultiScopeConsumer --jobs 1 Consumer
```

An explicit `INNOFLOW_CONSUMER_PACKAGE_PATH` may select the strict Linux adapter
for portable validation. That does not qualify Apple's original lock or UI.
