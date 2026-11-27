import Foundation
@_exported public import InnoFlowCore

public func assertValidGraph<Phase: Hashable & Sendable>(
  _ graph: PhaseTransitionGraph<Phase>,
  allPhases: Set<Phase>,
  root: Phase,
  terminalPhases: Set<Phase> = [],
  fileID: StaticString = #fileID,
  filePath: StaticString = #filePath,
  line: UInt = #line,
  column: UInt = #column
) {
  assertValidGraph(
    graph, allPhases: allPhases, root: root, terminalPhases: terminalPhases,
    location: .init(fileID: fileID, filePath: filePath, line: line, column: column))
}

/// Compatibility overload for an explicitly supplied legacy source file.
public func assertValidGraph<Phase: Hashable & Sendable>(
  _ graph: PhaseTransitionGraph<Phase>,
  allPhases: Set<Phase>,
  root: Phase,
  terminalPhases: Set<Phase> = [],
  file: StaticString,
  line: UInt = #line
) {
  assertValidGraph(
    graph, allPhases: allPhases, root: root, terminalPhases: terminalPhases,
    location: .init(fileID: file, filePath: file, line: line, column: 1))
}

package func assertValidGraph<Phase: Hashable & Sendable>(
  _ graph: PhaseTransitionGraph<Phase>,
  allPhases: Set<Phase>,
  root: Phase,
  terminalPhases: Set<Phase> = [],
  location: TestStoreSourceLocation
) {
  let report = graph.validationReport(
    allPhases: allPhases,
    root: root,
    terminalPhases: terminalPhases
  )

  guard report.issues.isEmpty else {
    testStoreAssertionFailure(
      """
      Phase graph validation failed.

      Root:
      \(root)

      Terminal phases:
      \(terminalPhases)

      Reachable phases:
      \(report.reachable)

      Unreachable phases:
      \(report.unreachable)

      Issues:
      \(report.issues)
      """,
      location: location
    )
    return
  }
}

extension TestStore {
  /// Sends an action and verifies that the phase transition its reduction
  /// makes is allowed by the provided graph.
  ///
  /// The transition is the one that reduction makes: from the phase right
  /// before the reducer runs for `action` to the phase right after. The
  /// buffered effect actions a send reduces first have been reduced by then,
  /// and their own transitions are not checked.
  @discardableResult
  public func send<Phase: Hashable & Sendable>(
    _ action: R.Action,
    tracking phase: KeyPath<R.State, Phase>,
    through graph: PhaseTransitionGraph<Phase>,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) async -> TestStoreDispatch {
    await send(
      action, tracking: phase, through: graph, assert: updateExpectedState,
      location: .init(fileID: fileID, filePath: filePath, line: line, column: column))
  }

  /// Compatibility overload for an explicitly supplied legacy source file.
  @discardableResult
  public func send<Phase: Hashable & Sendable>(
    _ action: R.Action,
    tracking phase: KeyPath<R.State, Phase>,
    through graph: PhaseTransitionGraph<Phase>,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    file: StaticString,
    line: UInt = #line
  ) async -> TestStoreDispatch {
    await send(
      action, tracking: phase, through: graph, assert: updateExpectedState,
      location: .init(fileID: file, filePath: file, line: line, column: 1))
  }

  @discardableResult
  package func send<Phase: Hashable & Sendable>(
    _ action: R.Action,
    tracking phase: KeyPath<R.State, Phase>,
    through graph: PhaseTransitionGraph<Phase>,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    location: TestStoreSourceLocation
  ) async -> TestStoreDispatch {
    await send(action, assert: updateExpectedState, location: location) { previousState in
      assertPhaseTransition(
        from: previousState, tracking: phase, through: graph, madeBy: action,
        failure: "Illegal phase transition detected.", location: location)
    }
  }

  /// Receives an action from an effect and verifies that the phase transition
  /// its reduction makes is allowed by the provided graph.
  ///
  /// The transition is the one that reduction makes: from the phase right
  /// before the reducer runs for `expectedAction` to the phase right after. A
  /// non-exhaustive store has reduced the actions it skips by then, and their
  /// own transitions are not checked. No transition is checked when
  /// `expectedAction` is not received: another action arrives in an
  /// exhaustive store, or the wait times out.
  public func receive<Phase: Hashable & Sendable>(
    _ expectedAction: R.Action,
    tracking phase: KeyPath<R.State, Phase>,
    through graph: PhaseTransitionGraph<Phase>,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) async where R.Action: Equatable {
    await receive(
      expectedAction, tracking: phase, through: graph, assert: updateExpectedState,
      location: .init(fileID: fileID, filePath: filePath, line: line, column: column))
  }

