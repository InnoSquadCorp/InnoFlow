// MARK: - SelectedStore.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
public import Observation

private func selectedStoreFailureMessage(
  parentType: Any.Type,
  valueType: Any.Type,
  stableID: AnyHashable?,
  reason: String
) -> String {
  let idSection = stableID.map { "\nStable ID: \($0)" } ?? ""
  return """
    SelectedStore<\(String(reflecting: valueType))> outlived its source projection from \(String(reflecting: parentType)).\(idSection)
    Reason: \(reason)
    Remediation: regenerate the selected store from the current parent store or scoped store before using it again.
    """
}

@Observable
@MainActor
@dynamicMemberLookup
public final class SelectedStore<Value: Equatable & Sendable> {
  @ObservationIgnored private var storedCachedValue: Value
  @ObservationIgnored private let cachedValueKeyPath: KeyPath<SelectedStore<Value>, Value> =
    \SelectedStore<Value>.cachedValue
  private var cachedValue: Value {
    get {
      access(keyPath: cachedValueKeyPath)
      noteTrackedRead()
      return storedCachedValue
    }
    set {
      withMutation(keyPath: cachedValueKeyPath) { storedCachedValue = newValue }
      noteObserversNotified()
    }
  }
  @ObservationIgnored private weak var parentObject: AnyObject?
  @ObservationIgnored private let sourceIsAlive: @MainActor () -> Bool
  @ObservationIgnored private let valueResolver: @MainActor () -> Value?
  @ObservationIgnored private let inactiveMessage: @MainActor () -> String
  @ObservationIgnored private let parentReleasedMessage: @MainActor () -> String
  @ObservationIgnored private var storedIsActive: Bool = true
  @ObservationIgnored private let isActiveKeyPath: KeyPath<SelectedStore<Value>, Bool> =
    \SelectedStore<Value>.isActive
  private var isActive: Bool {
    get {
      // Registers the liveness tracker only. A reader that also reads the
      // value re-arms retention there; a reader of liveness alone goes
      // through ``isAlive``, which retains until the terminal notification.
      access(keyPath: isActiveKeyPath)
      return storedIsActive
    }
    set {
      withMutation(keyPath: isActiveKeyPath) { storedIsActive = newValue }
      // Deactivation is terminal: no later notification will arrive to end a
      // grace period, so retention ends with this one.
      noteObserversNotified(isTerminal: !newValue)
    }
  }

  /// Where this selection stands relative to Observation's one-shot tracking.
  ///
  /// A reader that tracked this selection can only be notified through the
  /// selection itself, so the owner must keep it alive from a tracked read
  /// until the next notification. A notification consumes every tracker; a
  /// reader that is still interested reads again and re-arms retention.
  private enum ObservationPhase {
    /// Never read, or released after going unread across two notifications.
    case unobserved
    /// Read since the last notification: a tracker may be registered.
    case observed
    /// Notified and not read since: no tracker exists. Retention is kept for
    /// one more notification so a view that re-reads keeps the same handle.
    case notified
  }

  @ObservationIgnored private var observationPhase: ObservationPhase = .unobserved
  /// Set by a read of liveness alone. Such a reader's tracker is registered
  /// on liveness only: a value change never fires it, so it stays armed until
  /// the selection is deactivated and retention must last that long.
  @ObservationIgnored private var awaitsTerminalNotification = false
  @ObservationIgnored private weak var observationRetainer: SelectionCacheEntry?
  @ObservationIgnored private var unregisterFromParent: (@MainActor () -> Void)?

  private var needsRetention: Bool {
    observationPhase != .unobserved || awaitsTerminalNotification
  }

  private func updateRetention() {
    if needsRetention {
      observationRetainer?.retainSelection()
    } else {
      observationRetainer?.releaseSelection()
    }
  }

  private func noteTrackedRead() {
    guard observationPhase != .observed else { return }
    observationPhase = .observed
    updateRetention()
  }

  private func noteLivenessOnlyRead() {
    guard !awaitsTerminalNotification, storedIsActive else { return }
    awaitsTerminalNotification = true
    updateRetention()
  }

  private func noteObserversNotified(isTerminal: Bool = false) {
    if isTerminal {
      // Deactivation fires every tracker, liveness included, and no later
      // notification can arrive.
      observationPhase = .unobserved
      awaitsTerminalNotification = false
    } else {
      switch observationPhase {
      case .unobserved:
        break
      case .observed:
        observationPhase = .notified
      case .notified:
        observationPhase = .unobserved
      }
    }
    updateRetention()
  }

