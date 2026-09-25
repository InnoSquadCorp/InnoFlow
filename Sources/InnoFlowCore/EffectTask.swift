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

  /// Creates an `EffectContext` for use inside `EffectTask.run`.
  ///
  /// `errorReporter` mirrors the package init's `reportError` hook so user-supplied
  /// contexts (typically in tests or custom drivers) can surface non-cancellation
  /// errors that escape an `AsyncSequence` run. Cancellation errors must still be
  /// propagated by `throw`, not reported here.
  public init(
    now: @escaping @Sendable () async -> StoreClock.Instant,
    sleep: @escaping @Sendable (Duration) async throws -> Void,
    isCancellationRequested: @escaping @Sendable () async -> Bool,
    errorReporter: @escaping @Sendable (any Error) async -> Void = { _ in }
  ) {
    self.nowProvider = now
    self.sleepProvider = sleep
    self.isCancellationRequestedProvider = isCancellationRequested
    self.checkCancellationProvider = {
      if await isCancellationRequested() {
        throw CancellationError()
      }
    }
    self.errorReporter = errorReporter
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

  /// Reports a non-cancellation error escaping an effect to the host driver's
  /// failure channel. Cancellation errors must be propagated by `throw` instead.
  ///
  /// First-error-wins per run: Store suppresses the trailing `didFinishRun`,
  /// while TestStore records one assertion failure. Effects that wish to
  /// surface multiple failures must aggregate them before calling this.
  package func reportError(_ error: any Error) async {
    await errorReporter(error)
  }
}

/// A unified, output-typed effect model for asynchronous work in InnoFlow.
///
/// Most features use the ``EffectTask`` compatibility spelling, whose output
/// is `Never`. Reducers that emit coordinator events use this full type so the
/// output remains checked through composition and store delivery.
public struct ReducerEffect<Action: Sendable, Output: Sendable>: Sendable {
  package struct LazyMappedEffect: Sendable {
    private let materializeEffect: @Sendable () -> ReducerEffect<Action, Output>

    package init(_ materializeEffect: @escaping @Sendable () -> ReducerEffect<Action, Output>) {
      self.materializeEffect = materializeEffect
    }

    package func materialize() -> ReducerEffect<Action, Output> {
      materializeEffect()
    }
  }

  package indirect enum Operation: Sendable {
    case none
    case send(Action)
    case output(Output)
    case run(
      priority: TaskPriority?, operation: @Sendable (Send<Action>, EffectContext) async -> Void)
    case scheduledRun(
      id: AnyEffectID,
      policy: EffectExecutionPolicy,
      priority: TaskPriority?,
      onAdmission: (@Sendable (EffectAdmission) -> Action)?,
      operation: @Sendable (Send<Action>, EffectContext) async -> Void
    )
    case merge([ReducerEffect<Action, Output>])
    case concatenate([ReducerEffect<Action, Output>])
    case cancel(AnyEffectID)
    case cancellable(
      effect: ReducerEffect<Action, Output>,
      id: AnyEffectID,
      cancelInFlight: Bool
    )
    case debounce(
      effect: ReducerEffect<Action, Output>,
      id: AnyEffectID,
      interval: Duration
    )
    case throttle(
      effect: ReducerEffect<Action, Output>,
      id: AnyEffectID,
      interval: Duration,
      leading: Bool,
      trailing: Bool
    )
    case animation(
      effect: ReducerEffect<Action, Output>,
      animation: EffectAnimation
    )
    case lazyMap(LazyMappedEffect)
    /// Routes a drop event through the effect walker so reducers that do not
    /// own `Send` (e.g., `IfLet`/`IfCaseLet`) can still surface
    /// `StoreInstrumentation.didDropAction` to the host store.
    case diagnosticDrop(action: Action, reason: ActionDropReason)
  }

  package let operation: Operation

  /// Cancellation IDs precomputed at construction, or `nil` when the subtree
  /// contains a `.lazyMap` node — materializing those at construction would
  /// defeat the laziness they exist for, so lazy subtrees fall back to the
  /// recursive walk on access.
  private let cachedPotentialCancellationIDs: Set<AnyEffectID>?

  package init(operation: Operation) {
    self.operation = operation
    self.cachedPotentialCancellationIDs = Self.eagerPotentialCancellationIDs(of: operation)
  }

