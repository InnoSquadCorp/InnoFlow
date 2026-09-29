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
    file: StaticString = #filePath,
    line: UInt = #line,
    predicate: @escaping @MainActor @Sendable (R.State) -> Bool
  ) {
    addInvariant(
      TestStoreInvariant(name, file: file, line: line, predicate: predicate)
    )
  }

  package func reduceAction(
    _ action: R.Action,
    source: TestStoreReductionSource,
    file: StaticString,
    line: UInt
  ) -> ReducerEffect<R.Action, R.Output> {
    let previousState = state
    let effect = reducer.reduce(into: &state, action: action)
    checkInvariants(
      previousState: previousState,
      action: action,
      source: source,
      fallbackFile: file,
      fallbackLine: line
    )
    return effect
  }

  private func checkInvariants(
    previousState: R.State,
    action: R.Action,
    source: TestStoreReductionSource,
    fallbackFile: StaticString,
    fallbackLine: UInt
  ) {
    for invariant in invariants where invariant.predicate(state) == false {
      let diff =
        renderStateDiff(
          expected: previousState,
          actual: state,
          lineLimit: diffLineLimit
        ).map { "\n\nState change:\n\($0)" } ?? ""
      assertionFailureReporter(
        """
        TestStore invariant failed: \(invariant.name)

        Reduction source: \(source.rawValue)
        Action: \(String(describing: action))
        Final state: \(String(describing: state))\(diff)
        """,
        invariant.file.description.isEmpty ? fallbackFile : invariant.file,
        invariant.line == 0 ? fallbackLine : invariant.line
      )
    }
  }
}
