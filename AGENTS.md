# Repository Guidelines

> **Canonical source: [CLAUDE.md](CLAUDE.md).** AGENTS.md is preserved as a redirect for
> tools that resolve `AGENTS.md` by convention. The authoring contract, composition
> primitives, PhaseMap rules, testing recipes, and contribution discipline all live in
> CLAUDE.md — keep edits there.

Key reminders that earn their own line here so search tooling still surfaces them:

- **CI-only release validation:** run all 28 required release preflight checks,
  including the four OS 27 runtimes, only in `Release Preflight` CI.
  Under the 2026-10-06 policy, iOS 18.5 / tvOS 18.5 / watchOS 11.5 /
  visionOS 2.5 runtime checks are optional and are not run automatically.
  Do not install release-matrix runtimes or run `execute`/`resume` on the user's
  Mac. Local `plan`/`report`, static checks and focused diagnostic/fixture tests
  are allowed; they are not release evidence. See CLAUDE.md and RELEASING.md.
- **GitHub-hosted runners only:** release CI uses `macos-26` (Swift 6.3)
  and `xcode-27` (Swift 6.4). Do not assume or require a self-hosted runner.
  Runtime provisioning belongs to isolated hosted CI jobs, never the user's Mac.
- `@InnoFlow` features must declare the third reducer generic: use
  `var body: some Reducer<State, Action, Never>` without app-boundary output,
  or the feature's typed `Output` when it emits one.
- Compose with `Reduce`, `CombineReducers`, `Scope`, `IfLet`, `IfCaseLet`,
  `ForEachReducer`, `ForEachIdentifiedReducer`.
- Bind through `@BindableField` + `store.binding(\.$field, to:)` (canonical;
  `send:` and trailing-closure forms stay as compatibility spellings). Never
  author `BindableProperty` directly.
- `PhaseMap` owns post-reduce phase transitions; `PhaseTransitionGraph` is a
  topology-only validator.
- Navigation stacks, transport, session lifecycle, and dependency-graph
  construction stay outside InnoFlow.

When a change alters the framework contract, update CLAUDE.md, tests,
`scripts/principle-gates.sh`, and CI in the same branch. Do not leave a rule
enforced only by prose.
