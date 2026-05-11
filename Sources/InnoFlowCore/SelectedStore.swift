// MARK: - SelectedStore.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import Observation

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
  private var cachedValue: Value
  @ObservationIgnored private weak var parentObject: AnyObject?
  @ObservationIgnored private let valueResolver: @MainActor () -> Value?
  @ObservationIgnored private let inactiveMessage: @MainActor () -> String
  @ObservationIgnored private let parentReleasedMessage: @MainActor () -> String
  @ObservationIgnored private var isActive = true

  /// Whether this selection is still backed by a live source projection.
  ///
  /// Returns `false` once the parent store or scoped store backing this
  /// selection has been released, or once the selection has been marked
  /// inactive because its source collection entry was removed. Callers
  /// can consult this before reading `value` to avoid the cached-fallback
  /// path documented in the lifecycle contract.
  public var isAlive: Bool {
    parentObject != nil && isActive
  }

  /// A read accessor that reports a released parent or inactive selection
  /// as `nil` instead of returning the last cached value.
  ///
  /// Callers that need to distinguish "value is fresh" from "parent is
  /// gone" should consult this property and treat `nil` as "regenerate
  /// the selection." When the selection's liveness is a precondition of
  /// the call site (e.g., the value is read inside a SwiftUI view body
  /// guarded by `if selected.isAlive`), use ``requireAlive()`` instead —
  /// it returns `Value` directly and crashes loudly on a released parent.
  public var optionalValue: Value? {
    guard isAlive else { return nil }
    return cachedValue
  }

  /// Returns the cached selected value when the selection is still alive,
  /// otherwise crashes with a descriptive precondition failure.
  ///
  /// Use this from call sites that have already verified liveness (via
  /// ``isAlive``) or where reading after a released parent is a contract
  /// violation — for instance, inside a tightly-scoped SwiftUI view body
  /// that takes its lifetime from the parent store. The crash is
  /// intentionally loud in both debug and release so a missing
  /// regenerate-on-dismiss step does not silently surface stale data.
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
    guard isActive else {
      preconditionFailure(inactiveMessage(), file: file, line: line)
    }
    return cachedValue
  }

  init(
    initialValue: Value,
    parentObject: AnyObject,
    valueResolver: @escaping @MainActor () -> Value?,
    inactiveMessage: @escaping @MainActor () -> String,
    parentReleasedMessage: @escaping @MainActor () -> String
  ) {
    self.cachedValue = initialValue
    self.parentObject = parentObject
    self.valueResolver = valueResolver
    self.inactiveMessage = inactiveMessage
    self.parentReleasedMessage = parentReleasedMessage
  }

  public subscript<Member>(dynamicMember keyPath: KeyPath<Value, Member>) -> Member {
    // dynamicMember reads route through `requireAlive()` so a released
    // parent or inactive selection surfaces as a loud precondition
    // failure rather than a silent stale-cache read. Call sites that
    // tolerate dead selections must use `optionalValue` explicitly.
    requireAlive()[keyPath: keyPath]
  }
}

extension SelectedStore: ProjectionObserver {
  package func refreshFromParentStore() -> Bool {
    guard isActive else { return false }
    guard parentObject != nil else {
      isActive = false
      return true
    }
    guard let nextValue = valueResolver() else {
      isActive = false
      return true
    }
    if nextValue != cachedValue {
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
    .custom(callsite),
    hasChanged: { $0 != $1 }
  )
}

private func selectionCacheKey(
  callsite: SelectionCallsite,
  signature: SelectionSignature
) -> SelectionCacheKey {
  .init(callsite: callsite, signature: signature)
}

private func selectionCacheKey(
  callsite: SelectionCallsite,
  dependencyKeyPaths: [AnyKeyPath]
) -> SelectionCacheKey {
  selectionCacheKey(callsite: callsite, signature: .dependencies(dependencyKeyPaths))
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
    cacheKey: SelectionCacheKey,
    initialValue: @autoclosure () -> Value,
    registration: ProjectionObserverRegistration<R.State>,
    valueResolver: @escaping @MainActor () -> Value?
  ) -> SelectedStore<Value> {
    if let cached: SelectedStore<Value> = selectionCache.cached(
      for: cacheKey, valueType: Value.self)
    {
      return cached
    }

    let selectedStore = SelectedStore(
      initialValue: initialValue(),
      parentObject: self,
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
    selectionCache.store(selectedStore, for: cacheKey, valueType: Value.self)
    registerProjectionObserver(selectedStore, registration: registration)
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
      initialValue: state[keyPath: keyPath],
      registration: selectionDependencyRegistrations(
        selectionDependencyRegistration(keyPath)
      ),
      valueResolver: { [weak self] in
        guard let self else { return nil }
        return self.state[keyPath: keyPath]
      }
    )
  }

