// MARK: - ActionPathIdentity.swift
// InnoFlow - Action Path Identity
// Copyright © 2025 InnoSquad. All rights reserved.

/// Opaque reference identity shared by value copies of an action path.
///
/// Runtime caches use this token to distinguish independently constructed
/// paths without comparing their embedding and extraction closures.
package final class ActionPathIdentity: Sendable {
  package init() {}
}
