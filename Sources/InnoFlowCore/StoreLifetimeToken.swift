// MARK: - StoreLifetimeToken.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import Synchronization

package final class StoreLifetimeToken: Sendable {
  private let released = Mutex(false)

  package init() {}

  package func markReleased() {
    released.withLock { $0 = true }
  }

  package var isReleased: Bool {
    released.withLock { $0 }
  }
}
