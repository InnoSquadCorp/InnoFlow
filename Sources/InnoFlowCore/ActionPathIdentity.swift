// MARK: - ActionPathIdentity.swift
// InnoFlow - Action Path Identity
// Copyright © 2025 InnoSquad. All rights reserved.

/// Opaque reference identity shared by value copies of an action path.
///
/// Runtime caches use this token to distinguish independently constructed
/// paths without comparing their embedding and extraction closures.
package final class ActionPathIdentity: Hashable, Sendable {
  package init() {}

  package static func == (lhs: ActionPathIdentity, rhs: ActionPathIdentity) -> Bool {
    lhs === rhs
  }

  package func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }
}
