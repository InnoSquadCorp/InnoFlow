import Foundation
@_exported public import InnoFlowCore

@discardableResult
public func assertPhaseMapCovers<State: Sendable, Action: Sendable, Phase: Hashable & Sendable>(
  _ phaseMap: PhaseMap<State, Action, Phase>,
  expectedTriggersByPhase: [Phase: [PhaseMapExpectedTrigger<Action>]],
  file: StaticString = #file,
  line: UInt = #line
) -> PhaseMapValidationReport<Phase> {
  let report = phaseMap.validationReport(expectedTriggersByPhase: expectedTriggersByPhase)

  guard report.isEmpty else {
    testStoreAssertionFailure(
      """
      PhaseMap coverage validation failed.

      Missing triggers:
      \(report.missingTriggers)
      """,
      file: file,
      line: line
    )
    return report
  }

  return report
}

extension TestStore {
  public func send<Phase: Hashable & Sendable>(
    _ action: R.Action,
    through phaseMap: PhaseMap<R.State, R.Action, Phase>,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    file: StaticString = #file,
    line: UInt = #line
  ) async {
    await send(
      action,
      tracking: phaseMap.phaseKeyPath,
      through: phaseMap.derivedGraph,
      assert: updateExpectedState,
      file: file,
      line: line
    )
  }

  public func receive<Phase: Hashable & Sendable>(
    _ expectedAction: R.Action,
    through phaseMap: PhaseMap<R.State, R.Action, Phase>,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    file: StaticString = #file,
    line: UInt = #line
  ) async where R.Action: Equatable {
    await receive(
      expectedAction,
      tracking: phaseMap.phaseKeyPath,
      through: phaseMap.derivedGraph,
      assert: updateExpectedState,
      file: file,
      line: line
    )
  }
}
