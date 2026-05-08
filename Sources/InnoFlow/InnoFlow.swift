// MARK: - InnoFlow.swift (Module Entry Point)
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

@_exported import Foundation
@_exported import InnoFlowCore

// MARK: - InnoFlow Macro

/// Generates `Reducer` conformance boilerplate, validates the official
/// body-based InnoFlow authoring contract, and synthesizes reusable action paths
/// for scoping helpers on nested `Action` enums.
///
/// `@InnoFlow` requires:
/// 1. Nested `State` type
/// 2. Nested `Action` type
/// 3. `var body: some Reducer<State, Action>`
///
/// When the nested `Action` enum exposes:
/// - `case child(ChildAction)` the macro synthesizes `Action.childCasePath`
/// - `case todo(id: ID, action: ChildAction)` the macro synthesizes `Action.todoActionPath`
///
/// Existing manual definitions with the same names are preserved.
///
/// ## Example
/// ```swift
/// @InnoFlow
/// struct CounterFeature {
///     struct State: Equatable, Sendable {
///         var count = 0
///     }
///
///     enum Action: Sendable {
///         case increment
///     }
///
///     var body: some Reducer<State, Action> {
///         Reduce { state, action in
///             switch action {
///             case .increment:
///                 state.count += 1
///                 return .none
///             }
///         }
///     }
/// }
/// ```
@attached(member, names: named(reduce), arbitrary)
@attached(memberAttribute)
@attached(extension, conformances: Reducer, names: arbitrary)
public macro InnoFlow() =
  #externalMacro(
    module: "InnoFlowMacros",
    type: "InnoFlowMacro"
  )

/// Phase-managed variant of `@InnoFlow`. When invoked with `phaseManaged: true`,
/// the macro requires the type to provide a static `phaseMap` declaration and
/// automatically wraps the synthesized `reduce(into:action:)` in
/// `.phaseMap(Self.phaseMap)`. Authors no longer have to remember to call
/// `.phaseMap(Self.phaseMap)` inside `body`; forgetting `static var phaseMap`
/// becomes a compile-time error rather than a silent runtime drift.
///
/// A boolean marker is used instead of a `WritableKeyPath` argument to avoid
/// the self-referential macro-attribute issue where the keypath would refer
/// back to the same type the macro is being applied to. The phase key path
/// itself is declared inside the static `phaseMap` value where it belongs.
///
/// ## Example
/// ```swift
/// @InnoFlow(phaseManaged: true)
/// struct LoadingFeature {
///     struct State: Equatable, Sendable, DefaultInitializable {
///         enum Phase: Hashable, Sendable { case idle, loading, loaded, failed }
///         var phase: Phase = .idle
///     }
///
///     enum Action: Equatable, Sendable {
///         case load
///         case _loaded
///         case _failed
///     }
///
///     static var phaseMap: PhaseMap<State, Action, State.Phase> {
///         PhaseMap(\.phase) {
///             From(.idle) { On(.load, to: .loading) }
///             From(.loading) {
///                 On(Action.loadedCasePath, to: .loaded)
///                 On(Action.failedCasePath, to: .failed)
///             }
///         }
///     }
///
///     var body: some Reducer<State, Action> {
///         Reduce { state, action in
///             // No need to call `.phaseMap(Self.phaseMap)` — it is applied
///             // by the synthesized `reduce(into:action:)`.
///             return .none
///         }
///     }
/// }
/// ```
@attached(member, names: named(reduce), arbitrary)
@attached(memberAttribute)
@attached(extension, conformances: Reducer, names: arbitrary)
public macro InnoFlow(phaseManaged: Bool) =
  #externalMacro(
    module: "InnoFlowMacros",
    type: "InnoFlowMacro"
  )

/// Synthesizes case-path members for nested `Action` enums.
///
/// This macro remains public so generated members can be emitted across module
/// boundaries, but external projects should treat it as an implementation hook.
/// Use `@InnoFlow` instead of invoking `_InnoFlowActionPaths` directly.
@attached(member, names: arbitrary)
public macro _InnoFlowActionPaths() =
  #externalMacro(
    module: "InnoFlowMacros",
    type: "InnoFlowActionPathsMacro"
  )
