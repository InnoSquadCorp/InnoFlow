import Foundation
import InnoFlow

public extension TestStore {
  /// Sends an action and verifies that the observed phase transition is allowed
  /// by the provided graph.
  func send<Phase: Hashable & Sendable>(
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
  func receive<Phase: Hashable & Sendable>(
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