  /// Cancellation identifiers that this concrete effect tree may still introduce.
  ///
  /// The runtime uses this finite set to retain pre-registration cancellation
  /// state only for IDs the active interpreter can actually discover. The set
  /// is computed once at construction (children carry their own cached sets,
  /// so composing N effects costs O(N), not a fresh tree walk); only subtrees
  /// containing `.lazyMap` recompute on access.
  package var potentialCancellationIDs: Set<AnyEffectID> {
    cachedPotentialCancellationIDs ?? Self.walkPotentialCancellationIDs(of: operation)
  }

  /// Construction-time variant: returns `nil` as soon as a `.lazyMap` node is
  /// involved so laziness is preserved.
  private static func eagerPotentialCancellationIDs(
    of operation: Operation
  ) -> Set<AnyEffectID>? {
    switch operation {
    case .none, .send, .output, .run, .cancel, .diagnosticDrop:
      return []

    case .scheduledRun(let id, _, _, _, _):
      return [id]

    case .merge(let effects), .concatenate(let effects):
      var ids: Set<AnyEffectID> = []
      for effect in effects {
        guard let childIDs = effect.cachedPotentialCancellationIDs else { return nil }
        ids.formUnion(childIDs)
      }
      return ids

    case .cancellable(let effect, let id, _),
      .debounce(let effect, let id, _):
      guard let childIDs = effect.cachedPotentialCancellationIDs else { return nil }
      return childIDs.union([id])

    case .throttle(let effect, let id, _, _, _):
      guard let childIDs = effect.cachedPotentialCancellationIDs else { return nil }
      return childIDs.union([id])

    case .animation(let effect, _):
      return effect.cachedPotentialCancellationIDs

    case .lazyMap:
      return nil
    }
  }

  /// Access-time fallback for lazy subtrees; materializes `.lazyMap` nodes.
  private static func walkPotentialCancellationIDs(
    of operation: Operation
  ) -> Set<AnyEffectID> {
    switch operation {
    case .none, .send, .output, .run, .cancel, .diagnosticDrop:
      return []

    case .scheduledRun(let id, _, _, _, _):
      return [id]

    case .merge(let effects), .concatenate(let effects):
      return effects.reduce(into: []) { ids, effect in
        ids.formUnion(effect.potentialCancellationIDs)
      }

    case .cancellable(let effect, let id, _),
      .debounce(let effect, let id, _):
      return effect.potentialCancellationIDs.union([id])

    case .throttle(let effect, let id, _, _, _):
      return effect.potentialCancellationIDs.union([id])

    case .animation(let effect, _):
      return effect.potentialCancellationIDs

    case .lazyMap(let lazyMapped):
      return lazyMapped.materialize().potentialCancellationIDs
    }
  }

  /// No effect.
  public static var none: Self {
    .init(operation: .none)
  }

  /// Returns `true` when this effect has no work to perform.
  ///
  /// Public (rather than `package`) because inlinable hot paths such as
  /// `Reduce.reduce(into:action:)` need it to skip `.none` children without
  /// exposing the underlying `Operation` storage.
  public var isNone: Bool {
    if case .none = operation { return true }
    return false
  }

  /// Emit a single action immediately.
  public static func send(_ action: Action) -> Self {
    .init(operation: .send(action))
  }

