import Foundation
import os

/// Runs an optional child before its parent and binds the child's effects to
/// the lifetime of its explicit instance identity.
///
/// Use a fresh instance ID when reopening a child, even if its business ID is
/// unchanged. Keeping the ID denotes the same lifetime. The identity projection
/// must be pure and stable: hosts also evaluate it against final composed state.
/// This wrapper already reduces the child; do not also install `IfLet` for the same slot.
public struct OptionalChildLifetime<Parent: Reducer, Child: Reducer, ID: Hashable & Sendable>:
  Reducer
where Parent.Output == Child.Output {
  public typealias State = Parent.State
  public typealias Action = Parent.Action
  public typealias Output = Parent.Output

  private let parent: Parent
  private let child: Child
  private let statePath: any WritableKeyPath<State, Child.State?> & Sendable
  private let actionPath: CasePath<Action, Child.Action>
  private let instanceID: @Sendable (Child.State) -> ID
  private let slot: ChildLifetimeSlot

  public init(
    parent: Parent,
    state: any WritableKeyPath<State, Child.State?> & Sendable,
    action: CasePath<Action, Child.Action>,
    instanceID: @escaping @Sendable (Child.State) -> ID,
    reducer: Child,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    column: UInt = #column
  ) {
    self.parent = parent
    self.child = reducer
    self.statePath = state
    self.actionPath = action
    self.instanceID = instanceID
    self.slot = ChildLifetimeSlot(
      state: state, instanceID: instanceID, file: fileID.description, line: line, column: column)
  }

  public func reduce(into state: inout State, action: Action) -> ReducerEffect<Action, Output> {
    let before = state[keyPath: statePath].map { AnyEffectID(EffectID(instanceID($0))) }
    var childEffect: ReducerEffect<Action, Output> = .none
    if let childAction = actionPath.extract(action), var childState = state[keyPath: statePath] {
      childEffect = child.reduce(into: &childState, action: childAction).map(actionPath.embed)
      state[keyPath: statePath] = childState
    }
    let parentEffect = parent.reduce(into: &state, action: action)
    let after = state[keyPath: statePath].map { AnyEffectID(EffectID(instanceID($0))) }
    return .init(
      operation: .optionalChild(
        slot: slot, before: before, after: after, child: childEffect, parent: parentEffect
      ))
  }
}

extension Reducer {
  /// Adds opt-in optional-child lifetime management around this parent reducer.
  ///
  /// Child reduction runs first. Removal or replacement by either reducer
  /// invalidates old child actions and outputs before any effects are delivered.
  /// Cancellation IDs and scheduler lanes inside the child are owner-local;
  /// cancelling a raw ID outside it does not cancel that child's work.
  public func optionalChild<Child: Reducer, ID: Hashable & Sendable>(
    state: any WritableKeyPath<State, Child.State?> & Sendable,
    action: CasePath<Action, Child.Action>,
    instanceID: @escaping @Sendable (Child.State) -> ID,
    reducer: Child,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    column: UInt = #column
  ) -> OptionalChildLifetime<Self, Child, ID> where Child.Output == Output {
    OptionalChildLifetime(
      parent: self, state: state, action: action, instanceID: instanceID, reducer: reducer,
      fileID: fileID, line: line, column: column
    )
  }
}

/// Structural identity whose captured key-path indices are compiler-checked Sendable.
package final class ChildLifetimeKeyPath: Hashable, Sendable {
  private let path: any AnyKeyPath & Sendable
  package init(_ path: any AnyKeyPath & Sendable) { self.path = path }
  package static func == (lhs: ChildLifetimeKeyPath, rhs: ChildLifetimeKeyPath) -> Bool {
    lhs.path == rhs.path
  }
  package func hash(into hasher: inout Hasher) { hasher.combine(path) }
}

