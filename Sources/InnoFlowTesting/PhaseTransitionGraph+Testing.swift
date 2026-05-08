import Foundation
@_exported public import InnoFlowCore

public func assertValidGraph<Phase: Hashable & Sendable>(
  _ graph: PhaseTransitionGraph<Phase>,
  allPhases: Set<Phase>,
  root: Phase,
  terminalPhases: Set<Phase> = [],
  file: StaticString = #file,
  line: UInt = #line
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
      file: file,
      line: line
    )
    return
  }
}

extension TestStore {
  /// Sends an action and verifies that the observed phase transition is allowed
  /// by the provided graph.
  public func send<Phase: Hashable & Sendable>(
    _ action: R.Action,
    tracking phase: KeyPath<R.State, Phase>,
    through graph: PhaseTransitionGraph<Phase>,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    file: StaticString = #file,
    line: UInt = #line
  ) async {
    let previousPhase = state[keyPath: phase]
    await send(action, assert: updateExpectedState, file: file, line: line)
    let nextPhase = state[keyPath: phase]

    guard previousPhase != nextPhase else { return }

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
        file: file,
        line: line
      )
      return
    }
  }

  /// Receives an action from an effect and verifies the phase transition.
  public func receive<Phase: Hashable & Sendable>(
    _ expectedAction: R.Action,
    tracking phase: KeyPath<R.State, Phase>,
    through graph: PhaseTransitionGraph<Phase>,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    file: StaticString = #file,
    line: UInt = #line
  ) async where R.Action: Equatable {
    let previousPhase = state[keyPath: phase]
    await receive(expectedAction, assert: updateExpectedState, file: file, line: line)
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
        file: file,
        line: line
      )
      return
    }
  }
}