  /// Builds the internal output node used by reducer-typed `Self.output(...)`.
  package static func output(_ output: Output) -> Self {
    .init(operation: .output(output))
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

  /// Schedules one asynchronous run in a Store-local execution lane.
  ///
  /// Unlike `concatenate(_:)`, this policy applies across independent
  /// dispatches that use the same typed effect ID. Cancellation remains
  /// cooperative; only `serial` waits for physical operation completion before
  /// starting its successor.
  public static func run<ID: Hashable & Sendable>(
    id: EffectID<ID>,
    policy: EffectExecutionPolicy,
    priority: TaskPriority? = nil,
    _ operation: @escaping @Sendable (Send<Action>, EffectContext) async -> Void
  ) -> Self {
    scheduledRun(
      id: AnyEffectID(id),
      policy: policy,
      priority: priority,
      onAdmission: nil,
      operation: operation
    )
  }

  /// Schedules one asynchronous run and maps admission changes back to actions.
  ///
  /// A queued request first emits `.queued` and emits `.started` when it later
  /// acquires the lane. A rejected request never executes `operation`.
  public static func run<ID: Hashable & Sendable>(
    id: EffectID<ID>,
    policy: EffectExecutionPolicy,
    priority: TaskPriority? = nil,
    onAdmission: @escaping @Sendable (EffectAdmission) -> Action,
    _ operation: @escaping @Sendable (Send<Action>, EffectContext) async -> Void
  ) -> Self {
    scheduledRun(
      id: AnyEffectID(id),
      policy: policy,
      priority: priority,
      onAdmission: onAdmission,
      operation: operation
    )
  }

  private static func scheduledRun(
    id: AnyEffectID,
    policy: EffectExecutionPolicy,
    priority: TaskPriority?,
    onAdmission: (@Sendable (EffectAdmission) -> Action)?,
    operation: @escaping @Sendable (Send<Action>, EffectContext) async -> Void
  ) -> Self {
    return .init(
      operation: .scheduledRun(
        id: id,
        policy: policy,
        priority: priority,
        onAdmission: onAdmission,
        operation: operation
      )
    )
  }

  /// Performs one throwing async operation and maps its terminal result to an action.
  ///
  /// Cancellation is terminal and silent: neither `success` nor `failure` is
  /// invoked after cancellation has been accepted by the host store.
  public static func perform<Success: Sendable>(
    priority: TaskPriority? = nil,
    operation: @escaping @Sendable (EffectContext) async throws -> Success,
    success: @escaping @Sendable (Success) -> Action,
    failure: @escaping @Sendable (any Error) -> Action
  ) -> Self {
    .run(priority: priority) { send, context in
      do {
        try await context.checkCancellation()
        let value = try await operation(context)
        try await context.checkCancellation()
        await send(success(value))
      } catch is CancellationError {
        return
      } catch {
        guard await context.isCancellationRequested() == false else { return }
        await send(failure(error))
      }
    }
  }

  /// Convenience overload for operations that do not need ``EffectContext``.
  public static func perform<Success: Sendable>(
    priority: TaskPriority? = nil,
    operation: @escaping @Sendable () async throws -> Success,
    success: @escaping @Sendable (Success) -> Action,
    failure: @escaping @Sendable (any Error) -> Action
  ) -> Self {
    perform(
      priority: priority,
      operation: { _ in try await operation() },
      success: success,
      failure: failure
    )
  }

  /// Runs an async sequence and emits each element as an action.
  ///
  /// The sequence is built from the active ``EffectContext`` so producers can use the
  /// store-controlled clock and cancellation checks. Cancellation stops the effect
  /// silently; any other thrown error from an active run is forwarded to the host
  /// runtime's failure channel before the effect terminates. If host cancellation
  /// is accepted first, a later error from uncooperative work is discarded. `Store`
  /// emits `StoreInstrumentation.didFailRun`; `TestStore` records an assertion failure.
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
  /// Cancellation stops the effect silently; any other thrown error from an active
  /// run is forwarded to the host runtime's failure channel before the effect
  /// terminates. If host cancellation is accepted first, a later error from
  /// uncooperative work is discarded. `Store` emits `StoreInstrumentation.didFailRun`;
  /// `TestStore` records an assertion failure.
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
  ///
  /// Cancellation is rechecked before every child, including children inside
  /// nested concatenations. Once cancellation is accepted, remaining effects
  /// are not started.
  public static func concatenate(_ effects: Self...) -> Self {
    concatenate(effects)
  }

  /// Runs effects sequentially from a collection.
  ///
  /// Cancellation is rechecked before every child, including children inside
  /// nested concatenations. Once cancellation is accepted, remaining effects
  /// are not started.
  public static func concatenate(_ effects: [Self]) -> Self {
    let live = effects.filter { !$0.isNone }
    guard !live.isEmpty else { return .none }
    if live.count == 1 { return live[0] }
    return .init(operation: .concatenate(live))
  }

  /// Emits an `ActionDropEvent` through the host store's instrumentation
  /// without re-delivering the action. Used by composition primitives that
  /// detect a structurally-invalid action (e.g., `IfLet` with `nil` child
  /// state) and need to surface the drop in release builds.
  package static func reportDrop(_ action: Action, reason: ActionDropReason) -> Self {
    .init(operation: .diagnosticDrop(action: action, reason: reason))
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
  ) -> ReducerEffect<NewAction, Output> {
    switch operation {
    case .none:
      return .none

    case .send(let action):
      return .send(transform(action))

    case .output(let output):
      return .init(operation: .output(output))

    case .cancel(let id):
      return .cancel(id)

    case .lazyMap:
      return eagerMap(transform)

    case .diagnosticDrop(let action, let reason):
      return .reportDrop(transform(action), reason: reason)

    case .run, .scheduledRun, .merge, .concatenate, .cancellable, .debounce, .throttle, .animation:
      // Flatten the 1-stage map fast path: rather than wrapping the source in
      // a `.lazyMap` (one closure allocation now + one indirect materialize
      // on each walk), rewrite the operation tree eagerly. The work is
      // identical to what `EffectWalker` would have done via
      // `lazyMapped.materialize()`, just paid at construction time, so the
      // run-time path skips a heap-allocated closure box and an extra
      // dispatch through the `.lazyMap` case in `EffectWalker.walk`.
      return eagerMap(transform)
    }
  }

  /// Maps this effect's declared reducer output into a parent output type.
  ///
  /// Use ``Reducer/mapOutput(_:)`` at a feature boundary so child output
  /// ownership stays explicit while action cancellation semantics are kept.
  package func mapOutput<NewOutput: Sendable>(
    _ transform: @escaping @Sendable (Output) -> NewOutput
  ) -> ReducerEffect<Action, NewOutput> {
    switch operation {
    case .none:
      return .none

    case .send(let action):
      return .send(action)

    case .run(let priority, let operation):
      return .run(priority: priority, operation)

    case .scheduledRun(let id, let policy, let priority, let onAdmission, let operation):
      return .init(
        operation: .scheduledRun(
          id: id,
          policy: policy,
          priority: priority,
          onAdmission: onAdmission,
          operation: operation
        )
      )

    case .cancel(let id):
      return .cancel(id)

    case .diagnosticDrop(let action, let reason):
      return .reportDrop(action, reason: reason)

    case .output(let output):
      return .output(transform(output))

    case .merge(let effects):
      return .merge(effects.map { $0.mapOutput(transform) })

    case .concatenate(let effects):
      return .concatenate(effects.map { $0.mapOutput(transform) })

    case .cancellable(let effect, let id, let cancelInFlight):
      return effect.mapOutput(transform).cancellable(id, cancelInFlight: cancelInFlight)

    case .debounce(let effect, let id, let interval):
      return effect.mapOutput(transform).debounce(id, for: interval)

    case .throttle(let effect, let id, let interval, let leading, let trailing):
      return effect.mapOutput(transform).throttle(
        id,
        for: interval,
        leading: leading,
        trailing: trailing
      )

    case .animation(let effect, let animation):
      return effect.mapOutput(transform).applyingAnimation(animation)

    case .lazyMap(let lazyMapped):
      return lazyMapped.materialize().mapOutput(transform)
    }
  }

  private func eagerMap<NewAction: Sendable>(
    _ transform: @escaping @Sendable (Action) -> NewAction
  ) -> ReducerEffect<NewAction, Output> {
    var current = self
    while case .lazyMap(let lazyMapped) = current.operation {
      current = lazyMapped.materialize()
    }

    switch current.operation {
    case .none:
      return .none

    case .send(let action):
      return .send(transform(action))

    case .output(let output):
      return .init(operation: .output(output))

    case .run(let priority, let operation):
      return .run(priority: priority) { send, context in
        let mappedSend = Send<Action> { action in
          await send(transform(action))
        }
        await operation(mappedSend, context)
      }

    case .scheduledRun(let id, let policy, let priority, let onAdmission, let operation):
      let mappedAdmission: (@Sendable (EffectAdmission) -> NewAction)?
      if let onAdmission {
        mappedAdmission = { admission in
          transform(onAdmission(admission))
        }
      } else {
        mappedAdmission = nil
      }
      return .init(
        operation: .scheduledRun(
          id: id,
          policy: policy,
          priority: priority,
          onAdmission: mappedAdmission,
          operation: { send, context in
            let mappedSend = Send<Action> { action in
              await send(transform(action))
            }
            await operation(mappedSend, context)
          }
        )
      )

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

    case .diagnosticDrop(let action, let reason):
      return .reportDrop(transform(action), reason: reason)

    case .lazyMap:
      preconditionFailure(
        "lazyMap layers must be flattened before eagerMap switches on the concrete operation")
    }
  }
}

/// The source-compatible spelling for reducers that do not emit outputs.
public typealias EffectTask<Action: Sendable> = ReducerEffect<Action, Never>