  /// Compatibility overload for an explicitly supplied legacy source file.
  public func receive<Phase: Hashable & Sendable>(
    _ expectedAction: R.Action,
    tracking phase: KeyPath<R.State, Phase>,
    through graph: PhaseTransitionGraph<Phase>,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    file: StaticString,
    line: UInt = #line
  ) async where R.Action: Equatable {
    await receive(
      expectedAction, tracking: phase, through: graph, assert: updateExpectedState,
      location: .init(fileID: file, filePath: file, line: line, column: 1))
  }

  package func receive<Phase: Hashable & Sendable>(
    _ expectedAction: R.Action,
    tracking phase: KeyPath<R.State, Phase>,
    through graph: PhaseTransitionGraph<Phase>,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    location: TestStoreSourceLocation
  ) async where R.Action: Equatable {
    await receiveExact(
      expectedAction, timeout: nil, assert: updateExpectedState, location: location
    ) { previousState in
      assertPhaseTransition(
        from: previousState, tracking: phase, through: graph, madeBy: expectedAction,
        failure: "Illegal phase transition detected while receiving effect action.",
        location: location)
    }
  }

  /// Receives an action under a per-assertion timeout and verifies the phase
  /// transition its reduction makes against the supplied graph, as the
  /// overload without a timeout does.
  public func receive<Phase: Hashable & Sendable>(
    _ expectedAction: R.Action,
    tracking phase: KeyPath<R.State, Phase>,
    through graph: PhaseTransitionGraph<Phase>,
    timeout: Duration,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) async where R.Action: Equatable {
    await receive(
      expectedAction, tracking: phase, through: graph, timeout: timeout,
      assert: updateExpectedState,
      location: .init(fileID: fileID, filePath: filePath, line: line, column: column))
  }

  /// Compatibility overload for an explicitly supplied legacy source file.
  public func receive<Phase: Hashable & Sendable>(
    _ expectedAction: R.Action,
    tracking phase: KeyPath<R.State, Phase>,
    through graph: PhaseTransitionGraph<Phase>,
    timeout: Duration,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    file: StaticString,
    line: UInt = #line
  ) async where R.Action: Equatable {
    await receive(
      expectedAction, tracking: phase, through: graph, timeout: timeout,
      assert: updateExpectedState,
      location: .init(fileID: file, filePath: file, line: line, column: 1))
  }

  package func receive<Phase: Hashable & Sendable>(
    _ expectedAction: R.Action,
    tracking phase: KeyPath<R.State, Phase>,
    through graph: PhaseTransitionGraph<Phase>,
    timeout: Duration,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    location: TestStoreSourceLocation
  ) async where R.Action: Equatable {
    await receiveExact(
      expectedAction, timeout: timeout, assert: updateExpectedState, location: location
    ) { previousState in
      assertPhaseTransition(
        from: previousState, tracking: phase, through: graph, madeBy: expectedAction,
        failure: "Illegal phase transition detected while receiving effect action.",
        location: location)
    }
  }

  /// Reports the phase transition one reduction made, from `previousState`
  /// to the current state, unless `graph` allows it. A reduction that leaves
  /// the phase unchanged makes no transition.
  ///
  /// The caller passes the state right before the reducer ran for `action`
  /// and calls this right after that reduction. A phase read earlier would
  /// also span the buffered actions a send reduces first and the actions a
  /// non-exhaustive receive skips.
  private func assertPhaseTransition<Phase: Hashable & Sendable>(
    from previousState: R.State,
    tracking phase: KeyPath<R.State, Phase>,
    through graph: PhaseTransitionGraph<Phase>,
    madeBy action: R.Action,
    failure: String,
    location: TestStoreSourceLocation
  ) {
    let previousPhase = previousState[keyPath: phase]
    let nextPhase = state[keyPath: phase]

    guard previousPhase != nextPhase, !graph.allows(from: previousPhase, to: nextPhase) else {
      return
    }
    issueReporter(
      """
      \(failure)

      Action:
      \(action)

      From:
      \(previousPhase)

      To:
      \(nextPhase)

      Allowed next phases:
      \(graph.successors(from: previousPhase))
      """,
      location
    )
  }
}
