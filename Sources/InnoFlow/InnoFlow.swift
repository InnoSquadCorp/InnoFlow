// MARK: - InnoFlow.swift (Module Entry Point)
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

@_exported import Foundation

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

// MARK: - BindableField

/// Marks a `State` property as intentionally bindable from SwiftUI.
///
/// Properties marked with `@BindableField` remain reducer-friendly value fields,
/// while exposing a projected ``BindableProperty`` via `\.$field` for
/// `store.binding(_:send:)`.
