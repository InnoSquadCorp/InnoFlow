// MARK: - EffectCancellationScope.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import os

package struct EffectCancellationScopeMetrics: Sendable, Equatable {
  package let liveScopes: Int
  package let liveInterpreters: Int
  package let retainedPotentialIDs: Int
  package let pendingCancellationIDs: Int
  package let liveExactTokens: Int

  package init(
    liveScopes: Int,
    liveInterpreters: Int,
    retainedPotentialIDs: Int,
    pendingCancellationIDs: Int,
    liveExactTokens: Int
  ) {
    self.liveScopes = liveScopes
    self.liveInterpreters = liveInterpreters
    self.retainedPotentialIDs = retainedPotentialIDs
    self.pendingCancellationIDs = pendingCancellationIDs
    self.liveExactTokens = liveExactTokens
  }
}

/// A cancellation token retained only by work that is actually owned by an ID.
///
/// The token keeps late emissions suppressed after the interpreter that created
/// the work has unwound. Its registration in the sequence scope is weak, so a
/// completed dynamic ID does not become Store-lifetime history.
package final class EffectCancellationToken: Sendable {
  package let id: AnyEffectID

  private let registrationID: UUID
  private let scope: EffectCancellationScope
  private let cancelled = OSAllocatedUnfairLock(initialState: false)

  fileprivate init(
    id: AnyEffectID,
    registrationID: UUID,
    scope: EffectCancellationScope,
    initiallyCancelled: Bool
  ) {
    self.id = id
    self.registrationID = registrationID
    self.scope = scope
    self.cancelled.withLock { $0 = initiallyCancelled }
  }

  package var isCancelled: Bool {
    cancelled.withLock { $0 }
  }

  fileprivate func cancel() {
    cancelled.withLock { $0 = true }
  }

  deinit {
    scope.removeToken(id: id, registrationID: registrationID)
  }
}

/// Shared ownership proving that an effect tree may still discover new IDs.
///
/// Copies of an interpreter context share this reference. The pending-ID
/// journal is released only after the final structural continuation unwinds.
package final class EffectInterpreterLease: Sendable {
  private let scope: EffectCancellationScope

  fileprivate init(scope: EffectCancellationScope) {
    self.scope = scope
    scope.beginInterpreter()
  }

  deinit {
    scope.endInterpreter()
  }
}

/// Cancellation state for one issued Store/TestStore effect sequence.
///
/// A scope keeps only live exact-ID tokens plus IDs that a still-active
/// interpreter may discover later (for example through a concatenate sibling
/// or lazy map). Once interpretation ends, unrelated long-running work retains
/// no historical dynamic IDs.
package final class EffectCancellationScope: Sendable {
  private struct WeakToken {
    weak var value: EffectCancellationToken?
    let registrationID: UUID
  }

  private struct State {
    var isGloballyCancelled = false
    var interpreterCount = 0
    var potentialCancellationIDs: Set<AnyEffectID>
    var pendingCancellationIDs: Set<AnyEffectID> = []
    var tokensByID: [AnyEffectID: WeakToken] = [:]

    init(potentialCancellationIDs: Set<AnyEffectID>) {
      self.potentialCancellationIDs = potentialCancellationIDs
    }
  }

  package let sequence: UInt64

  private let registrationID: UUID
  private let registry: EffectCancellationScopeRegistry
  private let state: OSAllocatedUnfairLock<State>

  fileprivate init(
    sequence: UInt64,
    potentialCancellationIDs: Set<AnyEffectID>,
    registrationID: UUID,
    registry: EffectCancellationScopeRegistry
  ) {
    self.sequence = sequence
    self.registrationID = registrationID
    self.registry = registry
    self.state = OSAllocatedUnfairLock(
      initialState: State(potentialCancellationIDs: potentialCancellationIDs)
    )
  }

  package func makeInterpreterLease() -> EffectInterpreterLease {
    EffectInterpreterLease(scope: self)
  }

  package func token(for id: AnyEffectID) -> EffectCancellationToken {
    state.withLock { state in
      precondition(
        state.potentialCancellationIDs.contains(id),
        "Cancellation ID was not declared by the effect tree preflight"
      )
      removeReleasedTokens(from: &state)
      if let token = state.tokensByID[id]?.value {
        return token
      }

      let tokenRegistrationID = UUID()
      let token = EffectCancellationToken(
        id: id,
        registrationID: tokenRegistrationID,
        scope: self,
        initiallyCancelled: state.isGloballyCancelled
          || state.pendingCancellationIDs.contains(id)
      )
      state.tokensByID[id] = .init(
        value: token,
        registrationID: tokenRegistrationID
      )
      return token
    }
  }

  package var isGloballyCancelled: Bool {
    state.withLock { $0.isGloballyCancelled }
  }

  package func isCancelled(id: AnyEffectID) -> Bool {
    state.withLock { state in
      removeReleasedTokens(from: &state)
      if state.isGloballyCancelled || state.pendingCancellationIDs.contains(id) {
        return true
      }
      return state.tokensByID[id]?.value?.isCancelled == true
    }
  }

  package var retainedCancellationIDCount: Int {
    state.withLock { state in
      removeReleasedTokens(from: &state)
      return state.pendingCancellationIDs.count
    }
  }

  package var retainedPotentialIDCount: Int {
    state.withLock { $0.potentialCancellationIDs.count }
  }

  package var liveExactTokenCount: Int {
    state.withLock { state in
      removeReleasedTokens(from: &state)
      return state.tokensByID.count
    }
  }

  package var liveInterpreterCount: Int {
    state.withLock { $0.interpreterCount }
  }

  fileprivate func cancel(id: AnyEffectID) {
    let token = state.withLock { state -> EffectCancellationToken? in
      removeReleasedTokens(from: &state)
      if state.interpreterCount > 0, state.potentialCancellationIDs.contains(id) {
        state.pendingCancellationIDs.insert(id)
      }
      return state.tokensByID[id]?.value
    }
    token?.cancel()
  }

  fileprivate func cancelAll() {
    let tokens = state.withLock { state -> [EffectCancellationToken] in
      removeReleasedTokens(from: &state)
      state.isGloballyCancelled = true
      return state.tokensByID.values.compactMap(\.value)
    }
    for token in tokens {
      token.cancel()
    }
  }

  fileprivate func beginInterpreter() {
    state.withLock { $0.interpreterCount += 1 }
  }

  fileprivate func endInterpreter() {
    state.withLock { state in
      precondition(state.interpreterCount > 0, "Unbalanced effect interpreter lease")
      state.interpreterCount -= 1
      if state.interpreterCount == 0 {
        state.potentialCancellationIDs.removeAll(keepingCapacity: false)
        state.pendingCancellationIDs.removeAll(keepingCapacity: false)
      }
      removeReleasedTokens(from: &state)
    }
  }

  fileprivate func removeToken(id: AnyEffectID, registrationID: UUID) {
    state.withLock { state in
      guard state.tokensByID[id]?.registrationID == registrationID else { return }
      state.tokensByID.removeValue(forKey: id)
    }
  }

  private func removeReleasedTokens(from state: inout State) {
    let releasedIDs = state.tokensByID.compactMap { id, token in
      token.value == nil ? id : nil
    }
    for id in releasedIDs {
      state.tokensByID.removeValue(forKey: id)
    }
  }

  deinit {
    registry.removeScope(registrationID: registrationID)
  }
}