  /// Lets the owner's selection cache keep this selection alive while a
  /// tracked read may still be waiting for its notification.
  package func retainWhileObserved(by retainer: SelectionCacheEntry) {
    observationRetainer = retainer
    updateRetention()
  }

  /// Whether the owner would currently keep this selection alive without an
  /// external reference.
  package var isRetainedForObservation: Bool {
    observationRetainer != nil && needsRetention
  }

  /// Installs the hook that removes this selection from its parent's
  /// projection registry when it is deallocated.
  package func onDeinit(_ unregister: @escaping @MainActor () -> Void) {
    unregisterFromParent = unregister
  }

  // A released selection must leave its dependency bucket immediately: the
  // bucket would otherwise keep evaluating the selection's key path against
  // states the caller no longer vouches for. `@_optimize(none)` works around
  // the Swift 6.3 EarlyPerfInliner crash on generic isolated deinitializers
  // (swiftlang/swift#88173; see Store.deinit).
  @_optimize(none)
  isolated deinit {
    unregisterFromParent?()
  }

  /// Whether this selection is still backed by a live source projection.
  ///
  /// Returns `false` once the parent store or scoped store backing this
  /// selection has been released, or once the selection has been marked
  /// inactive because its source collection entry was removed. Callers
  /// can consult this before using ``SelectedStore/requireAlive(file:line:)`` or read
  /// ``optionalValue`` when a dead selection should be treated as absence.
  public var isAlive: Bool {
    let isAlive = livenessForRead
    noteLivenessOnlyRead()
    return isAlive
  }

  /// Liveness as part of a read that goes on to the value: the value read
  /// decides retention.
  private var livenessForRead: Bool {
    parentObject != nil && sourceIsAlive() && isActive
  }

  /// A read accessor that reports a released parent or inactive selection
  /// as `nil` instead of returning the last cached value.
  ///
  /// Callers that need to distinguish "value is fresh" from "parent is
  /// gone" should consult this property and treat `nil` as "regenerate
  /// the selection." When the selection's liveness is a caller-owned
  /// precondition, use ``SelectedStore/requireAlive(file:line:)`` instead — it returns `Value`
  /// directly and crashes loudly on a released parent.
  public var optionalValue: Value? {
    guard livenessForRead else { return nil }
    return cachedValue
  }

  /// Returns the cached selected value when the selection is still alive,
  /// otherwise crashes with a descriptive precondition failure.
  ///
  /// Use this from call sites that have already verified liveness (via
  /// ``isAlive``) or where reading after a released parent is a contract
  /// violation. The crash is intentionally loud in both debug and release so
  /// a missing regenerate-on-dismiss step does not silently surface stale
  /// data. SwiftUI view bodies that must survive a same-tick observer race can
  /// use dynamic-member reads instead.
  ///
  /// Replaces the removed `value` accessor whose cached fallback could
  /// silently leak stale state in release builds.
  public func requireAlive(
    file: StaticString = #fileID,
    line: UInt = #line
  ) -> Value {
    guard parentObject != nil else {
      preconditionFailure(parentReleasedMessage(), file: file, line: line)
    }
    guard sourceIsAlive(), isActive else {
      preconditionFailure(inactiveMessage(), file: file, line: line)
    }
    return cachedValue
  }

  init(
    initialValue: Value,
    parentObject: AnyObject,
    sourceIsAlive: @escaping @MainActor () -> Bool,
    valueResolver: @escaping @MainActor () -> Value?,
    inactiveMessage: @escaping @MainActor () -> String,
    parentReleasedMessage: @escaping @MainActor () -> String
  ) {
    self.storedCachedValue = initialValue
    self.parentObject = parentObject
    self.sourceIsAlive = sourceIsAlive
    self.valueResolver = valueResolver
    self.inactiveMessage = inactiveMessage
    self.parentReleasedMessage = parentReleasedMessage
  }

  public subscript<Member>(dynamicMember keyPath: KeyPath<Value, Member>) -> Member {
    // SwiftUI can read a projection on the same tick that its parent is
    // released. Match ScopedStore's observer-facing contract: diagnose the
    // stale read in debug, but keep optimized view-body evaluation alive with
    // the last valid snapshot. Non-UI callers should use optionalValue or
    // requireAlive() so their lifecycle policy remains explicit.
    guard parentObject != nil else {
      assertionFailure(parentReleasedMessage())
      return cachedValue[keyPath: keyPath]
    }
    guard sourceIsAlive(), isActive else {
      assertionFailure(inactiveMessage())
      return cachedValue[keyPath: keyPath]
    }
    return cachedValue[keyPath: keyPath]
  }
}

