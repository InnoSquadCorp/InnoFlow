// MARK: - EffectTask.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

/// A typed effect identifier used for cancellation.
public struct EffectID: Hashable, Sendable, ExpressibleByStringLiteral {
  public typealias StringLiteralType = StaticString
  public let rawValue: StaticString
  private let normalizedValue: String

  public init(_ rawValue: StaticString) {
    self.rawValue = rawValue
    self.normalizedValue = rawValue.description
  }

  public init(stringLiteral value: StaticString) {
    self.init(value)
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.normalizedValue == rhs.normalizedValue
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(normalizedValue)
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

/// Runtime facilities available inside `EffectTask.run`.
///
/// `sleep(for:)` follows the store's active clock, while `checkCancellation()` performs an
/// authoritative cancellation probe that includes task cancellation and store/runtime boundaries.
public struct EffectContext: Sendable {
  private let nowProvider: @Sendable () async -> StoreClock.Instant
  private let sleepProvider: @Sendable (Duration) async throws -> Void
  private let isCancelledProvider: @Sendable () -> Bool
  private let checkCancellationProvider: @Sendable () async throws -> Void

  public init(
    now: @escaping @Sendable () async -> StoreClock.Instant,
    sleep: @escaping @Sendable (Duration) async throws -> Void,
    isCancelled: @escaping @Sendable () -> Bool
  ) {
    self.nowProvider = now
    self.sleepProvider = sleep
    self.isCancelledProvider = isCancelled
    self.checkCancellationProvider = {
      if isCancelled() {
        throw CancellationError()
      }
    }
  }

  package init(
    now: @escaping @Sendable () async -> StoreClock.Instant,
    sleep: @escaping @Sendable (Duration) async throws -> Void,
    isCancelled: @escaping @Sendable () -> Bool,
    checkCancellation: @escaping @Sendable () async throws -> Void
  ) {
    self.nowProvider = now
    self.sleepProvider = sleep
    self.isCancelledProvider = isCancelled
    self.checkCancellationProvider = checkCancellation
  }

  public func now() async -> StoreClock.Instant {
    await nowProvider()
  }

  public func sleep(for duration: Duration) async throws {
    try await sleepProvider(duration)
  }

  public var isCancelled: Bool {
    isCancelledProvider()
  }

  /// Throws `CancellationError` when the current effect should cooperatively stop.
  public func checkCancellation() async throws {
    try await checkCancellationProvider()
  }
}

/// A unified effect model for asynchronous work in InnoFlow v2.
public struct EffectTask<Action: Sendable>: Sendable {
  package struct LazyMappedEffect: Sendable {
    private let materializeEffect: @Sendable () -> EffectTask<Action>

    package init(_ materializeEffect: @escaping @Sendable () -> EffectTask<Action>) {
      self.materializeEffect = materializeEffect
    }

    package func materialize() -> EffectTask<Action> {
      materializeEffect()
    }
  }

  package indirect enum Operation: Sendable {
    case none
    case send(Action)
    case run(
      priority: TaskPriority?, operation: @Sendable (Send<Action>, EffectContext) async -> Void)
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
      animation: EffectAnimation
    )
    case lazyMap(LazyMappedEffect)
  }

  package let operation: Operation

  /// No effect.
  public static var none: Self {
    .init(operation: .none)
  }

  /// Returns `true` when this effect has no work to perform.
  package var isNone: Bool {
    if case .none = operation { return true }
    return false
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
    run(priority: priority) { send, _ in
      await operation(send)
    }
  }

  /// Runs asynchronous work that can emit actions and observe the store runtime context.
  public static func run(
    priority: TaskPriority? = nil,
    _ operation: @escaping @Sendable (Send<Action>, EffectContext) async -> Void
  ) -> Self {
    .init(operation: .run(priority: priority, operation: operation))
  }

  /// Runs effects concurrently.
  public static func merge(_ effects: Self...) -> Self {
    merge(effects)
  }

  /// Runs effects concurrently from a collection.
  public static func merge(_ effects: [Self]) -> Self {
    let live = effects.filter { !$0.isNone }
    guard !live.isEmpty else { return .none }
    if live.count == 1 { return live[0] }
    return .init(operation: .merge(live))
  }

  /// Runs effects sequentially.
  public static func concatenate(_ effects: Self...) -> Self {
    concatenate(effects)
  }

  /// Runs effects sequentially from a collection.
  public static func concatenate(_ effects: [Self]) -> Self {
    let live = effects.filter { !$0.isNone }
    guard !live.isEmpty else { return .none }
    if live.count == 1 { return live[0] }
    return .init(operation: .concatenate(live))
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

  /// Transforms this effect into another action space while preserving effect semantics.
  public func map<NewAction: Sendable>(
    _ transform: @escaping @Sendable (Action) -> NewAction
  ) -> EffectTask<NewAction> {
    switch operation {
    case .none:
      return .none

    case .send(let action):
      return .send(transform(action))

    case .cancel(let id):
      return .cancel(id)

    case .lazyMap:
      return eagerMap(transform)

    case .run, .merge, .concatenate, .cancellable, .debounce, .throttle, .animation:
      let source = self
      return .init(
        operation: .lazyMap(
          .init {
            source.eagerMap(transform)
          }
        )
      )
    }
  }

  private func eagerMap<NewAction: Sendable>(
    _ transform: @escaping @Sendable (Action) -> NewAction
  ) -> EffectTask<NewAction> {
    var current = self
    while case .lazyMap(let lazyMapped) = current.operation {
      current = lazyMapped.materialize()
    }

    switch current.operation {
    case .none:
      return .none

    case .send(let action):
      return .send(transform(action))

    case .run(let priority, let operation):
      return .run(priority: priority) { send, context in
        let mappedSend = Send<Action> { action in
          await send(transform(action))
        }
        await operation(mappedSend, context)
      }

    case .merge(let effects):
      return .merge(effects.map { $0.eagerMap(transform) })

    case .concatenate(let effects):
      return .concatenate(effects.map { $0.eagerMap(transform) })

    case .cancel(let id):
      return .cancel(id)

    case .cancellable(let effect, let id, let cancelInFlight):
      return effect.eagerMap(transform).cancellable(id, cancelInFlight: cancelInFlight)

    case .debounce(let effect, let id, let interval):
      return effect.eagerMap(transform).debounce(id, for: interval)

    case .throttle(let effect, let id, let interval, let leading, let trailing):
      return effect.eagerMap(transform).throttle(
        id,
        for: interval,
        leading: leading,
        trailing: trailing
      )

    case .animation(let effect, let animation):
      return effect.eagerMap(transform).applyingAnimation(animation)

    case .lazyMap:
      preconditionFailure(
        "lazyMap layers must be flattened before eagerMap switches on the concrete operation")
    }
  }
}