  public func select<Dependency: Equatable & Sendable, Value: Equatable & Sendable>(
    dependingOn dependency: KeyPath<R.State, Dependency>,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    column: UInt = #column,
    _ transform: @escaping @Sendable (Dependency) -> Value
  ) -> SelectedStore<Value> {
    let callsite = selectionCallsite(fileID: fileID, line: line, column: column)
    return cachedSelectedStore(
      cacheKey: selectionCacheKey(
        callsite: callsite,
        dependencyKeyPaths: [dependency as AnyKeyPath]
      ),
      initialValue: transform(state[keyPath: dependency]),
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
      cacheKey: selectionCacheKey(
        callsite: callsite,
        dependencyKeyPaths: dependencyKeyPaths
      ),
      initialValue: transform(repeat state[keyPath: each dependencies]),
      registration: selectionDependencyRegistrations(fromArray: registrations),
      valueResolver: { [weak self] in
        guard let self else { return nil }
        return transform(repeat self.state[keyPath: each dependencies])
      }
    )
  }

  public func select<Value: Equatable & Sendable>(
    fileID: StaticString = #fileID,
    line: UInt = #line,
    column: UInt = #column,
    _ selector: @escaping @Sendable (R.State) -> Value
  ) -> SelectedStore<Value> {
    let callsite = selectionCallsite(fileID: fileID, line: line, column: column)
    return cachedSelectedStore(
      cacheKey: selectionCacheKey(callsite: callsite, signature: .closureSelector(memoized: false)),
      initialValue: selector(state),
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
      cacheKey: selectionCacheKey(
        callsite: callsite,
        signature: .closureSelector(memoized: memoize)
      ),
      initialValue: selector(state),
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
    cacheKey: SelectionCacheKey,
    initialValue: @autoclosure () -> Value,
    registration: ProjectionObserverRegistration<ChildState>,
    valueResolver: @escaping @MainActor () -> Value?
  ) -> SelectedStore<Value> {
    if let cached: SelectedStore<Value> = selectionCache.cached(
      for: cacheKey, valueType: Value.self)
    {
      return cached
    }

    let selectedStore = SelectedStore(
      initialValue: initialValue(),
      parentObject: self,
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
    selectionCache.store(selectedStore, for: cacheKey, valueType: Value.self)
    observerRegistry.register(selectedStore, registration: registration)
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
      initialValue: state[keyPath: keyPath],
      registration: selectionDependencyRegistrations(
        selectionDependencyRegistration(keyPath)
      ),
      valueResolver: { [weak self] in
        guard let self, self.isActive else { return nil }
        return self.cachedState[keyPath: keyPath]
      }
    )
  }

  public func select<Dependency: Equatable & Sendable, Value: Equatable & Sendable>(
    dependingOn dependency: KeyPath<ChildState, Dependency>,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    column: UInt = #column,
    _ transform: @escaping @Sendable (Dependency) -> Value
  ) -> SelectedStore<Value> {
    let callsite = scopedSelectionCallsite(fileID: fileID, line: line, column: column)
    return cachedSelectedStore(
      cacheKey: selectionCacheKey(
        callsite: callsite,
        dependencyKeyPaths: [dependency as AnyKeyPath]
      ),
      initialValue: transform(state[keyPath: dependency]),
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
      cacheKey: selectionCacheKey(
        callsite: callsite,
        dependencyKeyPaths: dependencyKeyPaths
      ),
      initialValue: transform(repeat state[keyPath: each dependencies]),
      registration: selectionDependencyRegistrations(fromArray: registrations),
      valueResolver: { [weak self] in
        guard let self, self.isActive else { return nil }
        return transform(repeat self.cachedState[keyPath: each dependencies])
      }
    )
  }

  public func select<Value: Equatable & Sendable>(
    fileID: StaticString = #fileID,
    line: UInt = #line,
    column: UInt = #column,
    _ selector: @escaping @Sendable (ChildState) -> Value
  ) -> SelectedStore<Value> {
    let callsite = scopedSelectionCallsite(fileID: fileID, line: line, column: column)
    return cachedSelectedStore(
      cacheKey: selectionCacheKey(callsite: callsite, signature: .closureSelector(memoized: false)),
      initialValue: selector(state),
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
      cacheKey: selectionCacheKey(
        callsite: callsite,
        signature: .closureSelector(memoized: memoize)
      ),
      initialValue: selector(state),
      registration: registration,
      valueResolver: { [weak self] in
        guard let self, self.isActive else { return nil }
        return selector(self.cachedState)
      }
    )
  }
}