/// An immutable, Sendable projection invoked only during MainActor reconciliation.
/// Erased snapshots stay in the caller's isolation domain; no closure or state is
/// transferred by a read, and user projections never run inside a lock.
package final class ChildLifetimeProjection: Hashable, Sendable {
  private let id: AnyEffectID
  private let read: @MainActor @Sendable (Any) -> Any?

  init(id: AnyEffectID, read: @escaping @MainActor @Sendable (Any) -> Any?) {
    self.id = id
    self.read = read
  }

  @MainActor
  func value(in state: Any) -> Any? { read(state) }

  package static func == (lhs: ChildLifetimeProjection, rhs: ChildLifetimeProjection) -> Bool {
    lhs.id == rhs.id
  }

  package func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A declaration identity independent of manually rebuilt CasePath closures.
package struct ChildLifetimeCaseLocation: Hashable, Sendable {
  private let rootType: ObjectIdentifier
  private let valueType: ObjectIdentifier
  private let file: String
  private let line: UInt
  private let column: UInt
  private let explicitID: AnyEffectID?

  package init<Root, Value>(
    state: CasePath<Root, Value>, explicitID: AnyEffectID? = nil,
    fileID: StaticString, line: UInt, column: UInt
  ) {
    rootType = ObjectIdentifier(Root.self)
    valueType = ObjectIdentifier(Value.self)
    file = fileID.description
    self.line = line
    self.column = column
    self.explicitID = explicitID
  }

  package var effectID: AnyEffectID { AnyEffectID(EffectID(self)) }
}

private struct ChildLifetimeCollectionLocation: Hashable, Sendable {
  let state: ChildLifetimeKeyPath
  let element: AnyEffectID
}

package struct ChildLifetimeSlot: Hashable, Sendable {
  let state: ChildLifetimeKeyPath
  let file: String
  let line: UInt
  let column: UInt
  private let read: @MainActor @Sendable (Any) -> (identity: AnyEffectID, state: Any)?

  init<Root, ChildState, ID: Hashable & Sendable>(
    state: any WritableKeyPath<Root, ChildState?> & Sendable,
    instanceID: @escaping @Sendable (ChildState) -> ID,
    file: String, line: UInt, column: UInt
  ) {
    self.state = ChildLifetimeKeyPath(state)
    self.file = file
    self.line = line
    self.column = column
    self.read = { root in
      guard let root = root as? Root, let child = root[keyPath: state] else { return nil }
      return (AnyEffectID(EffectID(instanceID(child))), child)
    }
  }

  @MainActor
  func snapshot(in state: Any) -> (identity: AnyEffectID, state: Any)? {
    read(state)
  }

  package static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.state == rhs.state && lhs.file == rhs.file && lhs.line == rhs.line
      && lhs.column == rhs.column
  }

  package func hash(into hasher: inout Hasher) {
    hasher.combine(state)
    hasher.combine(file)
    hasher.combine(line)
    hasher.combine(column)
  }
}

extension ReducerEffect {
  @usableFromInline
  func inLifetimeScope<Root, Value>(state: any KeyPath<Root, Value> & Sendable) -> Self {
    guard containsLifetimeMetadata else { return self }
    return .init(
      operation: .lifetimeScope(
        id: ChildLifetimeProjection(id: AnyEffectID(EffectID(ChildLifetimeKeyPath(state)))) {
          ($0 as? Root).map { $0[keyPath: state] }
        }, effect: self
      ))
  }

  @usableFromInline
  func inLifetimeScope<Root, Value>(state: any KeyPath<Root, Value?> & Sendable) -> Self {
    guard containsLifetimeMetadata else { return self }
    return .init(
      operation: .lifetimeScope(
        id: ChildLifetimeProjection(id: AnyEffectID(EffectID(ChildLifetimeKeyPath(state)))) {
          ($0 as? Root).flatMap { $0[keyPath: state] }
        }, effect: self
      ))
  }

  @usableFromInline
  func inLifetimeScope<Root, Value>(
    state: CasePath<Root, Value>, id: AnyEffectID
  ) -> Self {
    guard containsLifetimeMetadata else { return self }
    return .init(
      operation: .lifetimeScope(
        id: ChildLifetimeProjection(id: id) {
          ($0 as? Root).flatMap(state.extract)
        }, effect: self
      ))
  }

  @usableFromInline
  func inLifetimeScope<Root, Collection, ID: Hashable & Sendable, Element>(
    state: any KeyPath<Root, Collection> & Sendable, elementID: ID,
    element: @escaping @MainActor @Sendable (Collection, ID) -> Element?
  ) -> Self {
    guard containsLifetimeMetadata else { return self }
    let location = ChildLifetimeCollectionLocation(
      state: ChildLifetimeKeyPath(state), element: AnyEffectID(EffectID(elementID)))
    return .init(
      operation: .lifetimeScope(
        id: ChildLifetimeProjection(id: AnyEffectID(EffectID(location))) {
          ($0 as? Root).flatMap { element($0[keyPath: state], elementID) }
        }, effect: self
      ))
  }
}

/// Captured by events, never reconstructed from the current child state.
package final class ChildLifetimeOwner: Sendable {
  package let generation = UUID()
  private let cancelled = OSAllocatedUnfairLock(initialState: false)

  package var cancellationID: AnyEffectID {
    AnyEffectID(EffectID(CancellationID(generation: generation)))
  }
  package var isCancelled: Bool { cancelled.withLock { $0 } }
  package func invalidate() { cancelled.withLock { $0 = true } }

  package func namespace(_ id: AnyEffectID) -> AnyEffectID {
    AnyEffectID(EffectID(NamespacedID(owner: generation, raw: id)))
  }

  private struct CancellationID: Hashable, Sendable { let generation: UUID }

  private struct NamespacedID: Hashable, Sendable {
    let owner: UUID
    let raw: AnyEffectID
  }
}

