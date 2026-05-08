// MARK: - EffectTask.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

/// A typed effect identifier used for cancellation.
public struct EffectID<RawValue: Hashable & Sendable>: Hashable, Sendable {
  public let rawValue: RawValue

  public init(_ rawValue: RawValue) {
    self.rawValue = rawValue
  }
}

extension EffectID: ExpressibleByUnicodeScalarLiteral where RawValue == String {
  public typealias UnicodeScalarLiteralType = String

  public init(unicodeScalarLiteral value: String) {
    self.init(value)
  }
}

extension EffectID: ExpressibleByExtendedGraphemeClusterLiteral where RawValue == String {
  public typealias ExtendedGraphemeClusterLiteralType = String

  public init(extendedGraphemeClusterLiteral value: String) {
    self.init(value)
  }
}

extension EffectID: ExpressibleByStringLiteral where RawValue == String {
  public typealias StringLiteralType = String

  public init(stringLiteral value: String) {
    self.init(value)
  }
}

/// The default string-literal effect identifier.
public typealias StaticEffectID = EffectID<String>

/// A type-erased effect identifier used by runtime storage and instrumentation.
public struct AnyEffectID: Hashable, Sendable, CustomStringConvertible {
  private let box: any AnyEffectIDBox

  public init<RawValue: Hashable & Sendable>(_ id: EffectID<RawValue>) {
    self.box = EffectIDBox(rawValue: id.rawValue)
  }

  /// The erased raw identifier value.
  ///
  /// Equality and hashing still include the original raw value type, so two
  /// erased IDs with the same rendered value but different raw value types
  /// remain distinct.
  public var rawValue: AnyHashable {
    box.rawValue
  }

  public var description: String {
    box.description
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.box.isEqual(to: rhs.box)
  }

  public func hash(into hasher: inout Hasher) {
    box.hash(into: &hasher)
  }
}

private protocol AnyEffectIDBox: Sendable {
  var rawValue: AnyHashable { get }
  var description: String { get }
  func isEqual(to other: any AnyEffectIDBox) -> Bool
  func hash(into hasher: inout Hasher)
}

private struct EffectIDBox<RawValue: Hashable & Sendable>: AnyEffectIDBox {
  let typedRawValue: RawValue

  init(rawValue: RawValue) {
    self.typedRawValue = rawValue
  }

  var rawValue: AnyHashable {
    AnyHashable(typedRawValue)
  }

  var description: String {
    String(describing: typedRawValue)
  }

  func isEqual(to other: any AnyEffectIDBox) -> Bool {
    guard let other = other as? Self else { return false }
    return typedRawValue == other.typedRawValue
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(Self.self))
    hasher.combine(typedRawValue)
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
  private let isCancellationRequestedProvider: @Sendable () async -> Bool
  private let checkCancellationProvider: @Sendable () async throws -> Void
  private let errorReporter: @Sendable (any Error) async -> Void

  public init(
    now: @escaping @Sendable () async -> StoreClock.Instant,
    sleep: @escaping @Sendable (Duration) async throws -> Void,
    isCancellationRequested: @escaping @Sendable () async -> Bool
  ) {
    self.nowProvider = now
    self.sleepProvider = sleep
    self.isCancellationRequestedProvider = isCancellationRequested
    self.checkCancellationProvider = {
      if await isCancellationRequested() {
        throw CancellationError()
      }
    }
    self.errorReporter = { _ in }
  }

  package init(
    now: @escaping @Sendable () async -> StoreClock.Instant,
    sleep: @escaping @Sendable (Duration) async throws -> Void,
    isCancellationRequested: @escaping @Sendable () async -> Bool,
    checkCancellation: @escaping @Sendable () async throws -> Void,
    reportError: @escaping @Sendable (any Error) async -> Void = { _ in }
  ) {
    self.nowProvider = now
    self.sleepProvider = sleep
    self.isCancellationRequestedProvider = isCancellationRequested
    self.checkCancellationProvider = checkCancellation
    self.errorReporter = reportError
  }

  public func now() async -> StoreClock.Instant {
    await nowProvider()
  }

  public func sleep(for duration: Duration) async throws {
    try await sleepProvider(duration)
  }

  /// Returns whether the effect should cooperatively stop without throwing.
  public func isCancellationRequested() async -> Bool {
    await isCancellationRequestedProvider()
  }

  /// Throws `CancellationError` when the current effect should cooperatively stop.
  public func checkCancellation() async throws {
    try await checkCancellationProvider()
  }

