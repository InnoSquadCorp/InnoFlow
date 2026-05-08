// MARK: - BindableField.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

/// A wrapper for state fields that are intentionally bindable from SwiftUI.
///
/// `@BindableField` keeps reducer-facing state ergonomic (`state.step = 2`) while
/// projecting a low-level ``BindableProperty`` for ``Store/binding(_:send:)``.
@propertyWrapper
@dynamicMemberLookup
public struct BindableField<Value>: Equatable, Sendable where Value: Equatable & Sendable {
  private var storage: BindableProperty<Value>

  public init(wrappedValue: Value) {
    storage = BindableProperty(wrappedValue)
  }

  public var wrappedValue: Value {
    get { storage.value }
    set { storage.value = newValue }
  }

  public var projectedValue: BindableProperty<Value> {
    storage
  }

  public subscript<T>(dynamicMember keyPath: KeyPath<Value, T>) -> T {
    storage[dynamicMember: keyPath]
  }
}
