// MARK: - EffectTask.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import SwiftUI

/// A typed effect identifier used for cancellation.
public struct EffectID: Hashable, Sendable, ExpressibleByStringLiteral {
    public typealias StringLiteralType = StaticString
    public let rawValue: StaticString

    public init(_ rawValue: StaticString) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: StaticString) {
        self.rawValue = value
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.description == rhs.rawValue.description
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue.description)
    }
}

/// A sender used inside `EffectTask.run` to emit actions back to a store.
public struct Send<Action: Sendable>: Sendable {
    private let operation: @Sendable (Action) async -> Void

    public init(_ operation: @escaping @Sendable (Action) async -> Void) {
        self.operation = operation
    }

    public func callAsFunction(_ action: Action) async {
        await operation(action)
    }
}

/// A unified effect model for asynchronous work in InnoFlow v2.
public struct EffectTask<Action: Sendable>: Sendable {
    internal indirect enum Operation: Sendable {
        case none
        case send(Action)
        case run(priority: TaskPriority?, operation: @Sendable (Send<Action>) async -> Void)
        case merge([EffectTask<Action>])
        case concatenate([EffectTask<Action>])
        case cancel(EffectID)
        case cancellable(
            effect: EffectTask<Action>,
            id: EffectID,
            cancelInFlight: Bool
        )
        case debounce(
            effect: EffectTask<Action>,
            id: EffectID,
            interval: Duration
        )
        case throttle(
            effect: EffectTask<Action>,
            id: EffectID,
            interval: Duration,
            leading: Bool,
            trailing: Bool
        )
        case animation(
            effect: EffectTask<Action>,
            animation: Animation?
        )
    }

    internal let operation: Operation

    init(operation: Operation) {
        self.operation = operation
    }

    /// No effect.
    public static var none: Self {
        .init(operation: .none)
    }

    /// Emit a single action immediately.
    public static func send(_ action: Action) -> Self {
        .init(operation: .send(action))
    }

    /// Runs asynchronous work that can emit actions.
    public static func run(
        priority: TaskPriority? = nil,
        _ operation: @escaping @Sendable (Send<Action>) async -> Void
    ) -> Self {
        .init(operation: .run(priority: priority, operation: operation))
    }

    /// Runs effects concurrently.
    public static func merge(_ effects: Self...) -> Self {
        .init(operation: .merge(effects))
    }

    /// Runs effects sequentially.
    public static func concatenate(_ effects: Self...) -> Self {
        .init(operation: .concatenate(effects))
    }

    /// Cancels effects tied to an identifier.
    public static func cancel(_ id: EffectID) -> Self {
        .init(operation: .cancel(id))
    }

    /// Marks this effect as cancellable.
    public func cancellable(_ id: EffectID, cancelInFlight: Bool = false) -> Self {
        .init(operation: .cancellable(effect: self, id: id, cancelInFlight: cancelInFlight))
    }

    /// Delays effect execution and keeps only the latest run for the same id.
    ///
    /// New runs cancel prior in-flight or delayed runs sharing the same id.
    public func debounce(_ id: EffectID, for interval: Duration) -> Self {
        .init(operation: .debounce(effect: self, id: id, interval: interval))
    }

    /// Runs the first effect in a window and drops subsequent runs for the same id.
    ///
    /// Leading-only semantics: first event passes, in-window events are dropped.
    public func throttle(_ id: EffectID, for interval: Duration) -> Self {
        throttle(id, for: interval, leading: true, trailing: false)
    }

    /// Throttles effect execution with configurable leading/trailing behavior.
    ///
    /// - Parameters:
    ///   - id: Identifier used to scope throttle windows.
    ///   - interval: Fixed throttle window duration.
    ///   - leading: Whether to execute immediately when a new window starts.
    ///   - trailing: Whether to execute the latest in-window event at window end.
    ///
    /// `leading` and `trailing` cannot both be `false`.
    public func throttle(
        _ id: EffectID,
        for interval: Duration,
        leading: Bool = true,
        trailing: Bool = false
    ) -> Self {
        precondition(leading || trailing, "throttle requires at least one of leading or trailing")
        return .init(
            operation: .throttle(
                effect: self,
                id: id,
                interval: interval,
                leading: leading,
                trailing: trailing
            )
        )
    }

    /// Applies animation to state changes caused by actions emitted from this effect.
    public func animation(_ animation: Animation? = .default) -> Self {
        .init(operation: .animation(effect: self, animation: animation))
    }
}

// MARK: - Package Introspection (Testing Targets)

package indirect enum _EffectTaskOperation<Action: Sendable>: Sendable {
    case none
    case send(Action)
    case run(priority: TaskPriority?, operation: @Sendable (Send<Action>) async -> Void)
    case merge([EffectTask<Action>])
    case concatenate([EffectTask<Action>])
    case cancel(EffectID)
    case cancellable(
        effect: EffectTask<Action>,
        id: EffectID,
        cancelInFlight: Bool
    )
    case debounce(
        effect: EffectTask<Action>,
        id: EffectID,
        interval: Duration
    )
    case throttle(
        effect: EffectTask<Action>,
        id: EffectID,
        interval: Duration,
        leading: Bool,
        trailing: Bool
    )
    case animation(
        effect: EffectTask<Action>,
        animation: Animation?
    )
}

extension EffectTask {
    package var _testingOperation: _EffectTaskOperation<Action> {
        switch operation {
        case .none:
            return .none
        case .send(let action):
            return .send(action)
        case .run(let priority, let operation):
            return .run(priority: priority, operation: operation)
        case .merge(let effects):
            return .merge(effects)
        case .concatenate(let effects):
            return .concatenate(effects)
        case .cancel(let id):
            return .cancel(id)
        case .cancellable(let effect, let id, let cancelInFlight):
            return .cancellable(effect: effect, id: id, cancelInFlight: cancelInFlight)
        case .debounce(let effect, let id, let interval):
            return .debounce(effect: effect, id: id, interval: interval)
        case .throttle(let effect, let id, let interval, let leading, let trailing):
            return .throttle(
                effect: effect,
                id: id,
                interval: interval,
                leading: leading,
                trailing: trailing
            )
        case .animation(let effect, let animation):
            return .animation(effect: effect, animation: animation)
        }
    }
}
