# Architecture Review

Use this checklist when a change modifies framework semantics or canonical patterns.

## Review prompts

- Does the change preserve `var body: some Reducer<State, Action>` as the public authoring surface?
- Does the change keep ownership boundaries clear between InnoFlow, app-layer navigation, transport/session lifecycle, and dependency construction?
- If the change touches `SelectedStore`, does it preserve the `dependingOn:` contract and the always-refresh fallback story?
- If the change touches `PhaseMap`, does it preserve post-reduce ownership, `derivedGraph`, and topology-only graph validation?
- If the change introduces a new `@InnoFlow(phaseManaged: true)` feature in `Sources/InnoFlow`, is there an `assertPhaseMapCovers(...)` totality assertion landing in `Tests/InnoFlowTests` together with it? `scripts/principle-gates.sh` enforces this — see [docs/adr/ADR-phase-map-totality-validation.md](docs/adr/ADR-phase-map-totality-validation.md).
- If the change touches effects, does it preserve `EffectContext`, best-effort async cleanup, and deadlock-resistant runtime behavior?
- If the change touches samples or docs, does it keep accessibility identifiers stable and preserve the existing VoiceOver / Dynamic Type guidance?

## Required follow-through

When a rule changes, update source, tests, `README`, DocC, ADRs if needed, and `scripts/principle-gates.sh` together.