extension SelectedStore: ProjectionObserver {
  package func refreshFromParentStore() -> Bool {
    // Internal bookkeeping reads the stored values directly: a refresh is not
    // an observation and must neither register a tracker nor re-arm retention.
    guard storedIsActive else { return false }
    guard parentObject != nil, sourceIsAlive() else {
      isActive = false
      return true
    }
    guard let nextValue = valueResolver() else {
      isActive = false
      return true
    }
    if nextValue != storedCachedValue {
      cachedValue = nextValue
      return true
    }
    return false
  }
}

private func selectionDependencyRegistration<Snapshot, Dependency: Equatable>(
  _ keyPath: KeyPath<Snapshot, Dependency>
) -> ProjectionDependencyRegistration<Snapshot> {
  .init(
    .keyPath(keyPath as AnyKeyPath),
    hasChanged: { previousState, nextState in
      previousState[keyPath: keyPath] != nextState[keyPath: keyPath]
    }
  )
}

private func selectionDependencyRegistrations<Snapshot>(
  _ registrations: ProjectionDependencyRegistration<Snapshot>...
) -> ProjectionObserverRegistration<Snapshot> {
  selectionDependencyRegistrations(fromArray: registrations)
}

private func selectionDependencyRegistrations<Snapshot>(
  fromArray registrations: [ProjectionDependencyRegistration<Snapshot>]
) -> ProjectionObserverRegistration<Snapshot> {
  guard !registrations.isEmpty else {
    return .alwaysRefresh
  }

  if registrations.count == 1, let registration = registrations.first {
    return .dependency(registration.key, hasChanged: registration.hasChanged)
  }

  return .dependencies(registrations)
}

private func alwaysRefreshSelectionRegistration<Snapshot>(
  callsite: SelectionCallsite
) -> ProjectionObserverRegistration<Snapshot> {
  .dependency(
    .custom(callsite),
    hasChanged: { _, _ in true }
  )
}

private func memoizedCustomSelectionRegistration<Snapshot: Equatable>(
  callsite: SelectionCallsite
) -> ProjectionObserverRegistration<Snapshot> {
  // Snapshot-equality short-circuits valueResolver invocation when the
  // parent state has not changed between refresh passes. Pair this with
  // `select(_:memoize:)` for closure-only selections whose selector
  // body is expensive enough that always-rerun pays a real cost.
  .dependency(
    .memoizedCustom(callsite),
    hasChanged: { $0 != $1 }
  )
}

private func selectionCacheKey(
  callsite: SelectionCallsite,
  signature: SelectionSignature,
  semanticID: String? = nil
) -> SelectionCacheKey {
  .init(callsite: callsite, signature: signature, semanticID: semanticID)
}

private func scopedSelectionCallsite(
  fileID: StaticString,
  line: UInt,
  column: UInt
) -> SelectionCallsite {
  .init(fileID: fileID.description, line: line, column: column)
}

extension Store {
  private func cachedSelectedStore<Value: Equatable & Sendable>(
    cacheKey: SelectionCacheKey?,
    initialValue: @autoclosure () -> Value,
    registration: ProjectionObserverRegistration<R.State>,
    valueResolver: @escaping @MainActor () -> Value?
  ) -> SelectedStore<Value> {
    let cacheKey = cacheKey?.forValueType(Value.self)
    if let cacheKey,
      let cached: SelectedStore<Value> = selectionCache.cached(
        for: cacheKey, valueType: Value.self)
    {
      return cached
    }

    let lifetime = self.lifetime
    let selectedStore = SelectedStore(
      initialValue: initialValue(),
      parentObject: self,
      sourceIsAlive: { @MainActor in
        !lifetime.isReleased
      },
      valueResolver: valueResolver,
      inactiveMessage: { @MainActor @Sendable in
        selectedStoreFailureMessage(
          parentType: R.self,
          valueType: Value.self,
          stableID: nil,
          reason: "the parent store was released"
        )
      },
      parentReleasedMessage: { @MainActor @Sendable in
        selectedStoreFailureMessage(
          parentType: R.self,
          valueType: Value.self,
          stableID: nil,
          reason: "the parent store was released"
        )
      }
    )
    if let cacheKey {
      selectionCache.store(selectedStore, for: cacheKey, valueType: Value.self)
    }
    registerProjectionObserver(selectedStore, registration: registration)
    let observerID = ObjectIdentifier(selectedStore)
    selectedStore.onDeinit { [weak self] in
      self?.unregisterProjectionObserver(observerID)
    }
    return selectedStore
  }

