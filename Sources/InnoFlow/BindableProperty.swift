// MARK: - BindableProperty.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

/// A low-level storage type for state fields that intentionally support SwiftUI binding.
///
/// Public feature authoring must prefer `@BindableField` and pass `\.$field` into
/// `Store.binding(_:send:)`. Direct authoring such as `var step: BindableProperty<Int>`
/// in feature State is reported by the `@InnoFlow` macro as a warning with a Fix-It
/// that rewrites the declaration to `@BindableField var step: Int`. The type is
/// `public` only because it appears in the KeyPath signatures of public binding APIs;
/// it is not part of the user-authoring surface.
@dynamicMemberLookup
public struct BindableProperty<Value>: Equatable, Sendable where Value: Equatable & Sendable {
  public var value: Value

  public init(_ value: Value) {
    self.value = value
  }

  public init(wrappedValue: Value) {
    self.value = wrappedValue
  }

  public subscript<T>(dynamicMember keyPath: KeyPath<Value, T>) -> T {
    value[keyPath: keyPath]
  }
}

extension BindableProperty: CustomDebugStringConvertible {
  public var debugDescription: String {
    String(reflecting: value)
  }
}

extension BindableProperty: CustomReflectable {
  public var customMirror: Mirror {
    Mirror(reflecting: value)
  }
}

/// Conform state to this protocol when default initialization is desired.
public protocol DefaultInitializable {
  init()
}
