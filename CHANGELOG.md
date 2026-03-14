# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `PhaseTransition` and `PhaseTransitionGraph` for opt-in phase-driven FSM modeling
- `PhaseTransitionGraph.linear(...)` and dictionary-literal initialization for concise phase graph declarations
- `InnoFlowTesting` helpers to validate reducer actions against documented phase transitions
- `PHASE_DRIVEN_MODELING.md` as the official guide for feature-level FSM usage

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
  - Example apps (CounterApp, TodoApp)
  - Architecture diagrams and guides

### Features
- Built on Swift's `@Observable` for seamless SwiftUI integration
- `@dynamicMemberLookup` for convenient state access
- Thread-safe with `@MainActor`
- Automatic effect handling and action dispatching
- Type-safe bindings with `@BindableField`
- Minimal boilerplate with Swift macros