  public func select<Value: Equatable & Sendable>(
    _ keyPath: KeyPath<R.State, Value>,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    column: UInt = #column
  ) -> SelectedStore<Value> {
    let callsite = selectionCallsite(fileID: fileID, line: line, column: column)
    return cachedSelectedStore(
      cacheKey: selectionCacheKey(
        callsite: callsite,
        signature: .keyPath(keyPath as AnyKeyPath)
      ),
      initialValue: untrackedState[keyPath: keyPath],
      registration: selectionDependencyRegistrations(
        selectionDependencyRegistration(keyPath)
      ),
      valueResolver: { [weak self] in
        guard let self else { return nil }
        return self.state[keyPath: keyPath]
      }
    )
  }

  /// Creates a derived selection. Each call without `id` owns an independent
  /// selector, even when the source location and dependency are identical.
  /// Supply a stable `id` only when repeated calls have the same captured
  /// inputs and meaning. Live matching handles are reused; the cache keeps
  /// them weakly, so callers that require persistent identity must retain one.
  public func select<Dependency: Equatable & Sendable, Value: Equatable & Sendable>(
    dependingOn dependency: KeyPath<R.State, Dependency>,
    id: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    column: UInt = #column,
    _ transform: @escaping @Sendable (Dependency) -> Value
  ) -> SelectedStore<Value> {
    let callsite = selectionCallsite(fileID: fileID, line: line, column: column)
    return cachedSelectedStore(
      cacheKey: id.map {
        selectionCacheKey(
          callsite: callsite,
          signature: .singleDependency(dependency as AnyKeyPath),
          semanticID: $0
        )
      },
      initialValue: transform(untrackedState[keyPath: dependency]),
      registration: selectionDependencyRegistrations(
        selectionDependencyRegistration(dependency)
      ),
      valueResolver: { [weak self] in
        guard let self else { return nil }
        return transform(self.state[keyPath: dependency])
      }
    )
  }

  /// Variadic selection: declares an arbitrary number of explicit
  /// dependency key paths through Swift parameter packs and projects them
  /// into a derived value.
  ///
  /// Use this overload whenever a projection depends on two or more state
  /// fields. The single-field convenience `select(dependingOn:)` remains
  /// available for the common one-dependency case; the closure-only
  /// `select(_:)` form is reserved for projections that cannot enumerate
  /// their dependencies and intentionally fall back to `.alwaysRefresh`.
  public func select<each Dep: Equatable & Sendable, Value: Equatable & Sendable>(
    dependingOnAll dependencies: repeat KeyPath<R.State, each Dep>,
    id: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    column: UInt = #column,
    _ transform: @escaping @Sendable (repeat each Dep) -> Value
  ) -> SelectedStore<Value> {
    let callsite = selectionCallsite(fileID: fileID, line: line, column: column)

    var registrations: [ProjectionDependencyRegistration<R.State>] = []
    var dependencyKeyPaths: [AnyKeyPath] = []
    for keyPath in repeat each dependencies {
      registrations.append(selectionDependencyRegistration(keyPath))
      dependencyKeyPaths.append(keyPath as AnyKeyPath)
    }

    return cachedSelectedStore(
      cacheKey: id.map {
        selectionCacheKey(
          callsite: callsite,
          signature: .dependencies(dependencyKeyPaths),
          semanticID: $0
        )
      },
      initialValue: transform(repeat untrackedState[keyPath: each dependencies]),
      registration: selectionDependencyRegistrations(fromArray: registrations),
      valueResolver: { [weak self] in
        guard let self else { return nil }
        return transform(repeat self.state[keyPath: each dependencies])
      }
    )
  }

  public func select<Value: Equatable & Sendable>(
    id: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    column: UInt = #column,
    _ selector: @escaping @Sendable (R.State) -> Value
  ) -> SelectedStore<Value> {
    let callsite = selectionCallsite(fileID: fileID, line: line, column: column)
    return cachedSelectedStore(
      cacheKey: id.map {
        selectionCacheKey(
          callsite: callsite,
          signature: .closureSelector(memoized: false),
          semanticID: $0
        )
      },
      initialValue: selector(untrackedState),
      registration: alwaysRefreshSelectionRegistration(callsite: callsite),
      valueResolver: { [weak self] in
        guard let self else { return nil }
        return selector(self.state)
      }
    )
  }

