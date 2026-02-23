// MARK: - InnoFlow.swift (Module Entry Point)
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

@_exported import Foundation

// MARK: - InnoFlow Macro

/// Generates `Reducer` conformance boilerplate and validates v2 reducer contract.
///
/// `@InnoFlow` requires:
/// 1. Nested `State` type
/// 2. Nested `Action` type
/// 3. `reduce(into:action:) -> EffectTask<Action>`
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
///     func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
///         switch action {
///         case .increment:
///             state.count += 1
///             return .none
///         }
///     }
/// }
/// ```
@attached(extension, conformances: Reducer)
public macro InnoFlow() =
  #externalMacro(
    module: "InnoFlowMacros",
    type: "InnoFlowMacro"
  )

// MARK: - BindableField Macro

/// Marks a `State` property as intentionally bindable from SwiftUI.
///
/// Properties marked with `@BindableField` are transformed into
/// `BindableProperty<Value>`-backed storage and can be used with
/// `store.binding(_:send:)`.
@attached(accessor)
@attached(peer, names: arbitrary)
public macro BindableField() =
  #externalMacro(
    module: "InnoFlowMacros",
    type: "BindableFieldMacro"
  )
