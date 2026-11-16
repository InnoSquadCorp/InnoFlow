// MARK: - EffectCancellationScope.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import Synchronization

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

/// A cancellation request returned by a reducer.
///
/// `all` cancels every effect for the identifier up to the requesting
/// sequence; `inFlight` keeps the requesting sequence alive and cancels only
/// its predecessors (`cancelInFlight: true`, debounce replacement).
package enum EffectCancellationRequest: Hashable, Sendable {
  case all(AnyEffectID)
  case inFlight(AnyEffectID)

  package var id: AnyEffectID {
    switch self {
    case .all(let id), .inFlight(let id): return id
    }
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
  private let cancelled = Mutex(false)

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
/// interpreter may discover later (for example through a concatenate
/// sibling). Once interpretation ends, unrelated long-running work retains
/// no historical dynamic IDs.
///
/// Lock discipline: tokens and scopes are referenced weakly and remove their
/// own entry from a deinitializer that takes the owning lock. A strong
/// reference loaded from weak storage must therefore never be released while
/// that lock is held — if another thread dropped the last other reference in
/// the meantime, the release would run the deinitializer and re-enter the
/// lock. Every lookup hands the loaded reference out of the critical section
/// and releases it afterwards; nothing inside a critical section tests a weak
/// reference for liveness.
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
    /// Requests accepted in the reduction turn, before the interpreter task
    /// reaches the node that issued them, counted per request.
    var acceptedCancellations: [EffectCancellationRequest: Int] = [:]
    /// The dispatch whose effect this scope belongs to, and whether its root
    /// interpreter has still to start. Work such a scope declares is not
    /// registered anywhere yet, so a cancellation accepted in that gap finds
    /// the affected dispatch here.
    var dispatchID: DispatchID?
    var awaitsInterpretation = true

    init(potentialCancellationIDs: Set<AnyEffectID>) {
      self.potentialCancellationIDs = potentialCancellationIDs
    }
  }

  package let sequence: UInt64

  private let registrationID: UUID
  private let registry: EffectCancellationScopeRegistry
  private let state: Mutex<State>

  fileprivate init(
    sequence: UInt64,
    potentialCancellationIDs: Set<AnyEffectID>,
    registrationID: UUID,
    registry: EffectCancellationScopeRegistry
  ) {
    self.sequence = sequence
    self.registrationID = registrationID
    self.registry = registry
    self.state = Mutex(
      State(potentialCancellationIDs: potentialCancellationIDs)
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
    let lookup = state.withLock { state -> (isCancelled: Bool, token: EffectCancellationToken?) in
      if state.isGloballyCancelled || state.pendingCancellationIDs.contains(id) {
        return (true, nil)
      }
      return (false, state.tokensByID[id]?.value)
    }
    return lookup.isCancelled || lookup.token?.isCancelled == true
  }

  package var retainedCancellationIDCount: Int {
    state.withLock { $0.pendingCancellationIDs.count }
  }

  package var retainedPotentialIDCount: Int {
    state.withLock { $0.potentialCancellationIDs.count }
  }

  package var liveExactTokenCount: Int {
    liveTokens().count
  }

  /// Strong references to every token that is still alive. The references
  /// leave the critical section so their release cannot re-enter the lock.
  private func liveTokens() -> [EffectCancellationToken] {
    state.withLock { state in
      state.tokensByID.values.compactMap(\.value)
    }
  }

  package var liveInterpreterCount: Int {
    state.withLock { $0.interpreterCount }
  }

  /// Names the dispatch that owns this scope's effect.
  package func bindDispatch(_ dispatchID: DispatchID?) {
    state.withLock { $0.dispatchID = dispatchID }
  }

  /// Marks the root interpreter as started: from here on the work this scope
  /// owns is registered with the runtime as it is created.
  package func beginInterpretation() {
    state.withLock { $0.awaitsInterpretation = false }
  }

  /// The owning dispatch, while the root interpreter has not started and the
  /// effect declares work under `id` (any work when `id` is `nil`).
  fileprivate func uninterpretedDispatchID(declaring id: AnyEffectID?) -> DispatchID? {
    state.withLock { state in
      guard state.awaitsInterpretation, state.interpreterCount > 0 else { return nil }
      if let id, !state.potentialCancellationIDs.contains(id) { return nil }
      return state.dispatchID
    }
  }

  /// Records a request accepted synchronously with the reduction that
  /// returned it. The interpreter later consumes exactly one entry per node,
  /// so acceptance and its instrumentation happen once.
  package func recordAcceptedCancellation(_ request: EffectCancellationRequest) {
    state.withLock { $0.acceptedCancellations[request, default: 0] += 1 }
  }

  /// Returns `true` when the request was already accepted for this sequence,
  /// consuming that acceptance; `false` when the interpreter must accept it.
  package func consumeAcceptedCancellation(_ request: EffectCancellationRequest) -> Bool {
    state.withLock { state in
      guard let count = state.acceptedCancellations[request], count > 0 else {
        return false
      }
      state.acceptedCancellations[request] = count == 1 ? nil : count - 1
      return true
    }
  }

  fileprivate func cancel(id: AnyEffectID) {
    let token = state.withLock { state -> EffectCancellationToken? in
      if state.interpreterCount > 0, state.potentialCancellationIDs.contains(id) {
        state.pendingCancellationIDs.insert(id)
      }
      return state.tokensByID[id]?.value
    }
    token?.cancel()
  }

  package func cancelAll() {
    let tokens = state.withLock { state -> [EffectCancellationToken] in
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
        state.acceptedCancellations.removeAll(keepingCapacity: false)
      }
    }
  }

  fileprivate func removeToken(id: AnyEffectID, registrationID: UUID) {
    state.withLock { state in
      guard state.tokensByID[id]?.registrationID == registrationID else { return }
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

  private let scopes = Mutex([UUID: WeakScope]())

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
    for scope in liveScopes() where scope.sequence <= sequence {
      scope.cancel(id: id)
    }
  }

  package func cancelAll(upTo sequence: UInt64) {
    for scope in liveScopes() where scope.sequence <= sequence {
      scope.cancelAll()
    }
  }

  /// Dispatches at or below `sequence` whose root interpreter has not started
  /// and whose effect declares work under `id` (any work when `id` is `nil`).
  package func uninterpretedDispatchIDs(
    declaring id: AnyEffectID?,
    upTo sequence: UInt64
  ) -> Set<DispatchID> {
    var dispatchIDs: Set<DispatchID> = []
    for scope in liveScopes() where scope.sequence <= sequence {
      if let dispatchID = scope.uninterpretedDispatchID(declaring: id) {
        dispatchIDs.insert(dispatchID)
      }
    }
    return dispatchIDs
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

  /// Strong references to every scope that is still alive. A scope removes
  /// its own entry when it is deinitialized, so the lookup never prunes; the
  /// references leave the critical section and callers filter them outside
  /// it, so no scope is released while the registry lock is held.
  private func liveScopes() -> [EffectCancellationScope] {
    scopes.withLock { scopes in
      scopes.values.compactMap(\.value)
    }
  }
}
