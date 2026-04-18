# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
adapted for the release workflow in [RELEASING.md](RELEASING.md).

## [Unreleased]

### Changed

- `ReducerBuilder` now preserves each composed reducer's concrete type through the whole builder chain. A block of N child reducers produces a left-leaning `_ReducerSequence<…>` tower of concrete types instead of an O(N) tower of nested closures, and `if` / `if-else` / `for` blocks emit dedicated `_OptionalReducer`, `_ConditionalReducer`, and `_ArrayReducer` composition types. Public authoring (`CombineReducers { … }` with `Reduce`, `Scope`, `IfLet`, `IfCaseLet`, `ForEachReducer`) is unchanged. Construction-side benchmarks (debug build) show −29%/−34%/−40% at N=2/8/32; dispatch-side benchmarks show modest −3 to −5% gains in debug and are expected to improve further in release builds where `@inlinable` unlocks specialization across the builder boundary.

## [3.0.2] - 2026-03-21

### Changed

- Declared the full `swift-syntax` product set required by `InnoFlowMacros` so SwiftPM and Xcode package builds no longer emit missing macro dependency scan warnings.
- Kept the consumer-facing `InnoFlow` and `InnoFlowTesting` package surface unchanged while tightening the maintainer macro build graph.

## [3.0.1] - 2026-03-21

### Added

- `MIGRATION.md` guidance for the consumer dependency graph cleanup.

### Changed

- Removed `swift-docc-plugin` from the main consumer package graph so SwiftPM users only resolve dependencies required to build and test InnoFlow.
- Moved DocC generation to a docs-only flow that injects the DocC plugin into a temporary package during maintainer and CI documentation builds.
- Updated the release workflow to publish the matching changelog section as the GitHub Release body.
- Updated installation snippets and release governance docs for the `3.0.1` stable tag.

## [3.0.0] - 2026-03-18

### Added
- `PhaseMap` as the canonical post-reduce phase-transition layer for phase-heavy features
- `ActionMatcher` for payload-aware phase transition matching
- `PhaseMap` testing helpers that reuse `derivedGraph` with `TestStore.send/receive(..., through:)`
- `PhaseMap.validationReport(expectedTriggersByPhase:)` for opt-in trigger coverage validation in tests
- `PhaseTransition` and `PhaseTransitionGraph` for opt-in phase-driven FSM modeling
- `PhaseTransitionGraph.linear(...)` and dictionary-literal initialization for concise phase graph declarations
- `InnoFlowTesting` helpers to validate reducer actions against documented phase transitions
- `PHASE_DRIVEN_MODELING.md` as the official guide for feature-level FSM usage
- Queue-ordering contract tests for `EffectTask.send`, `EffectTask.run`, `merge`, and `concatenate`
- Direct-composition guidance for `InnoFlow` + `InnoRouter` at the app/coordinator boundary

### Changed
- `PhaseMap` now owns the declared phase key path in phase-heavy features; base reducers must stop mutating that phase directly once `.phaseMap(...)` is active
- `PhaseMap` remains partial by default at runtime; unmatched phase/action pairs stay legal no-ops and stricter coverage is opt-in
- Generated case path member names strip one leading underscore
  - `Action._loadedCasePath` → `Action.loadedCasePath`
  - `Action._failedCasePath` → `Action.failedCasePath`
- `validatePhaseTransitions(...)` remains available for backward compatibility, but `PhaseMap` is now the canonical authoring pattern for runtime phase movement
- `Store` now dispatches reducer input and effect-emitted follow-up actions through a single FIFO queue
- `EffectTask.send` follow-up actions are queued rather than reducer-reentrant
- Documentation now defines `concatenate` as declaration-ordered and `merge` as completion-ordered

### Migration Notes
- `PhaseMap` is the canonical path for phase-heavy features.
- Base reducers should stop mutating an owned phase directly once `.phaseMap(...)` is active.
- Generated case path names now strip one leading underscore.
- Prefer `CasePath`-based `On(...)` rules first, then equatable action matching, and keep `On(where:)` as an escape hatch.

## [1.0.0] - 2025-01-XX

### Added
- **Core Architecture**
  - `Store` - Observable state container with `@Observable` integration
  - `Reducer` protocol - Defines feature logic with unidirectional data flow
  - `Action`, `Mutation`, `Effect` - Core types for state management
  - `Reduce` - Result type for action processing
  
- **Swift Macros**
  - `@InnoFlow` macro - Automatically generates `Reducer` conformance and `Effect = Never` when needed
  - `@BindableField` macro - Type-safe two-way bindings for SwiftUI
  - Automatic boilerplate reduction
  
- **Binding Support**
  - `@BindableField` for marking bindable state properties
  - `BindableProperty` wrapper type for type-safe bindings
  - `store.binding(_:send:)` method for creating SwiftUI bindings
  
- **Effect System**
  - `EffectOutput` - Supports `.none`, `.single`, and `.stream` outputs
  - Async effect handling with automatic action dispatching
  - Effect cancellation support
  
- **Testing**
  - `TestStore` - Comprehensive testing utilities
  - Action and state assertion support
  - Effect testing with action verification
  
- **Documentation**
  - Comprehensive API documentation
  - Canonical sample app (`Examples/InnoFlowSampleApp`)
  - Architecture diagrams and guides

### Features
- Built on Swift's `@Observable` for seamless SwiftUI integration
- `@dynamicMemberLookup` for convenient state access
- Thread-safe with `@MainActor`
- Automatic effect handling and action dispatching
- Type-safe bindings with `@BindableField`
- Minimal boilerplate with Swift macros
