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
    guard parentObject != nil else {
      preconditionFailure(parentReleasedMessage())
    }
    guard isActive else {
      preconditionFailure(inactiveMessage())
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

extension Store {
  public func select<Value: Equatable & Sendable>(
    _ keyPath: KeyPath<R.State, Value>,
    fileID: StaticString = #fileID,
    line: UInt = #line
  ) -> SelectedStore<Value> {
    let callsite = selectionCallsite(fileID: fileID, line: line)
    if let cached: SelectedStore<Value> = selectionCache.cached(for: callsite, valueType: Value.self) {
      return cached
    }

    let selectedStore = SelectedStore(
      initialValue: state[keyPath: keyPath],
      parentObject: self,
      valueResolver: { [weak self] in
        guard let self else { return nil }
        return self.state[keyPath: keyPath]
      },
      inactiveMessage: {
        selectedStoreFailureMessage(
          parentType: R.self,
          valueType: Value.self,
          stableID: nil,
          reason: "the parent store was released"
        )
      },
      parentReleasedMessage: {
        selectedStoreFailureMessage(
          parentType: R.self,
          valueType: Value.self,
          stableID: nil,
          reason: "the parent store was released"
        )
      }
    )
    selectionCache.store(selectedStore, for: callsite, valueType: Value.self)
    registerProjectionObserver(
      selectedStore,
      registration: .dependency(
        .keyPath(keyPath as AnyKeyPath),
        hasChanged: { previousState, nextState in
          previousState[keyPath: keyPath] != nextState[keyPath: keyPath]
        }
      )
    )
    return selectedStore
  }

  public func select<Dependency: Equatable & Sendable, Value: Equatable & Sendable>(
    dependingOn dependency: KeyPath<R.State, Dependency>,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ transform: @escaping @Sendable (Dependency) -> Value
  ) -> SelectedStore<Value> {
    let callsite = selectionCallsite(fileID: fileID, line: line)
    if let cached: SelectedStore<Value> = selectionCache.cached(for: callsite, valueType: Value.self) {
      return cached
    }

    let selectedStore = SelectedStore(
      initialValue: transform(state[keyPath: dependency]),
      parentObject: self,
      valueResolver: { [weak self] in
        guard let self else { return nil }
        return transform(self.state[keyPath: dependency])
      },
      inactiveMessage: {
        selectedStoreFailureMessage(
          parentType: R.self,
          valueType: Value.self,
          stableID: nil,
          reason: "the parent store was released"
        )
      },
      parentReleasedMessage: {
        selectedStoreFailureMessage(
          parentType: R.self,
          valueType: Value.self,
          stableID: nil,
          reason: "the parent store was released"
        )
      }
    )
    selectionCache.store(selectedStore, for: callsite, valueType: Value.self)
    registerProjectionObserver(
      selectedStore,
      registration: .dependency(
        .keyPath(dependency as AnyKeyPath),
        hasChanged: { previousState, nextState in
          previousState[keyPath: dependency] != nextState[keyPath: dependency]
        }
      )
    )
    return selectedStore
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
    if let cached: SelectedStore<Value> = selectionCache.cached(for: callsite, valueType: Value.self) {
      return cached
    }

    let selectedStore = SelectedStore(
      initialValue: transform(state[keyPath: firstDependency], state[keyPath: secondDependency]),
      parentObject: self,
      valueResolver: { [weak self] in
        guard let self else { return nil }
        return transform(
          self.state[keyPath: firstDependency],
          self.state[keyPath: secondDependency]
        )
      },
      inactiveMessage: {
        selectedStoreFailureMessage(
          parentType: R.self,
          valueType: Value.self,
          stableID: nil,
          reason: "the parent store was released"
        )
      },
      parentReleasedMessage: {
        selectedStoreFailureMessage(
          parentType: R.self,
          valueType: Value.self,
          stableID: nil,
          reason: "the parent store was released"
        )
      }
    )
    selectionCache.store(selectedStore, for: callsite, valueType: Value.self)
    registerProjectionObserver(
      selectedStore,
      registration: .dependencies([
        .init(.keyPath(firstDependency as AnyKeyPath), hasChanged: { previousState, nextState in
          previousState[keyPath: firstDependency] != nextState[keyPath: firstDependency]
        }),
        .init(.keyPath(secondDependency as AnyKeyPath), hasChanged: { previousState, nextState in
          previousState[keyPath: secondDependency] != nextState[keyPath: secondDependency]
        }),
      ])
    )
    return selectedStore
  }

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
    if let cached: SelectedStore<Value> = selectionCache.cached(for: callsite, valueType: Value.self) {
      return cached
    }

    let selectedStore = SelectedStore(
      initialValue: transform(
        state[keyPath: firstDependency],
        state[keyPath: secondDependency],
        state[keyPath: thirdDependency]
      ),
      parentObject: self,
      valueResolver: { [weak self] in
        guard let self else { return nil }
        return transform(
          self.state[keyPath: firstDependency],
          self.state[keyPath: secondDependency],
          self.state[keyPath: thirdDependency]
        )
      },
      inactiveMessage: {
        selectedStoreFailureMessage(
          parentType: R.self,
          valueType: Value.self,
          stableID: nil,
          reason: "the parent store was released"
        )
      },
      parentReleasedMessage: {
        selectedStoreFailureMessage(
          parentType: R.self,
          valueType: Value.self,
          stableID: nil,
          reason: "the parent store was released"
        )
      }
    )
    selectionCache.store(selectedStore, for: callsite, valueType: Value.self)
    registerProjectionObserver(
      selectedStore,
      registration: .dependencies([
        .init(.keyPath(firstDependency as AnyKeyPath), hasChanged: { previousState, nextState in
          previousState[keyPath: firstDependency] != nextState[keyPath: firstDependency]
        }),
        .init(.keyPath(secondDependency as AnyKeyPath), hasChanged: { previousState, nextState in
          previousState[keyPath: secondDependency] != nextState[keyPath: secondDependency]
        }),
        .init(.keyPath(thirdDependency as AnyKeyPath), hasChanged: { previousState, nextState in
          previousState[keyPath: thirdDependency] != nextState[keyPath: thirdDependency]
        }),
      ])
    )
    return selectedStore
  }

  public func select<Value: Equatable & Sendable>(
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ selector: @escaping @Sendable (R.State) -> Value
  ) -> SelectedStore<Value> {
    let callsite = selectionCallsite(fileID: fileID, line: line)
    if let cached: SelectedStore<Value> = selectionCache.cached(for: callsite, valueType: Value.self) {
      return cached
    }

    let selectedStore = SelectedStore(
      initialValue: selector(state),
      parentObject: self,
      valueResolver: { [weak self] in
        guard let self else { return nil }
        return selector(self.state)
      },
      inactiveMessage: {
        selectedStoreFailureMessage(
          parentType: R.self,
          valueType: Value.self,
          stableID: nil,
          reason: "the parent store was released"
        )
      },
      parentReleasedMessage: {
        selectedStoreFailureMessage(
          parentType: R.self,
          valueType: Value.self,
          stableID: nil,
          reason: "the parent store was released"
        )
      }
    )
    selectionCache.store(selectedStore, for: callsite, valueType: Value.self)
    registerProjectionObserver(
      selectedStore,
      registration: .dependency(
        .custom(callsite),
        hasChanged: { _, _ in true }
      )
    )
    return selectedStore
  }
}

