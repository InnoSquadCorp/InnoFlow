# Repository Guidelines

## InnoFlow 4.0.0 authoring rules

These are repository rules, not suggestions.

- `@InnoFlow` features must expose `var body: some Reducer<State, Action>`.
- Do not author public features with explicit `func reduce(into:action:)`.
- Use `Reduce`, `CombineReducers`, and `Scope` for composition.
- Keep binding explicit through `@BindableField`.
- Keep concrete navigation ownership at the app boundary or in another navigation library.
- Keep transport/session lifecycle outside InnoFlow.
- Keep dependency graph construction outside InnoFlow and pass dependencies in explicitly.
- Treat `PhaseTransitionGraph` as validation, not runtime ownership.

## Change discipline

When a change alters the framework contract, update all of the following in the same branch:

- source code
- tests
- docs
- `scripts/principle-gates.sh`
- CI

Do not leave a rule enforced only by prose.

## Project structure

- Core runtime: `Sources/InnoFlowCore`
- Macro facade: `Sources/InnoFlow`
- Macros: `Sources/InnoFlowMacros`
- Testing utilities: `Sources/InnoFlowTesting`
- Canonical sample: `Examples/InnoFlowSampleApp`

## Verification commands

```bash
swift test --package-path .
swift test --package-path Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage --jobs 1
xcodebuild -jobs 1 -project Examples/InnoFlowSampleApp/InnoFlowSampleApp.xcodeproj -scheme InnoFlowSampleApp -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
./scripts/principle-gates.sh
```

## Implementation notes

- Prefer general-purpose architecture changes over test-specific fixes.
- Keep side effects isolated and testable.
- Favor observer-style instrumentation over behavior-changing middleware.
