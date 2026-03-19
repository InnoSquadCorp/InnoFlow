# InnoFlow Sample Apps

`InnoFlow` now ships one canonical sample app instead of parallel mini-apps.

## Canonical Sample

### InnoFlowSampleApp

The canonical app demonstrates the full recommended story in one place:

- `Basics`: `@InnoFlow`, `Store`, `@BindableField`, queue-based follow-up actions
- `Orchestration`: parent-child orchestration, cancellation fan-out, long-running progress pipeline
- `Phase-Driven FSM`: explicit business lifecycle and `phaseGraph` validation
- `App-Boundary Navigation`: direct composition at the app/coordinator boundary with pure SwiftUI navigation state

[Learn more →](./InnoFlowSampleApp/README.md)

## Recommended Learning Order

1. Open the sample hub
2. Start with `Basics`
3. Move to `Orchestration`
4. Study `Phase-Driven FSM`
5. Finish with `App-Boundary Navigation`

## Modeling Notes

Use the canonical sample together with these guides:

- [PHASE_DRIVEN_MODELING.md](../PHASE_DRIVEN_MODELING.md)
- [README.md](../README.md)

The sample intentionally keeps one concern in one layer:

- domain and feature lifecycle in `InnoFlow`
- navigation state ownership in the app boundary
- sample-specific services behind protocol boundaries and explicit dependency bundles

The canonical sample also acts as the preview and accessibility contract:

- feature views keep at least one `#Preview`
- tested controls keep stable `accessibilityIdentifier(...)` values
- layouts prefer system controls and Dynamic Type-friendly sizing
