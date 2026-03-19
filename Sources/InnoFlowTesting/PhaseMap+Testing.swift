import Foundation
import InnoFlow

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
