# visionOS Integration

Use InnoFlow on visionOS the same way you use it on iOS or macOS: reducers own business and domain
transitions, while scene, window, and space orchestration stays in the app layer.

InnoFlow does **not** own immersive runtime APIs. `ImmersiveSpace`, volumetric windows, and any
spatial presentation state remain app-boundary concerns.

## Ownership boundaries

- InnoFlow owns feature state, domain actions, and effect orchestration.
- The app layer owns window, volume, and immersive-space lifecycle.
- Spatial or immersive state should be translated into explicit reducer intent or explicit state
  before it reaches `Store`.

That keeps reducers portable across iOS, macOS, and visionOS instead of coupling the core runtime
to a single presentation system.

## Recommended pattern

Model visionOS UI concerns in two layers:

1. reducer-owned business phase or intent
2. app-owned scene/space state

For example:

- reducer emits an intent like `showDetailsRequested`
- app layer decides whether that means pushing a regular view, opening a window, or entering an
  immersive space

`PhaseTransitionGraph` still validates only feature-level topology. It is not a spatial runtime and
does not model immersive transitions directly.

## View-state guidance

- Use `SelectedStore` when a visionOS view needs an expensive read-only projection.
- Prefer `select(dependingOn:..., transform:)` when the view state comes from one to six explicit
  slices, and use `select(dependingOnAll:)` when a larger explicit dependency set is justified.
- Use `Store.preview(...)` inside `#Preview` so preview setup stays explicit and platform-local.

## Accessibility and layout

- Prefer system controls and Dynamic Type-friendly layouts before custom chrome.
- Treat VoiceOver labels and hints as part of the sample contract when button text or spatial layout
  alone is not descriptive enough.
- Keep stable `accessibilityIdentifier(...)` values on controls that are exercised by smoke tests.
- Use `Store.preview(...)` during visionOS-specific preview review so accessibility and spatial UI
  checks stay explicit without changing production wiring.

## Current support level

InnoFlow currently provides package-level and documentation-level visionOS support.

- `Package.swift` declares visionOS support.
- CI validates package builds across supported platforms.
- The canonical sample remains an iOS-first interactive shell.

Dedicated immersive or spatial samples can be added later if real visionOS product requirements
appear, but they are intentionally outside the current core contract.
