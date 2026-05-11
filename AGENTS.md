# Repository Guidelines

> **Canonical source: [CLAUDE.md](CLAUDE.md).** AGENTS.md is preserved as a redirect for
> tools that resolve `AGENTS.md` by convention. The authoring contract, composition
> primitives, PhaseMap rules, testing recipes, and contribution discipline all live in
> CLAUDE.md — keep edits there.

Key reminders that earn their own line here so search tooling still surfaces them:

- `@InnoFlow` features must declare `var body: some Reducer<State, Action>`.
- Compose with `Reduce`, `CombineReducers`, `Scope`, `IfLet`, `IfCaseLet`,
  `ForEachReducer`.
- Bind through `@BindableField` + `store.binding(\.$field, send:)` /
  `store.binding(\.$field, to:)`. Never author `BindableProperty` directly.
- `PhaseMap` owns post-reduce phase transitions; `PhaseTransitionGraph` is a
  topology-only validator.
- Navigation stacks, transport, session lifecycle, and dependency-graph
  construction stay outside InnoFlow.

When a change alters the framework contract, update CLAUDE.md, tests,
`scripts/principle-gates.sh`, and CI in the same branch. Do not leave a rule
enforced only by prose.
