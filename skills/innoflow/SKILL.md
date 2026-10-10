---
name: innoflow
description: Implement, test, diagnose, or migrate Swift state management with InnoFlow when the project uses InnoFlow or the user requests it. Use for InnoFlow reducers, effects, typed outputs, PhaseMap, Store lifetimes, and TestStore; do not introduce InnoFlow for unrelated state-management work.
---

# InnoFlow

Help the consumer use its resolved InnoFlow API. Support covers stable **6.0.x** (`>=6.0.0, <6.1.0`); the exact tagged example and validation baseline are **6.0.2**. Supporting the patch series does not mean every patch was tested. This skill is self-contained and requires no other InnoSquad skill or MCP server.

## Establish the version

Read the consumer's manifest, applicable `Package.resolved`, actual checkout or local override, targets, deployment floors, and Swift/Xcode version before editing. A declared range alone is not the resolved version.

- For stable 6.0.x, use [support.json](references/support.json) and the relevant references below. For a later patch, inspect that tag's release notes, manifest, and relevant fixes, then test the actual consumer. Keep its resolved patch; do not downgrade to match this fixture.
- For new adoption, check the latest published stable 6.0.x tag and project compatibility. The exact 6.0.2 fixture is a reproducible baseline, not an adoption requirement. A Git tag and a GitHub Release page are separate evidence.
- For 5.x, 6.1 or later, prereleases, or unreleased `main`, inspect the actual version's source before borrowing examples. Do not silently upgrade, downgrade, or substitute a path dependency.
- If resolution or source inspection is unavailable, state the uncertainty. A bundled fixture pass does not validate the user's app.

## Choose the workflow

| Task | Read |
| --- | --- |
| Feature authoring, dependency bundles, binding, child composition | [implementation.md](references/implementation.md) and [Features.swift](assets/consumer/Sources/FlowSkillExample/Features.swift) |
| Async effects, cancellation, typed outputs, dispatch/scope lifetime | [effects-lifetime.md](references/effects-lifetime.md) |
| Domain phases, deterministic tests, exhaustive action/output assertions | [phase-testing.md](references/phase-testing.md) and [consumer tests](assets/consumer/Tests/FlowSkillExampleTests/ConsumerTests.swift) |
| Dependency/toolchain conflict, 5→6 migration, compiler-plugin recovery | [compatibility-migration.md](references/compatibility-migration.md) |

Read only the resources relevant to the task. Advanced scheduler, optional-child lifetime, diagnostics, Inspector, and scenario APIs are linked to exact-version upstream sources in the references; the small fixture does not qualify all those paths.

## Keep the contracts intact

- Author features with `@InnoFlow`, nested `State` and `Action`, and `var body: some Reducer<State, Action, Never>` or the feature's typed `Output`. Compose with `Reduce`, `CombineReducers`, and typed child primitives; do not implement `reduce` directly for ordinary macro-based authoring.
- Keep dependencies explicit as reducer inputs, normally a `Sendable` bundle of closures. Feature state owns business data; app navigation stacks, transport/session lifecycle, and dependency-graph construction remain outside InnoFlow.
- Use `@BindableField` and `store.binding(\.$field, to:)`. `BindableProperty` is storage, not the public feature-authoring spelling. Import/link `InnoFlowSwiftUI` for binding helpers.
- Use `Self.output(...)` for ephemeral app-boundary events. Persist renderable/restorable data in `State`. Lift child output explicitly with `mapOutput`; `promoteOutput(to:)` is only for output-free (`Never`) reducers/effects.
- `@InnoFlow(phaseManaged: true)` applies `Self.phaseMap` once, after reduction. Do not also apply it manually or mutate its phase key path in the base reducer.
- Own dispatches through `FlowTask` and, when useful, `withFlowScope`. Dropping a handle is not cancellation; cancelling a dispatch does not roll back state already reduced. Keep unrelated work independent.
- Keep `TestStore` exhaustive by default. Assert all state changes, consume effect actions and outputs, then `await store.finish()`. Do not turn exhaustivity off to hide a failure or replace terminal verification with a queue snapshot.

## Verify and report

Build/test the affected consumer using its normal concurrency, warning, and platform settings. Validate failure, retry, cancellation, and lifetime behavior when changing those paths. Use injected clients and registration-aware `ManualTestClock` progression instead of wall-clock delays or polling. Distinguish a fixture error from a library defect with a passing control.

For this skill's own exact-baseline fixture, run Python 3 and Swift on an Apple host:

```bash
python3 scripts/validate_consumer.py --scratch-path /tmp/innoflow-skill-validation
```

Run from the skill directory or use the script's absolute path. The helper copies the fixture outside the skill, resolves its remote pins, verifies the actual dependency graph and clean checkout SHAs, and records logs/JSON evidence. It tests 6.0.2, not every supported patch, and does not change the user's dependency graph. Cold-cache runs download dependencies.

State the resolved version, changed behavior, checks actually run, and remaining boundaries. Keep compiled examples, runtime tests, device behavior, AI selection, and release readiness separate. This consumer check is not the library's CI-only release matrix.