/// Contains only active slots. Retired tokens live solely in outstanding work.
@MainActor
package final class ChildLifetimeRegistry {
  private struct Location: Hashable {
    let path: [ChildLifetimeProjection]
    let slot: ChildLifetimeSlot
  }
  private final class Node {
    let identity: AnyEffectID
    let owner = ChildLifetimeOwner()
    var children: [Location: Node] = [:]
    init(identity: AnyEffectID) { self.identity = identity }
  }
  private var roots: [Location: Node] = [:]

  package init() {}

  package var activeOwnerCount: Int {
    func count(_ nodes: [Location: Node]) -> Int {
      nodes.values.reduce(0) { $0 + 1 + count($1.children) }
    }
    return count(roots)
  }

  /// Check before materializing State at the call site. Existing owners still
  /// need final-state reconciliation even when this effect carries no metadata.
  package func requiresPreparation<Action, Output>(
    for effect: ReducerEffect<Action, Output>
  ) -> Bool {
    effect.containsLifetimeMetadata || !roots.isEmpty
  }

  package func prepare<Action, Output, State>(
    _ effect: ReducerEffect<Action, Output>,
    state: State,
    invalidate: (AnyEffectID) -> Void
  ) -> ReducerEffect<Action, Output> {
    guard requiresPreparation(for: effect) else { return effect }
    let prepared =
      effect.containsLifetimeMetadata
      ? prepare(effect, parent: nil, path: [], invalidate: invalidate) : effect
    // A later parent reducer can remove or replace a collection element without
    // routing another action through that element. Reconcile before delivery.
    reconcile(&roots, state: state, invalidate: invalidate)
    return prepared
  }

  private func reconcile(
    _ nodes: inout [Location: Node], state: Any, invalidate: (AnyEffectID) -> Void
  ) {
    for (location, node) in nodes {
      let parentState = location.path.reduce(Optional(state)) { value, step in
        value.flatMap { step.value(in: $0) }
      }
      guard let parentState, let snapshot = location.slot.snapshot(in: parentState),
        snapshot.identity == node.identity
      else {
        close(node, invalidate: invalidate)
        nodes.removeValue(forKey: location)
        continue
      }
      reconcile(&node.children, state: snapshot.state, invalidate: invalidate)
    }
  }

  package func removeAll() {
    for node in roots.values { close(node, invalidate: { _ in }) }
    roots.removeAll()
  }

  private func close(_ node: Node, invalidate: (AnyEffectID) -> Void) {
    node.owner.invalidate()
    for child in node.children.values { close(child, invalidate: invalidate) }
    node.children.removeAll()
    invalidate(node.owner.cancellationID)
  }

  private func prepare<Action, Output>(
    _ effect: ReducerEffect<Action, Output>,
    parent: Node?,
    path: [ChildLifetimeProjection],
    invalidate: (AnyEffectID) -> Void
  ) -> ReducerEffect<Action, Output> {
    func recurse(_ effect: ReducerEffect<Action, Output>) -> ReducerEffect<Action, Output> {
      prepare(effect, parent: parent, path: path, invalidate: invalidate)
    }
    func id(_ raw: AnyEffectID) -> AnyEffectID { parent?.owner.namespace(raw) ?? raw }
    switch effect.operation {
    case .lifetimeScope(let id, let nested):
      return prepare(nested, parent: parent, path: path + [id], invalidate: invalidate)
    case .optionalChild(let slot, let before, let after, let child, let parentEffect):
      let location = Location(path: path, slot: slot)
      var slots = parent?.children ?? roots
      var previous = slots[location]
      if previous?.identity != before {
        if let previous { close(previous, invalidate: invalidate) }
        previous = before.map(Node.init)
      }
      let childEffect: ReducerEffect<Action, Output>
      if let previous, !child.isNone {
        childEffect = .init(
          operation: .owned(
            owner: previous.owner,
            effect: prepare(child, parent: previous, path: [], invalidate: invalidate)
          ))
      } else {
        childEffect = .none
      }
      if before != after {
        if let previous { close(previous, invalidate: invalidate) }
        slots[location] = after.map(Node.init)
      } else {
        slots[location] = previous
      }
      if let parent { parent.children = slots } else { roots = slots }
      // Prepare every branch before executing any branch, including siblings.
      return .merge(childEffect, recurse(parentEffect))
    case .merge(let effects):
      return .merge(effects.map(recurse))
    case .concatenate(let effects):
      return .concatenate(effects.map(recurse))
    case .cancellable(let effect, let raw, let cancelInFlight):
      return recurse(effect).cancellable(id(raw), cancelInFlight: cancelInFlight)
    case .debounce(let effect, let raw, let interval):
      return recurse(effect).debounce(id(raw), for: interval)
    case .throttle(let effect, let raw, let interval, let leading, let trailing):
      return recurse(effect).throttle(id(raw), for: interval, leading: leading, trailing: trailing)
    case .scheduledRun(let raw, let policy, let priority, let onAdmission, let operation):
      return .init(
        operation: .scheduledRun(
          id: id(raw), policy: policy, priority: priority, onAdmission: onAdmission,
          operation: operation
        ))
    case .cancel(let raw):
      return .cancel(id(raw))
    case .animation(let effect, let animation):
      return recurse(effect).applyingAnimation(animation)
    case .lazyMap(let lazy):
      return recurse(lazy.materialize())
    case .owned:
      return effect
    case .none, .send, .output, .run, .diagnosticDrop:
      return effect
    }
  }
}