  /// Reports a non-cancellation error escaping an effect to the host store's
  /// instrumentation. Cancellation errors must be propagated by `throw` instead.
  package func reportError(_ error: any Error) async {
    await errorReporter(error)
  }
}

/// A unified effect model for asynchronous work in InnoFlow.
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
    case cancel(AnyEffectID)
    case cancellable(
      effect: EffectTask<Action>,
      id: AnyEffectID,
      cancelInFlight: Bool
    )
    case debounce(
      effect: EffectTask<Action>,
      id: AnyEffectID,
      interval: Duration
    )
    case throttle(
      effect: EffectTask<Action>,
      id: AnyEffectID,
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

  /// Runs an async sequence and emits each element as an action.
  ///
  /// The sequence is built from the active ``EffectContext`` so producers can use the
  /// store-controlled clock and cancellation checks. Cancellation stops the effect
  /// silently; any other thrown error is forwarded to the host store's instrumentation
  /// (`StoreInstrumentation.didFailRun`) before the effect terminates.
  public static func run<S: AsyncSequence & Sendable>(
    priority: TaskPriority? = nil,
    _ makeSequence: @escaping @Sendable (EffectContext) async throws -> S
  ) -> Self where S.Element == Action, S.AsyncIterator: Sendable {
    run(priority: priority) { send, context in
      do {
        let sequence = try await makeSequence(context)
        for try await action in sequence {
          try await context.checkCancellation()
          await send(action)
        }
      } catch is CancellationError {
        return
      } catch {
        await context.reportError(error)
      }
    }
  }

  /// Runs an async sequence and transforms each element into an optional action.
  ///
  /// Returning `nil` from `transform` drops that element without ending the effect.
  /// Cancellation stops the effect silently; any other thrown error is forwarded to
  /// the host store's instrumentation (`StoreInstrumentation.didFailRun`) before the
  /// effect terminates.
  public static func run<S: AsyncSequence & Sendable>(
    priority: TaskPriority? = nil,
    sequence makeSequence: @escaping @Sendable (EffectContext) async throws -> S,
    transform: @escaping @Sendable (S.Element) -> Action?
  ) -> Self where S.AsyncIterator: Sendable {
    run(priority: priority) { send, context in
      do {
        let sequence = try await makeSequence(context)
        for try await element in sequence {
          try await context.checkCancellation()
          guard let action = transform(element) else { continue }
          await send(action)
        }
      } catch is CancellationError {
        return
      } catch {
        await context.reportError(error)
      }
    }
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
  public static func cancel<ID: Hashable & Sendable>(_ id: EffectID<ID>) -> Self {
    cancel(AnyEffectID(id))
  }

  package static func cancel(_ id: AnyEffectID) -> Self {
    .init(operation: .cancel(id))
  }

  /// Marks this effect as cancellable.
  public func cancellable<ID: Hashable & Sendable>(
    _ id: EffectID<ID>,
    cancelInFlight: Bool = false
  ) -> Self {
    cancellable(AnyEffectID(id), cancelInFlight: cancelInFlight)
  }

  package func cancellable(_ id: AnyEffectID, cancelInFlight: Bool = false) -> Self {
    .init(operation: .cancellable(effect: self, id: id, cancelInFlight: cancelInFlight))
  }

  /// Delays effect execution and keeps only the latest run for the same id.
  ///
  /// New runs cancel prior in-flight or delayed runs sharing the same id.
  public func debounce<ID: Hashable & Sendable>(_ id: EffectID<ID>, for interval: Duration)
    -> Self
  {
    debounce(AnyEffectID(id), for: interval)
  }

  package func debounce(_ id: AnyEffectID, for interval: Duration) -> Self {
    .init(operation: .debounce(effect: self, id: id, interval: interval))
  }

  /// Runs the first effect in a window and drops subsequent runs for the same id.
  ///
  /// Leading-only semantics: first event passes, in-window events are dropped.
  public func throttle<ID: Hashable & Sendable>(_ id: EffectID<ID>, for interval: Duration) -> Self
  {
    throttle(id, for: interval, leading: true, trailing: false)
  }

  package func throttle(_ id: AnyEffectID, for interval: Duration) -> Self {
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
  public func throttle<ID: Hashable & Sendable>(
    _ id: EffectID<ID>,
    for interval: Duration,
    leading: Bool = true,
    trailing: Bool = false
  ) -> Self {
    throttle(AnyEffectID(id), for: interval, leading: leading, trailing: trailing)
  }

  package func throttle(
    _ id: AnyEffectID,
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
