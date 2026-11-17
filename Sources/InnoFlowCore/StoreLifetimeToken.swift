// MARK: - StoreLifetimeToken.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import Observation
import Synchronization

/// The release state of one `Store`, shared with its projections and effects.
///
/// ``isReleased`` can be read from any executor and records no Observation
/// access. ``observedIsReleased`` is the store's observable liveness: a
/// projection reads it to observe its owner, and ``markReleased()`` notifies
/// those readers. `Store.deinit` calls it in the turn that deactivates the
/// store's projections, so a reader of the owner's liveness is notified even
/// when the projection it read through no longer exists.
package final class StoreLifetimeToken: Sendable, Observable {
  private let released = Mutex(false)
  private let registrar = ObservationRegistrar()

  package init() {}

  package func markReleased() {
    registrar.withMutation(of: self, keyPath: \.observedIsReleased) {
      released.withLock { $0 = true }
    }
  }

  package var isReleased: Bool {
    released.withLock { $0 }
  }

  /// ``isReleased``, recording an Observation access that ``markReleased()``
  /// invalidates.
  package var observedIsReleased: Bool {
    registrar.access(self, keyPath: \.observedIsReleased)
    return isReleased
  }
}
