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

  public var value: Value {
    // Lifecycle race: a SwiftUI observer may read this projection on the same
    // tick that its parent store is released. Rather than aborting the
    // process in release builds, return the last valid cached projection —
    // the observer refresh pass will invalidate dependents within the next
    // tick. Debug builds surface the race via `assertionFailure`.
    //
    // See ARCHITECTURE_CONTRACT.md — "Projection lifecycle contract".
    guard parentObject != nil else {
      assertionFailure(parentReleasedMessage())
      return cachedValue
    }
    guard isActive else {
      assertionFailure(inactiveMessage())
      return cachedValue
    }
    return cachedValue
  }

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
  /// `value` keeps the existing cached-read contract for SwiftUI observer
  /// races. `optionalValue` is the explicit form: callers that need to
  /// distinguish "value is fresh" from "parent is gone" without hitting a
  /// debug assertion or a release-time stale read should consult this
  /// property and treat `nil` as "regenerate the selection."
  public var optionalValue: Value? {
    guard isAlive else { return nil }
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
    value[keyPath: keyPath]
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

extension Store {
  private func cachedSelectedStore<Value: Equatable & Sendable>(
    callsite: SelectionCallsite,
    initialValue: @autoclosure () -> Value,
    registration: ProjectionObserverRegistration<R.State>,
    valueResolver: @escaping @MainActor () -> Value?
  ) -> SelectedStore<Value> {
    if let cached: SelectedStore<Value> = selectionCache.cached(
      for: callsite, valueType: Value.self)
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
    selectionCache.store(selectedStore, for: callsite, valueType: Value.self)
    registerProjectionObserver(selectedStore, registration: registration)
    return selectedStore
  }

  public func select<Value: Equatable & Sendable>(
    _ keyPath: KeyPath<R.State, Value>,
    fileID: StaticString = #fileID,
    line: UInt = #line
  ) -> SelectedStore<Value> {
    let callsite = selectionCallsite(fileID: fileID, line: line)
    return cachedSelectedStore(
      callsite: callsite,
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
    _ transform: @escaping @Sendable (Dependency) -> Value
  ) -> SelectedStore<Value> {
    let callsite = selectionCallsite(fileID: fileID, line: line)
    return cachedSelectedStore(
      callsite: callsite,
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

  public func select<
    FirstDependency: Equatable & Sendable,
    SecondDependency: Equatable & Sendable,
    Value: Equatable & Sendable
  >(
    dependingOn dependencies: (
      KeyPath<R.State, FirstDependency>,
      KeyPath<R.State, SecondDependency>
    ),
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ transform: @escaping @Sendable (FirstDependency, SecondDependency) -> Value
  ) -> SelectedStore<Value> {
    let (firstDependency, secondDependency) = dependencies
    let callsite = selectionCallsite(fileID: fileID, line: line)
    return cachedSelectedStore(
      callsite: callsite,
      initialValue: transform(state[keyPath: firstDependency], state[keyPath: secondDependency]),
      registration: selectionDependencyRegistrations(
        selectionDependencyRegistration(firstDependency),
        selectionDependencyRegistration(secondDependency)
      ),
      valueResolver: { [weak self] in
        guard let self else { return nil }
        return transform(
          self.state[keyPath: firstDependency],
          self.state[keyPath: secondDependency]
        )
      }
    )
  }

  /// Creates or reuses a selected store derived from three equatable dependency slices.
  ///
  /// The dependency tuple is registered for selective invalidation, so the selected
  /// store refreshes only when one of the supplied slices changes.
  ///
  /// - Parameters:
  ///   - dependencies: Three equatable state slices tracked for invalidation.
  ///   - fileID: Callsite metadata used to preserve stable selection caching.
  ///   - line: Callsite metadata used to preserve stable selection caching.
  ///   - transform: Maps the tracked dependency values into the selected output.
  /// - Returns: A cached `SelectedStore` derived from the supplied dependencies.
  public func select<
    FirstDependency: Equatable & Sendable,
    SecondDependency: Equatable & Sendable,
    ThirdDependency: Equatable & Sendable,
    Value: Equatable & Sendable
  >(
    dependingOn dependencies: (
      KeyPath<R.State, FirstDependency>,
      KeyPath<R.State, SecondDependency>,
      KeyPath<R.State, ThirdDependency>
    ),
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ transform: @escaping @Sendable (FirstDependency, SecondDependency, ThirdDependency) -> Value
  ) -> SelectedStore<Value> {
    let (firstDependency, secondDependency, thirdDependency) = dependencies
    let callsite = selectionCallsite(fileID: fileID, line: line)
    return cachedSelectedStore(
      callsite: callsite,
      initialValue: transform(
        state[keyPath: firstDependency],
        state[keyPath: secondDependency],
        state[keyPath: thirdDependency]
      ),
      registration: selectionDependencyRegistrations(
        selectionDependencyRegistration(firstDependency),
        selectionDependencyRegistration(secondDependency),
        selectionDependencyRegistration(thirdDependency)
      ),
      valueResolver: { [weak self] in
        guard let self else { return nil }
        return transform(
          self.state[keyPath: firstDependency],
          self.state[keyPath: secondDependency],
          self.state[keyPath: thirdDependency]
        )
      }
    )
  }

  /// Creates or reuses a selected store derived from four equatable dependency slices.
  ///
  /// The dependency tuple is registered for selective invalidation, so the selected
  /// store refreshes only when one of the supplied slices changes.
  ///
  /// - Parameters:
  ///   - dependencies: Four equatable state slices tracked for invalidation.
  ///   - fileID: Callsite metadata used to preserve stable selection caching.
  ///   - line: Callsite metadata used to preserve stable selection caching.
  ///   - transform: Maps the tracked dependency values into the selected output.
  /// - Returns: A cached `SelectedStore` derived from the supplied dependencies.
  public func select<
    FirstDependency: Equatable & Sendable,
    SecondDependency: Equatable & Sendable,
    ThirdDependency: Equatable & Sendable,
    FourthDependency: Equatable & Sendable,
    Value: Equatable & Sendable
  >(
    dependingOn dependencies: (
      KeyPath<R.State, FirstDependency>,
      KeyPath<R.State, SecondDependency>,
      KeyPath<R.State, ThirdDependency>,
      KeyPath<R.State, FourthDependency>
    ),
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ transform:
      @escaping @Sendable (
        FirstDependency,
        SecondDependency,
        ThirdDependency,
        FourthDependency
      ) -> Value
  ) -> SelectedStore<Value> {
    let (firstDependency, secondDependency, thirdDependency, fourthDependency) = dependencies
    let callsite = selectionCallsite(fileID: fileID, line: line)
    return cachedSelectedStore(
      callsite: callsite,
      initialValue: transform(
        state[keyPath: firstDependency],
        state[keyPath: secondDependency],
        state[keyPath: thirdDependency],
        state[keyPath: fourthDependency]
      ),
      registration: selectionDependencyRegistrations(
        selectionDependencyRegistration(firstDependency),
        selectionDependencyRegistration(secondDependency),
        selectionDependencyRegistration(thirdDependency),
        selectionDependencyRegistration(fourthDependency)
      ),
      valueResolver: { [weak self] in
        guard let self else { return nil }
        return transform(
          self.state[keyPath: firstDependency],
          self.state[keyPath: secondDependency],
          self.state[keyPath: thirdDependency],
          self.state[keyPath: fourthDependency]
        )
      }
    )
  }

  /// Creates or reuses a selected store derived from five equatable dependency slices.
  ///
  /// The dependency tuple is registered for selective invalidation, so the selected
  /// store refreshes only when one of the supplied slices changes.
  ///
  /// - Parameters:
  ///   - dependencies: Five equatable state slices tracked for invalidation.
  ///   - fileID: Callsite metadata used to preserve stable selection caching.
  ///   - line: Callsite metadata used to preserve stable selection caching.
  ///   - transform: Maps the tracked dependency values into the selected output.
  /// - Returns: A cached `SelectedStore` derived from the supplied dependencies.
  public func select<
    FirstDependency: Equatable & Sendable,
    SecondDependency: Equatable & Sendable,
    ThirdDependency: Equatable & Sendable,
    FourthDependency: Equatable & Sendable,
    FifthDependency: Equatable & Sendable,
    Value: Equatable & Sendable
  >(
    dependingOn dependencies: (
      KeyPath<R.State, FirstDependency>,
      KeyPath<R.State, SecondDependency>,
      KeyPath<R.State, ThirdDependency>,
      KeyPath<R.State, FourthDependency>,
      KeyPath<R.State, FifthDependency>
    ),
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ transform:
      @escaping @Sendable (
        FirstDependency,
        SecondDependency,
        ThirdDependency,
        FourthDependency,
        FifthDependency
      ) -> Value
  ) -> SelectedStore<Value> {
    let (firstDependency, secondDependency, thirdDependency, fourthDependency, fifthDependency) =
      dependencies
    let callsite = selectionCallsite(fileID: fileID, line: line)
    return cachedSelectedStore(
      callsite: callsite,
      initialValue: transform(
        state[keyPath: firstDependency],
        state[keyPath: secondDependency],
        state[keyPath: thirdDependency],
        state[keyPath: fourthDependency],
        state[keyPath: fifthDependency]
      ),
      registration: selectionDependencyRegistrations(
        selectionDependencyRegistration(firstDependency),
        selectionDependencyRegistration(secondDependency),
        selectionDependencyRegistration(thirdDependency),
        selectionDependencyRegistration(fourthDependency),
        selectionDependencyRegistration(fifthDependency)
      ),
      valueResolver: { [weak self] in
        guard let self else { return nil }
        return transform(
          self.state[keyPath: firstDependency],
          self.state[keyPath: secondDependency],
          self.state[keyPath: thirdDependency],
          self.state[keyPath: fourthDependency],
          self.state[keyPath: fifthDependency]
        )
      }
    )
  }

  /// Creates or reuses a selected store derived from six equatable dependency slices.
  ///
  /// The dependency tuple is registered for selective invalidation, so the selected
  /// store refreshes only when one of the supplied slices changes.
  ///
  /// - Parameters:
  ///   - dependencies: Six equatable state slices tracked for invalidation.
  ///   - fileID: Callsite metadata used to preserve stable selection caching.
  ///   - line: Callsite metadata used to preserve stable selection caching.
  ///   - transform: Maps the tracked dependency values into the selected output.
  /// - Returns: A cached `SelectedStore` derived from the supplied dependencies.
  public func select<
    FirstDependency: Equatable & Sendable,
    SecondDependency: Equatable & Sendable,
    ThirdDependency: Equatable & Sendable,
    FourthDependency: Equatable & Sendable,
    FifthDependency: Equatable & Sendable,
    SixthDependency: Equatable & Sendable,
    Value: Equatable & Sendable
  >(
    dependingOn dependencies: (
      KeyPath<R.State, FirstDependency>,
      KeyPath<R.State, SecondDependency>,
      KeyPath<R.State, ThirdDependency>,
      KeyPath<R.State, FourthDependency>,
      KeyPath<R.State, FifthDependency>,
      KeyPath<R.State, SixthDependency>
    ),
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ transform:
      @escaping @Sendable (
        FirstDependency,
        SecondDependency,
        ThirdDependency,
        FourthDependency,
        FifthDependency,
        SixthDependency
      ) -> Value
  ) -> SelectedStore<Value> {
    let (
      firstDependency,
      secondDependency,
      thirdDependency,
      fourthDependency,
      fifthDependency,
      sixthDependency
    ) = dependencies
    let callsite = selectionCallsite(fileID: fileID, line: line)
    return cachedSelectedStore(
      callsite: callsite,
      initialValue: transform(
        state[keyPath: firstDependency],
        state[keyPath: secondDependency],
        state[keyPath: thirdDependency],
        state[keyPath: fourthDependency],
        state[keyPath: fifthDependency],
        state[keyPath: sixthDependency]
      ),
      registration: selectionDependencyRegistrations(
        selectionDependencyRegistration(firstDependency),
        selectionDependencyRegistration(secondDependency),
        selectionDependencyRegistration(thirdDependency),
        selectionDependencyRegistration(fourthDependency),
        selectionDependencyRegistration(fifthDependency),
        selectionDependencyRegistration(sixthDependency)
      ),
      valueResolver: { [weak self] in
        guard let self else { return nil }
        return transform(
          self.state[keyPath: firstDependency],
          self.state[keyPath: secondDependency],
          self.state[keyPath: thirdDependency],
          self.state[keyPath: fourthDependency],
          self.state[keyPath: fifthDependency],
          self.state[keyPath: sixthDependency]
        )
      }
    )
  }

  /// Variadic selection: declares an arbitrary number of explicit
  /// dependency key paths through Swift parameter packs and projects them
  /// into a derived value.
  ///
  /// The fixed-arity `select(dependingOn:)` overloads (1- through 6-field)
  /// remain the recommended form for the common cases; this overload is
  /// the type-safe escape hatch for projections that legitimately depend
  /// on more than six fields, where the closure-only `select(_:)` form
  /// would otherwise force `.alwaysRefresh` and re-evaluate on every
  /// parent action.
  ///
  /// Use a distinct `dependingOnAll:` argument label rather than overloading
  /// the existing `dependingOn:` to keep the fixed-arity tuple overloads
  /// unambiguous at call sites where one through six dependencies are
  /// passed as a tuple literal.
  public func select<each Dep: Equatable & Sendable, Value: Equatable & Sendable>(
    dependingOnAll dependencies: repeat KeyPath<R.State, each Dep>,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ transform: @escaping @Sendable (repeat each Dep) -> Value
  ) -> SelectedStore<Value> {
    let callsite = selectionCallsite(fileID: fileID, line: line)

    let initial = transform(repeat state[keyPath: each dependencies])

    var registrations: [ProjectionDependencyRegistration<R.State>] = []
    for keyPath in repeat each dependencies {
      registrations.append(selectionDependencyRegistration(keyPath))
    }

    return cachedSelectedStore(
      callsite: callsite,
      initialValue: initial,
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
    _ selector: @escaping @Sendable (R.State) -> Value
  ) -> SelectedStore<Value> {
    let callsite = selectionCallsite(fileID: fileID, line: line)
    return cachedSelectedStore(
      callsite: callsite,
      initialValue: selector(state),
      registration: alwaysRefreshSelectionRegistration(callsite: callsite),
      valueResolver: { [weak self] in
        guard let self else { return nil }
        return selector(self.state)
      }
    )
  }
}

extension ScopedStore {
  private func cachedSelectedStore<Value: Equatable & Sendable>(
    callsite: SelectionCallsite,
    initialValue: @autoclosure () -> Value,
    registration: ProjectionObserverRegistration<ChildState>,
    valueResolver: @escaping @MainActor () -> Value?
  ) -> SelectedStore<Value> {
    if let cached: SelectedStore<Value> = selectionCache.cached(
      for: callsite, valueType: Value.self)
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
    selectionCache.store(selectedStore, for: callsite, valueType: Value.self)
    observerRegistry.register(selectedStore, registration: registration)
    return selectedStore
  }

  public func select<Value: Equatable & Sendable>(
    _ keyPath: KeyPath<ChildState, Value>,
    fileID: StaticString = #fileID,
    line: UInt = #line
  ) -> SelectedStore<Value> {
    let callsite = SelectionCallsite(fileID: fileID.description, line: line)
    return cachedSelectedStore(
      callsite: callsite,
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
    _ transform: @escaping @Sendable (Dependency) -> Value
  ) -> SelectedStore<Value> {
    let callsite = SelectionCallsite(fileID: fileID.description, line: line)
    return cachedSelectedStore(
      callsite: callsite,
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

  public func select<
    FirstDependency: Equatable & Sendable,
    SecondDependency: Equatable & Sendable,
    Value: Equatable & Sendable
  >(
    dependingOn dependencies: (
      KeyPath<ChildState, FirstDependency>,
      KeyPath<ChildState, SecondDependency>
    ),
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ transform: @escaping @Sendable (FirstDependency, SecondDependency) -> Value
  ) -> SelectedStore<Value> {
    let (firstDependency, secondDependency) = dependencies
    let callsite = SelectionCallsite(fileID: fileID.description, line: line)
    return cachedSelectedStore(
      callsite: callsite,
      initialValue: transform(state[keyPath: firstDependency], state[keyPath: secondDependency]),
      registration: selectionDependencyRegistrations(
        selectionDependencyRegistration(firstDependency),
        selectionDependencyRegistration(secondDependency)
      ),
      valueResolver: { [weak self] in
        guard let self, self.isActive else { return nil }
        return transform(
          self.cachedState[keyPath: firstDependency],
          self.cachedState[keyPath: secondDependency]
        )
      }
    )
  }

  public func select<
    FirstDependency: Equatable & Sendable,
    SecondDependency: Equatable & Sendable,
    ThirdDependency: Equatable & Sendable,
    Value: Equatable & Sendable
  >(
    dependingOn dependencies: (
      KeyPath<ChildState, FirstDependency>,
      KeyPath<ChildState, SecondDependency>,
      KeyPath<ChildState, ThirdDependency>
    ),
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ transform: @escaping @Sendable (FirstDependency, SecondDependency, ThirdDependency) -> Value
  ) -> SelectedStore<Value> {
    let (firstDependency, secondDependency, thirdDependency) = dependencies
    let callsite = SelectionCallsite(fileID: fileID.description, line: line)
    return cachedSelectedStore(
      callsite: callsite,
      initialValue: transform(
        state[keyPath: firstDependency],
        state[keyPath: secondDependency],
        state[keyPath: thirdDependency]
      ),
      registration: selectionDependencyRegistrations(
        selectionDependencyRegistration(firstDependency),
        selectionDependencyRegistration(secondDependency),
        selectionDependencyRegistration(thirdDependency)
      ),
      valueResolver: { [weak self] in
        guard let self, self.isActive else { return nil }
        return transform(
          self.cachedState[keyPath: firstDependency],
          self.cachedState[keyPath: secondDependency],
          self.cachedState[keyPath: thirdDependency]
        )
      }
    )
  }

  /// Creates or reuses a selected store derived from four equatable child-state slices.
  ///
  /// The dependency tuple is registered for selective invalidation, so the selected
  /// store refreshes only when one of the supplied slices changes.
  ///
  /// - Parameters:
  ///   - dependencies: Four equatable child-state slices tracked for invalidation.
  ///   - fileID: Callsite metadata used to preserve stable selection caching.
  ///   - line: Callsite metadata used to preserve stable selection caching.
  ///   - transform: Maps the tracked dependency values into the selected output.
  /// - Returns: A cached `SelectedStore` derived from the supplied dependencies.
  public func select<
    FirstDependency: Equatable & Sendable,
    SecondDependency: Equatable & Sendable,
    ThirdDependency: Equatable & Sendable,
    FourthDependency: Equatable & Sendable,
    Value: Equatable & Sendable
  >(
    dependingOn dependencies: (
      KeyPath<ChildState, FirstDependency>,
      KeyPath<ChildState, SecondDependency>,
      KeyPath<ChildState, ThirdDependency>,
      KeyPath<ChildState, FourthDependency>
    ),
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ transform:
      @escaping @Sendable (
        FirstDependency,
        SecondDependency,
        ThirdDependency,
        FourthDependency
      ) -> Value
  ) -> SelectedStore<Value> {
    let (firstDependency, secondDependency, thirdDependency, fourthDependency) = dependencies
    let callsite = SelectionCallsite(fileID: fileID.description, line: line)
    return cachedSelectedStore(
      callsite: callsite,
      initialValue: transform(
        state[keyPath: firstDependency],
        state[keyPath: secondDependency],
        state[keyPath: thirdDependency],
        state[keyPath: fourthDependency]
      ),
      registration: selectionDependencyRegistrations(
        selectionDependencyRegistration(firstDependency),
        selectionDependencyRegistration(secondDependency),
        selectionDependencyRegistration(thirdDependency),
        selectionDependencyRegistration(fourthDependency)
      ),
      valueResolver: { [weak self] in
        guard let self, self.isActive else { return nil }
        return transform(
          self.cachedState[keyPath: firstDependency],
          self.cachedState[keyPath: secondDependency],
          self.cachedState[keyPath: thirdDependency],
          self.cachedState[keyPath: fourthDependency]
        )
      }
    )
  }

  /// Creates or reuses a selected store derived from five equatable child-state slices.
  ///
  /// The dependency tuple is registered for selective invalidation, so the selected
  /// store refreshes only when one of the supplied slices changes.
  ///
  /// - Parameters:
  ///   - dependencies: Five equatable child-state slices tracked for invalidation.
  ///   - fileID: Callsite metadata used to preserve stable selection caching.
  ///   - line: Callsite metadata used to preserve stable selection caching.
  ///   - transform: Maps the tracked dependency values into the selected output.
  /// - Returns: A cached `SelectedStore` derived from the supplied dependencies.
  public func select<
    FirstDependency: Equatable & Sendable,
    SecondDependency: Equatable & Sendable,
    ThirdDependency: Equatable & Sendable,
    FourthDependency: Equatable & Sendable,
    FifthDependency: Equatable & Sendable,
    Value: Equatable & Sendable
  >(
    dependingOn dependencies: (
      KeyPath<ChildState, FirstDependency>,
      KeyPath<ChildState, SecondDependency>,
      KeyPath<ChildState, ThirdDependency>,
      KeyPath<ChildState, FourthDependency>,
      KeyPath<ChildState, FifthDependency>
    ),
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ transform:
      @escaping @Sendable (
        FirstDependency,
        SecondDependency,
        ThirdDependency,
        FourthDependency,
        FifthDependency
      ) -> Value
  ) -> SelectedStore<Value> {
    let (firstDependency, secondDependency, thirdDependency, fourthDependency, fifthDependency) =
      dependencies
    let callsite = SelectionCallsite(fileID: fileID.description, line: line)
    return cachedSelectedStore(
      callsite: callsite,
      initialValue: transform(
        state[keyPath: firstDependency],
        state[keyPath: secondDependency],
        state[keyPath: thirdDependency],
        state[keyPath: fourthDependency],
        state[keyPath: fifthDependency]
      ),
      registration: selectionDependencyRegistrations(
        selectionDependencyRegistration(firstDependency),
        selectionDependencyRegistration(secondDependency),
        selectionDependencyRegistration(thirdDependency),
        selectionDependencyRegistration(fourthDependency),
        selectionDependencyRegistration(fifthDependency)
      ),
      valueResolver: { [weak self] in
        guard let self, self.isActive else { return nil }
        return transform(
          self.cachedState[keyPath: firstDependency],
          self.cachedState[keyPath: secondDependency],
          self.cachedState[keyPath: thirdDependency],
          self.cachedState[keyPath: fourthDependency],
          self.cachedState[keyPath: fifthDependency]
        )
      }
    )
  }

  /// Creates or reuses a selected store derived from six equatable child-state slices.
  ///
  /// The dependency tuple is registered for selective invalidation, so the selected
  /// store refreshes only when one of the supplied slices changes.
  ///
  /// - Parameters:
  ///   - dependencies: Six equatable child-state slices tracked for invalidation.
  ///   - fileID: Callsite metadata used to preserve stable selection caching.
  ///   - line: Callsite metadata used to preserve stable selection caching.
  ///   - transform: Maps the tracked dependency values into the selected output.
  /// - Returns: A cached `SelectedStore` derived from the supplied dependencies.
  public func select<
    FirstDependency: Equatable & Sendable,
    SecondDependency: Equatable & Sendable,
    ThirdDependency: Equatable & Sendable,
    FourthDependency: Equatable & Sendable,
    FifthDependency: Equatable & Sendable,
    SixthDependency: Equatable & Sendable,
    Value: Equatable & Sendable
  >(
    dependingOn dependencies: (
      KeyPath<ChildState, FirstDependency>,
      KeyPath<ChildState, SecondDependency>,
      KeyPath<ChildState, ThirdDependency>,
      KeyPath<ChildState, FourthDependency>,
      KeyPath<ChildState, FifthDependency>,
      KeyPath<ChildState, SixthDependency>
    ),
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ transform:
      @escaping @Sendable (
        FirstDependency,
        SecondDependency,
        ThirdDependency,
        FourthDependency,
        FifthDependency,
        SixthDependency
      ) -> Value
  ) -> SelectedStore<Value> {
    let (
      firstDependency,
      secondDependency,
      thirdDependency,
      fourthDependency,
      fifthDependency,
      sixthDependency
    ) = dependencies
    let callsite = SelectionCallsite(fileID: fileID.description, line: line)
    return cachedSelectedStore(
      callsite: callsite,
      initialValue: transform(
        state[keyPath: firstDependency],
        state[keyPath: secondDependency],
        state[keyPath: thirdDependency],
        state[keyPath: fourthDependency],
        state[keyPath: fifthDependency],
        state[keyPath: sixthDependency]
      ),
      registration: selectionDependencyRegistrations(
        selectionDependencyRegistration(firstDependency),
        selectionDependencyRegistration(secondDependency),
        selectionDependencyRegistration(thirdDependency),
        selectionDependencyRegistration(fourthDependency),
        selectionDependencyRegistration(fifthDependency),
        selectionDependencyRegistration(sixthDependency)
      ),
      valueResolver: { [weak self] in
        guard let self, self.isActive else { return nil }
        return transform(
          self.cachedState[keyPath: firstDependency],
          self.cachedState[keyPath: secondDependency],
          self.cachedState[keyPath: thirdDependency],
          self.cachedState[keyPath: fourthDependency],
          self.cachedState[keyPath: fifthDependency],
          self.cachedState[keyPath: sixthDependency]
        )
      }
    )
  }

  public func select<Value: Equatable & Sendable>(
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ selector: @escaping @Sendable (ChildState) -> Value
  ) -> SelectedStore<Value> {
    let callsite = SelectionCallsite(fileID: fileID.description, line: line)
    return cachedSelectedStore(
      callsite: callsite,
      initialValue: selector(state),
      registration: alwaysRefreshSelectionRegistration(callsite: callsite),
      valueResolver: { [weak self] in
        guard let self, self.isActive else { return nil }
        return selector(self.cachedState)
      }
    )
  }
}