  /// Memoized closure-only selection: requires `R.State: Equatable` so the
  /// projection registry can skip a refresh pass entirely when the parent
  /// snapshot is unchanged. Pass `memoize: false` to retain the legacy
  /// always-refresh contract.
  public func select<Value: Equatable & Sendable>(
    id: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    column: UInt = #column,
    memoize: Bool,
    _ selector: @escaping @Sendable (R.State) -> Value
  ) -> SelectedStore<Value> where R.State: Equatable {
    let callsite = selectionCallsite(fileID: fileID, line: line, column: column)
    let registration: ProjectionObserverRegistration<R.State> =
      memoize
      ? memoizedCustomSelectionRegistration(callsite: callsite)
      : alwaysRefreshSelectionRegistration(callsite: callsite)
    return cachedSelectedStore(
      cacheKey: id.map {
        selectionCacheKey(
          callsite: callsite,
          signature: .closureSelector(memoized: memoize),
          semanticID: $0
        )
      },
      initialValue: selector(untrackedState),
      registration: registration,
      valueResolver: { [weak self] in
        guard let self else { return nil }
        return selector(self.state)
      }
    )
  }
}

extension ScopedStore {
  private func cachedSelectedStore<Value: Equatable & Sendable>(
    cacheKey: SelectionCacheKey?,
    initialValue: @autoclosure () -> Value,
    registration: ProjectionObserverRegistration<ChildState>,
    valueResolver: @escaping @MainActor () -> Value?
  ) -> SelectedStore<Value> {
    let cacheKey = cacheKey?.forValueType(Value.self)
    if let cacheKey,
      let cached: SelectedStore<Value> = selectionCache.cached(
        for: cacheKey, valueType: Value.self)
    {
      return cached
    }

    let selectedStore = SelectedStore(
      initialValue: initialValue(),
      parentObject: self,
      sourceIsAlive: { @MainActor [weak self] in
        self?.isAlive == true
      },
      valueResolver: valueResolver,
      inactiveMessage: { @MainActor @Sendable [weak self] in
        guard let self else {
          return selectedStoreFailureMessage(
            parentType: ParentReducer.self,
            valueType: Value.self,
            stableID: nil,
            reason: "the parent scoped store was released"
          )
        }
        return selectedStoreFailureMessage(
          parentType: ParentReducer.self,
          valueType: Value.self,
          stableID: self.stableID,
          reason: self.failureKind == .collectionEntryRemoved
            ? "the source collection entry was removed"
            : "the parent scoped store became unavailable"
        )
      },
      parentReleasedMessage: { @MainActor @Sendable [weak self] in
        selectedStoreFailureMessage(
          parentType: ParentReducer.self,
          valueType: Value.self,
          stableID: self?.stableID,
          reason: "the parent scoped store was released"
        )
      }
    )
    if let cacheKey {
      selectionCache.store(selectedStore, for: cacheKey, valueType: Value.self)
    }
    observerRegistry.register(selectedStore, registration: registration)
    let observerID = ObjectIdentifier(selectedStore)
    selectedStore.onDeinit { [weak observerRegistry] in
      observerRegistry?.unregister(observerID)
    }
    return selectedStore
  }

  public func select<Value: Equatable & Sendable>(
    _ keyPath: KeyPath<ChildState, Value>,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    column: UInt = #column
  ) -> SelectedStore<Value> {
    let callsite = scopedSelectionCallsite(fileID: fileID, line: line, column: column)
    return cachedSelectedStore(
      cacheKey: selectionCacheKey(
        callsite: callsite,
        signature: .keyPath(keyPath as AnyKeyPath)
      ),
      initialValue: untrackedState[keyPath: keyPath],
      registration: selectionDependencyRegistrations(
        selectionDependencyRegistration(keyPath)
      ),
      valueResolver: { [weak self] in
        guard let self, self.isActive else { return nil }
        return self.cachedState[keyPath: keyPath]
      }
    )
  }

