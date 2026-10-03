// MARK: - TestStore+Invariants.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
package import InnoFlowCore

extension TestStore {
  /// Registers an invariant that is checked after every subsequent reduction.
  ///
  /// Explicit invariants remain active when ``exhaustivity`` is `.off`.
  public func addInvariant(
    _ invariant: TestStoreInvariant<R.State>
  ) {
    invariants.append(invariant)
  }

  /// Convenience spelling for registering a named state predicate.
  public func addInvariant(
    _ name: String,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column,
    predicate: @escaping @MainActor @Sendable (R.State) -> Bool
  ) {
    addInvariant(
      name, location: .init(fileID: fileID, filePath: filePath, line: line, column: column),
      predicate: predicate)
  }

  /// Compatibility overload for an explicitly supplied legacy source file.
  public func addInvariant(
    _ name: String,
    file: StaticString,
    line: UInt = #line,
    predicate: @escaping @MainActor @Sendable (R.State) -> Bool
  ) {
    addInvariant(
      name, location: .init(fileID: file, filePath: file, line: line, column: 1),
      predicate: predicate)
  }

  package func addInvariant(
    _ name: String,
    location: TestStoreSourceLocation,
    predicate: @escaping @MainActor @Sendable (R.State) -> Bool
  ) {
    addInvariant(
      TestStoreInvariant(name, location: location, predicate: predicate)
    )
  }

  package func reduceAction(
    _ action: R.Action,
    source: TestStoreReductionSource,
    location: TestStoreSourceLocation
  ) -> ReducerEffect<R.Action, R.Output> {
    let previousState = state
    let effect = childLifetimeRegistry.prepare(reducer.reduce(into: &state, action: action)) { id in
      let sequence = markCancelled(id: id)
      cancelEffectsSynchronously(identifiedBy: id, upTo: sequence)
    }
    checkInvariants(
      previousState: previousState,
      action: action,
      source: source,
      fallbackLocation: location
    )
    return effect
  }

  private func checkInvariants(
    previousState: R.State,
    action: R.Action,
    source: TestStoreReductionSource,
    fallbackLocation: TestStoreSourceLocation
  ) {
    for invariant in invariants where invariant.predicate(state) == false {
      let diff =
        renderStateDiff(
          expected: previousState,
          actual: state,
          lineLimit: diffLineLimit
        ).map { "\n\nState change:\n\($0)" } ?? ""
      issueReporter(
        """
        TestStore invariant failed: \(invariant.name)

        Reduction source: \(source.rawValue)
        Action: \(String(describing: action))
        Final state: \(String(describing: state))\(diff)
        """,
        invariant.location.filePath.description.isEmpty || invariant.location.line == 0
          ? fallbackLocation : invariant.location
      )
    }
  }
}
