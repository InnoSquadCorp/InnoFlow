# Migration Notes

This file tracks release-to-release migration guidance when behavior, defaults, or artifact contracts change in a way that users must react to.

## 3.0.2

### Who is affected

- Maintainers and CI jobs that build the `InnoFlowMacros` target through SwiftPM or Xcode package resolution.

### Required action

- No source migration is required for framework consumers.
- Update downstream lockfiles only if you want the quieter macro dependency graph from the `3.0.2` tag.

### Notes

- This patch release only aligns the declared `swift-syntax` macro dependencies with what the compiler already loads during package builds.

## 3.0.1

### Who is affected

- SwiftPM consumers that inspect resolved dependencies for InnoFlow.
- Maintainers or CI jobs that generate DocC documentation.

### Required action

- No source code migration is required for framework consumers.
- Switch DocC generation to `Tools/generate-docc.sh` instead of calling `swift package generate-documentation` directly from the checked-in package manifest.

### Notes

- This patch release removes `swift-docc-plugin` from the consumer dependency graph.
- DocC generation remains available for maintainers and CI through the docs-only generation flow.

## 3.0.0

### Who is affected

- Existing app features migrating to `PhaseMap`-owned phase transitions.

### Required action

- Stop mutating an owned phase directly once `.phaseMap(...)` is active.
- Update references to generated action path names that previously kept one leading underscore.

### Notes

- `PhaseMap` is the canonical runtime phase-transition layer for phase-heavy features.
- `validatePhaseTransitions(...)` remains available for backward compatibility.