  /// Closure selections are independent unless a stable semantic `id` is
  /// supplied. Include every captured input that can change the result in it.
  public func select<Dependency: Equatable & Sendable, Value: Equatable & Sendable>(
    dependingOn dependency: KeyPath<ChildState, Dependency>,
    id: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    column: UInt = #column,
    _ transform: @escaping @Sendable (Dependency) -> Value
  ) -> SelectedStore<Value> {
    let callsite = scopedSelectionCallsite(fileID: fileID, line: line, column: column)
    return cachedSelectedStore(
      cacheKey: id.map {
        selectionCacheKey(
          callsite: callsite,
          signature: .singleDependency(dependency as AnyKeyPath),
          semanticID: $0
        )
      },
      initialValue: transform(untrackedState[keyPath: dependency]),
      registration: selectionDependencyRegistrations(
        selectionDependencyRegistration(dependency)
      ),
      valueResolver: { [weak self] in
        guard let self, self.isActive else { return nil }
        return transform(self.cachedState[keyPath: dependency])
      }
    )
  }

  /// Variadic selection: declares an arbitrary number of explicit child-state
  /// dependency key paths through Swift parameter packs and projects them into
  /// a derived value.
  ///
  /// Use this overload whenever a scoped projection depends on two or more
  /// child-state fields. The single-field convenience
  /// `select(dependingOn:)` remains available for the common
  /// one-dependency case; the closure-only `select(_:)` form is reserved
  /// for projections that cannot enumerate their dependencies and
  /// intentionally fall back to `.alwaysRefresh`.
  public func select<each Dep: Equatable & Sendable, Value: Equatable & Sendable>(
    dependingOnAll dependencies: repeat KeyPath<ChildState, each Dep>,
    id: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    column: UInt = #column,
    _ transform: @escaping @Sendable (repeat each Dep) -> Value
  ) -> SelectedStore<Value> {
    let callsite = scopedSelectionCallsite(fileID: fileID, line: line, column: column)

    var registrations: [ProjectionDependencyRegistration<ChildState>] = []
    var dependencyKeyPaths: [AnyKeyPath] = []
    for keyPath in repeat each dependencies {
      registrations.append(selectionDependencyRegistration(keyPath))
      dependencyKeyPaths.append(keyPath as AnyKeyPath)
    }

    return cachedSelectedStore(
      cacheKey: id.map {
        selectionCacheKey(
          callsite: callsite,
          signature: .dependencies(dependencyKeyPaths),
          semanticID: $0
        )
      },
      initialValue: transform(repeat untrackedState[keyPath: each dependencies]),
      registration: selectionDependencyRegistrations(fromArray: registrations),
      valueResolver: { [weak self] in
        guard let self, self.isActive else { return nil }
        return transform(repeat self.cachedState[keyPath: each dependencies])
      }
    )
  }

  public func select<Value: Equatable & Sendable>(
    id: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    column: UInt = #column,
    _ selector: @escaping @Sendable (ChildState) -> Value
  ) -> SelectedStore<Value> {
    let callsite = scopedSelectionCallsite(fileID: fileID, line: line, column: column)
    return cachedSelectedStore(
      cacheKey: id.map {
        selectionCacheKey(
          callsite: callsite,
          signature: .closureSelector(memoized: false),
          semanticID: $0
        )
      },
      initialValue: selector(untrackedState),
      registration: alwaysRefreshSelectionRegistration(callsite: callsite),
      valueResolver: { [weak self] in
        guard let self, self.isActive else { return nil }
        return selector(self.cachedState)
      }
    )
  }

  /// Memoized closure-only selection: ChildState is already required to be
  /// `Equatable`, so the projection registry can skip refresh passes whose
  /// child snapshot is unchanged. Pass `memoize: false` to retain the
  /// legacy always-refresh contract.
  public func select<Value: Equatable & Sendable>(
    id: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    column: UInt = #column,
    memoize: Bool,
    _ selector: @escaping @Sendable (ChildState) -> Value
  ) -> SelectedStore<Value> {
    let callsite = scopedSelectionCallsite(fileID: fileID, line: line, column: column)
    let registration: ProjectionObserverRegistration<ChildState> =
      memoize
      ? memoizedCustomSelectionRegistration(callsite: callsite)
      : alwaysRefreshSelectionRegistration(callsite: callsite)
    return cachedSelectedStore(
      cacheKey: id.map {
        selectionCacheKey(
          callsite: callsite,
          signature: .closureSelector(memoized: memoize),
          semanticID: $0
        )
      },
      initialValue: selector(untrackedState),
      registration: registration,
      valueResolver: { [weak self] in
        guard let self, self.isActive else { return nil }
        return selector(self.cachedState)
      }
    )
  }
}
