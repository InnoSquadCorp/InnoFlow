# Contributing to InnoFlow

## Before you change code

Read these files first:

- `README.md`
- `ARCHITECTURE_REVIEW.md`
- `CLAUDE.md`
- `AGENTS.md`

Those files define the current framework contract.

## Non-negotiable rules

- `@InnoFlow` features use `var body: some Reducer<State, Action>`.
- Public feature authoring does not use explicit `reduce(into:action:)`.
- Reducer composition should use `Reduce`, `CombineReducers`, and `Scope`.
- Binding must stay explicit through `@BindableField`, and SwiftUI entry points should use projected key paths like `\.$field`.
- Concrete navigation ownership belongs to the app boundary or another navigation layer, not InnoFlow.
- Transport and session lifecycle belong outside InnoFlow.
- Dependency graph construction belongs outside InnoFlow and should enter reducers as explicit bundles.

## When changing framework rules

If you change the framework surface or architectural rules, update all of these together:

1. source code
2. tests
3. docs
4. `scripts/principle-gates.sh`
5. `.github/workflows/ci.yml`

The repository should fail fast if the new rule is violated.

## Validation

Run all of these before proposing the change:

```bash
swift test --package-path .
swift test --package-path Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage
xcodebuild -project Examples/InnoFlowSampleApp/InnoFlowSampleApp.xcodeproj -scheme InnoFlowSampleApp -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
./scripts/principle-gates.sh
```

## Change quality

- Fix root causes, not just failing tests.
- Keep public APIs small and explicit.
- Keep ownership boundaries between InnoFlow and app-owned navigation, transport, and dependency systems clear.
- Prefer observer-style diagnostics over middleware that changes reducer behavior.
