# Authoring a 6.0.x feature

These patterns use the tagged 6.0.0 baseline. Keep an existing consumer's stable 6.0.x patch and check its relevant changes before adapting the example.

## Package and product boundaries

The [consumer manifest](../assets/consumer/Package.swift) links `InnoFlow` for macro authoring and `InnoFlowSwiftUI` for UI helpers. `InnoFlowTesting` belongs to test targets. `InnoFlowCore` is the deliberate compiler-plugin-free runtime boundary; it is not a reason to replace ordinary macro authoring with handwritten reducers. The optional `InnoFlowInspector` product is separate from UI and testing helpers.

No InnoDI-style DAG build plugin belongs on an InnoFlow target. Preserve the consumer's actual dependency and build configuration; see [compatibility-migration.md](compatibility-migration.md) for toolchain constraints.

## Feature and composition decisions

Use the compiled [Features.swift](../assets/consumer/Sources/FlowSkillExample/Features.swift):

- `CounterFeature` shows `@InnoFlow`, `@BindableField`, `State: Equatable & Sendable & DefaultInitializable`, and `Reducer<State, Action, Never>`. `DefaultInitializable` is needed for the default-state Store/TestStore initializer; explicit initial state is another supported choice.
- `LoadFeature` takes an explicit `Sendable` dependency bundle, maps success/failure into actions, declares typed output, and lets PhaseMap own phases.
- `ParentFeature` scopes the same child state/action path and explicitly maps child output to parent output. Generated `Action.childCasePath` is reused for reducer and test scoping.
- [CounterView.swift](../assets/consumer/Sources/FlowSkillExample/CounterView.swift) imports both InnoFlow products and binds the projected field with the canonical `to:` label. The fixture compiles this boundary; it does not run a SwiftUI device lifecycle.

Choose `Scope` for always-present child state, `IfLet` for optional state, `IfCaseLet` for enum state, and collection reducers for identified children. `CombineReducers` runs in declaration order. Composition requires compatible output types; map a real output or promote `Never`, rather than discarding events.

State paths passed to reducer composition and PhaseMap must preserve `Sendable`. Direct literals such as `\.child` work. Hoisted paths need a type such as `any WritableKeyPath<Parent.State, Child.State> & Sendable`; a plain `WritableKeyPath` annotation erases that proof. Do not cast around this diagnostic.

## Paths, projections, and optional ownership

`@InnoFlow` synthesizes paths for ordinary single-payload actions, collection `id:action:` cases, and nested Output cases. One leading underscore is stripped. For unsupported action payload shapes, declare the canonical static path inside `Action`; use `@InnoFlowCasePathIgnored` only when no generated path is needed or the manual declaration is outside the attached macro's visibility.

Runtime scoped stores and selections are projections of the parent. Do not create an independent Store to fake a shared child. After optional/collection removal, discard stale projections; use `optionalState`/`optionalValue` for absence or `requireAlive()` for a programmer invariant. Closure-based selections are independent by default; stable `id:` reuse must cover captured inputs as well as the semantic selection.

`OptionalChildLifetime` / `.optionalChild` opt into state-owned effect cancellation. Use a fresh explicit instance ID on reopening, avoid duplicate child composition, and read the exact ownership contract before adopting it. Existing `IfLet` alone does not imply that new ownership contract.

Exact 6.0.0 sources: [authoring and composition](https://github.com/InnoSquadCorp/InnoFlow/blob/188c2732d26350cf01afadade3dac89a2b73b68f/CLAUDE.md), [dependency patterns](https://github.com/InnoSquadCorp/InnoFlow/blob/188c2732d26350cf01afadade3dac89a2b73b68f/docs/DEPENDENCY_PATTERNS.md), [optional-child lifetime](https://github.com/InnoSquadCorp/InnoFlow/blob/188c2732d26350cf01afadade3dac89a2b73b68f/docs/OPTIONAL_CHILD_LIFETIME.md). Advanced collection/optional ownership and selection behavior are outside this skill fixture's runtime coverage.
