// MARK: - InnoFlow.swift (Module Entry Point)
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

@_exported public import Foundation
@_exported public import InnoFlowCore

// MARK: - InnoFlow Macro

/// Generates `Reducer` conformance boilerplate, validates the official
/// body-based InnoFlow authoring contract, and synthesizes reusable paths for
/// scoping nested `Action` enums and matching nested `Output` enums.
///
/// `@InnoFlow` requires:
/// 1. Nested `State` type
/// 2. Nested `Action` type
/// 3. `var body: some Reducer<State, Action, Never>`
///
/// When the nested `Action` enum exposes:
/// - `case child(ChildAction)` the macro synthesizes `Action.childCasePath`
/// - `case todo(id: ID, action: ChildAction)` the macro synthesizes `Action.todoActionPath`
///
/// Nested `Output` enums receive `<caseName>CasePath` members for no-payload,
/// single-payload, and ordinary multi-payload cases. These paths can be used by
/// `TestStore.receiveOutput` without requiring `Output: Equatable`.
///
/// Generated action-path names must be unique and cannot reuse an existing
/// static member name. Rename the enum case or expose a manually declared path
/// under a different static name when a collision occurs.
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
///     var body: some Reducer<State, Action, Never> {
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
///     var body: some Reducer<State, Action, Never> {
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

/// Strict phase-declaration variant of `@InnoFlow`.
///
/// Set `strictPhaseTotality: true` only with `phaseManaged: true`. The macro
/// then requires every nested `Phase` enum case to appear directly in the
/// static `phaseMap` DSL as a `From` source or an `On` target. Missing phase
/// coverage is a compile-time error instead of the default warning.
///
/// This is syntax-level declaration completeness. Predicate and payload
/// trigger semantics remain runtime values and must still be verified with
/// `PhaseMap.requireComplete(expectedTriggersByPhase:)`.
@attached(member, names: named(reduce), arbitrary)
@attached(memberAttribute)
@attached(extension, conformances: Reducer, names: arbitrary)
public macro InnoFlow(phaseManaged: Bool, strictPhaseTotality: Bool) =
  #externalMacro(
    module: "InnoFlowMacros",
    type: "InnoFlowMacro"
  )

/// Excludes an `Action` enum case from `@InnoFlow` action-path synthesis and
/// unsupported-payload diagnostics.
///
/// Prefer a manually declared `<caseName>CasePath` inside `Action` when the
/// case needs a custom path. Use this marker when no path is needed or when a
/// manual path must live in an extension that the attached macro cannot inspect.
/// The canonical static variable name is the manual-path signal, so typealiases
/// and factory-built `CasePath` values are supported.
@attached(peer)
public macro InnoFlowCasePathIgnored() =
  #externalMacro(
    module: "InnoFlowMacros",
    type: "InnoFlowCasePathIgnoredMacro"
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

/// Synthesizes case-path members for nested `Output` enums.
///
/// This is an implementation hook used by `@InnoFlow`; invoke `@InnoFlow`
/// rather than applying this macro directly.
@attached(member, names: arbitrary)
public macro _InnoFlowOutputPaths() =
  #externalMacro(
    module: "InnoFlowMacros",
    type: "InnoFlowOutputPathsMacro"
  )
