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
  /// Sends an action and verifies that the observed phase transition is allowed
  /// by the provided graph.
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
    let previousPhase = state[keyPath: phase]
    let task = await send(action, assert: updateExpectedState, location: location)
    let nextPhase = state[keyPath: phase]

    guard previousPhase != nextPhase else { return task }

    guard graph.allows(from: previousPhase, to: nextPhase) else {
      testStoreAssertionFailure(
        """
        Illegal phase transition detected.

        Action:
        \(action)

        From:
        \(previousPhase)

        To:
        \(nextPhase)

        Allowed next phases:
        \(graph.successors(from: previousPhase))
        """,
        location: location
      )
      return task
    }
    return task
  }

  /// Receives an action from an effect and verifies the phase transition.
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
    let previousPhase = state[keyPath: phase]
    await receive(expectedAction, assert: updateExpectedState, location: location)
    let nextPhase = state[keyPath: phase]

    guard previousPhase != nextPhase else { return }

    guard graph.allows(from: previousPhase, to: nextPhase) else {
      testStoreAssertionFailure(
        """
        Illegal phase transition detected while receiving effect action.

        Action:
        \(expectedAction)

        From:
        \(previousPhase)

        To:
        \(nextPhase)

        Allowed next phases:
        \(graph.successors(from: previousPhase))
        """,
        location: location
      )
      return
    }
  }

  /// Receives an action under a per-assertion timeout and verifies the phase
  /// transition against the supplied graph.
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
    let previousPhase = state[keyPath: phase]
    await receive(
      expectedAction,
      timeout: timeout,
      assert: updateExpectedState,
      location: location
    )
    let nextPhase = state[keyPath: phase]

    guard previousPhase != nextPhase else { return }

    guard graph.allows(from: previousPhase, to: nextPhase) else {
      testStoreAssertionFailure(
        """
        Illegal phase transition detected while receiving effect action.

        Action:
        \(expectedAction)

        From:
        \(previousPhase)

        To:
        \(nextPhase)

        Allowed next phases:
        \(graph.successors(from: previousPhase))
        """,
        location: location
      )
      return
    }
  }
}