extension ScopedStore {
  public func select<Value: Equatable & Sendable>(
    _ keyPath: KeyPath<ChildState, Value>,
    fileID: StaticString = #fileID,
    line: UInt = #line
  ) -> SelectedStore<Value> {
    let callsite = SelectionCallsite(fileID: fileID.description, line: line)
    if let cached: SelectedStore<Value> = selectionCache.cached(for: callsite, valueType: Value.self) {
      return cached
    }

    let selectedStore = SelectedStore(
      initialValue: state[keyPath: keyPath],
      parentObject: self,
      valueResolver: { [weak self] in
        guard let self, self.isActive else { return nil }
        return self.cachedState[keyPath: keyPath]
      },
      inactiveMessage: { [weak self] in
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
      parentReleasedMessage: { [weak self] in
        selectedStoreFailureMessage(
          parentType: ParentReducer.self,
          valueType: Value.self,
          stableID: self?.stableID,
          reason: "the parent scoped store was released"
        )
      }
    )
    selectionCache.store(selectedStore, for: callsite, valueType: Value.self)
    observerRegistry.register(
      selectedStore,
      registration: .dependency(
        .keyPath(keyPath as AnyKeyPath),
        hasChanged: { previousState, nextState in
          previousState[keyPath: keyPath] != nextState[keyPath: keyPath]
        }
      )
    )
    return selectedStore
  }

  public func select<Dependency: Equatable & Sendable, Value: Equatable & Sendable>(
    dependingOn dependency: KeyPath<ChildState, Dependency>,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ transform: @escaping @Sendable (Dependency) -> Value
  ) -> SelectedStore<Value> {
    let callsite = SelectionCallsite(fileID: fileID.description, line: line)
    if let cached: SelectedStore<Value> = selectionCache.cached(for: callsite, valueType: Value.self) {
      return cached
    }

    let selectedStore = SelectedStore(
      initialValue: transform(state[keyPath: dependency]),
      parentObject: self,
      valueResolver: { [weak self] in
        guard let self, self.isActive else { return nil }
        return transform(self.cachedState[keyPath: dependency])
      },
      inactiveMessage: { [weak self] in
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
      parentReleasedMessage: { [weak self] in
        selectedStoreFailureMessage(
          parentType: ParentReducer.self,
          valueType: Value.self,
          stableID: self?.stableID,
          reason: "the parent scoped store was released"
        )
      }
    )
    selectionCache.store(selectedStore, for: callsite, valueType: Value.self)
    observerRegistry.register(
      selectedStore,
      registration: .dependency(
        .keyPath(dependency as AnyKeyPath),
        hasChanged: { previousState, nextState in
          previousState[keyPath: dependency] != nextState[keyPath: dependency]
        }
      )
    )
    return selectedStore
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
    if let cached: SelectedStore<Value> = selectionCache.cached(for: callsite, valueType: Value.self) {
      return cached
    }

    let selectedStore = SelectedStore(
      initialValue: transform(state[keyPath: firstDependency], state[keyPath: secondDependency]),
      parentObject: self,
      valueResolver: { [weak self] in
        guard let self, self.isActive else { return nil }
        return transform(
          self.cachedState[keyPath: firstDependency],
          self.cachedState[keyPath: secondDependency]
        )
      },
      inactiveMessage: { [weak self] in
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
      parentReleasedMessage: { [weak self] in
        selectedStoreFailureMessage(
          parentType: ParentReducer.self,
          valueType: Value.self,
          stableID: self?.stableID,
          reason: "the parent scoped store was released"
        )
      }
    )
    selectionCache.store(selectedStore, for: callsite, valueType: Value.self)
    observerRegistry.register(
      selectedStore,
      registration: .dependencies([
        .init(.keyPath(firstDependency as AnyKeyPath), hasChanged: { previousState, nextState in
          previousState[keyPath: firstDependency] != nextState[keyPath: firstDependency]
        }),
        .init(.keyPath(secondDependency as AnyKeyPath), hasChanged: { previousState, nextState in
          previousState[keyPath: secondDependency] != nextState[keyPath: secondDependency]
        }),
      ])
    )
    return selectedStore
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
    if let cached: SelectedStore<Value> = selectionCache.cached(for: callsite, valueType: Value.self) {
      return cached
    }

    let selectedStore = SelectedStore(
      initialValue: transform(
        state[keyPath: firstDependency],
        state[keyPath: secondDependency],
        state[keyPath: thirdDependency]
      ),
      parentObject: self,
      valueResolver: { [weak self] in
        guard let self, self.isActive else { return nil }
        return transform(
          self.cachedState[keyPath: firstDependency],
          self.cachedState[keyPath: secondDependency],
          self.cachedState[keyPath: thirdDependency]
        )
      },
      inactiveMessage: { [weak self] in
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
      parentReleasedMessage: { [weak self] in
        selectedStoreFailureMessage(
          parentType: ParentReducer.self,
          valueType: Value.self,
          stableID: self?.stableID,
          reason: "the parent scoped store was released"
        )
      }
    )
    selectionCache.store(selectedStore, for: callsite, valueType: Value.self)
    observerRegistry.register(
      selectedStore,
      registration: .dependencies([
        .init(.keyPath(firstDependency as AnyKeyPath), hasChanged: { previousState, nextState in
          previousState[keyPath: firstDependency] != nextState[keyPath: firstDependency]
        }),
        .init(.keyPath(secondDependency as AnyKeyPath), hasChanged: { previousState, nextState in
          previousState[keyPath: secondDependency] != nextState[keyPath: secondDependency]
        }),
        .init(.keyPath(thirdDependency as AnyKeyPath), hasChanged: { previousState, nextState in
          previousState[keyPath: thirdDependency] != nextState[keyPath: thirdDependency]
        }),
      ])
    )
    return selectedStore
  }

  public func select<Value: Equatable & Sendable>(
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ selector: @escaping @Sendable (ChildState) -> Value
  ) -> SelectedStore<Value> {
    let callsite = SelectionCallsite(fileID: fileID.description, line: line)
    if let cached: SelectedStore<Value> = selectionCache.cached(for: callsite, valueType: Value.self) {
      return cached
    }

    let selectedStore = SelectedStore(
      initialValue: selector(state),
      parentObject: self,
      valueResolver: { [weak self] in
        guard let self, self.isActive else { return nil }
        return selector(self.cachedState)
      },
      inactiveMessage: { [weak self] in
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
      parentReleasedMessage: { [weak self] in
        selectedStoreFailureMessage(
          parentType: ParentReducer.self,
          valueType: Value.self,
          stableID: self?.stableID,
          reason: "the parent scoped store was released"
        )
      }
    )
    selectionCache.store(selectedStore, for: callsite, valueType: Value.self)
    observerRegistry.register(
      selectedStore,
      registration: .dependency(
        .custom(callsite),
        hasChanged: { _, _ in true }
      )
    )
    return selectedStore
  }
}
