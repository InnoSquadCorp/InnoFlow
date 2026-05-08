// MARK: - StoreActionQueue.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

package struct StoreQueuedAction<Action> {
  package let action: Action
  package let animation: EffectAnimation?
}

@MainActor
package final class StoreActionQueue<Action> {
  // Back-pressure policy: see docs/adr/ADR-store-action-queue-burst.md.
  // The queue intentionally has no drop / collapse / hard-cap policy because
  // those decisions are domain-shaped and belong in EffectTask.throttle,
  // EffectTask.debounce, or a collapsing reducer.
  private var buffered: [StoreQueuedAction<Action>] = []
  private var head = 0
  private var isDraining = false

  package init() {}

  package func enqueue(_ action: Action, animation: EffectAnimation?) {
    buffered.append(.init(action: action, animation: animation))
  }

  package func beginDrain() -> Bool {
    guard !isDraining else { return false }
    isDraining = true
    return true
  }

  package func next() -> StoreQueuedAction<Action>? {
    guard head < buffered.count else { return nil }
    let action = buffered[head]
    head += 1
    return action
  }

  package func finishDrain() {
    isDraining = false
    buffered.removeAll(keepingCapacity: true)
    head = 0
  }
}