/// Thread-safe weak registry used to apply a sequence boundary to live scopes.
package final class EffectCancellationScopeRegistry: Sendable {
  private struct WeakScope {
    weak var value: EffectCancellationScope?
  }

  private let scopes = OSAllocatedUnfairLock(initialState: [UUID: WeakScope]())

  package init() {}

  package func makeScopeAndInterpreterLease(
    sequence: UInt64,
    potentialCancellationIDs: Set<AnyEffectID>
  ) -> (scope: EffectCancellationScope, lease: EffectInterpreterLease) {
    let registrationID = UUID()
    let scope = EffectCancellationScope(
      sequence: sequence,
      potentialCancellationIDs: potentialCancellationIDs,
      registrationID: registrationID,
      registry: self
    )
    let lease = scope.makeInterpreterLease()
    scopes.withLock { $0[registrationID] = .init(value: scope) }
    return (scope, lease)
  }

  package func cancel(id: AnyEffectID, upTo sequence: UInt64) {
    for scope in liveScopes(upTo: sequence) {
      scope.cancel(id: id)
    }
  }

  package func cancelAll(upTo sequence: UInt64) {
    for scope in liveScopes(upTo: sequence) {
      scope.cancelAll()
    }
  }

  package var retainedCancellationIDCount: Int {
    liveScopes().reduce(into: 0) { count, scope in
      count += scope.retainedCancellationIDCount
    }
  }

  package var liveScopeCount: Int {
    liveScopes().count
  }

  package var liveInterpreterCount: Int {
    liveScopes().reduce(into: 0) { count, scope in
      count += scope.liveInterpreterCount
    }
  }

  package var retainedPotentialIDCount: Int {
    liveScopes().reduce(into: 0) { count, scope in
      count += scope.retainedPotentialIDCount
    }
  }

  package var liveExactTokenCount: Int {
    liveScopes().reduce(into: 0) { count, scope in
      count += scope.liveExactTokenCount
    }
  }

  fileprivate func removeScope(registrationID: UUID) {
    _ = scopes.withLock { $0.removeValue(forKey: registrationID) }
  }

  private func liveScopes(upTo sequence: UInt64? = nil) -> [EffectCancellationScope] {
    scopes.withLock { scopes in
      removeReleasedScopes(from: &scopes)
      return scopes.values.compactMap(\.value).filter { scope in
        sequence.map { scope.sequence <= $0 } ?? true
      }
    }
  }

  private func removeReleasedScopes(from scopes: inout [UUID: WeakScope]) {
    let releasedIDs = scopes.compactMap { id, scope in
      scope.value == nil ? id : nil
    }
    for id in releasedIDs {
      scopes.removeValue(forKey: id)
    }
  }
}
