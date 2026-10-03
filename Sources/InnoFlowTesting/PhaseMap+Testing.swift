import Foundation
@_exported public import InnoFlowCore

@discardableResult
public func assertPhaseMapCovers<State: Sendable, Action: Sendable, Phase: Hashable & Sendable>(
  _ phaseMap: PhaseMap<State, Action, Phase>,
  expectedTriggersByPhase: [Phase: [PhaseMapExpectedTrigger<Action>]],
  fileID: StaticString = #fileID,
  filePath: StaticString = #filePath,
  line: UInt = #line,
  column: UInt = #column
) -> PhaseMapValidationReport<Phase> {
  assertPhaseMapCovers(
    phaseMap, expectedTriggersByPhase: expectedTriggersByPhase,
    location: .init(fileID: fileID, filePath: filePath, line: line, column: column))
}

/// Compatibility overload for an explicitly supplied legacy source file.
@discardableResult
public func assertPhaseMapCovers<State: Sendable, Action: Sendable, Phase: Hashable & Sendable>(
  _ phaseMap: PhaseMap<State, Action, Phase>,
  expectedTriggersByPhase: [Phase: [PhaseMapExpectedTrigger<Action>]],
  file: StaticString,
  line: UInt = #line
) -> PhaseMapValidationReport<Phase> {
  assertPhaseMapCovers(
    phaseMap, expectedTriggersByPhase: expectedTriggersByPhase,
    location: .init(fileID: file, filePath: file, line: line, column: 1))
}

@discardableResult
package func assertPhaseMapCovers<State: Sendable, Action: Sendable, Phase: Hashable & Sendable>(
  _ phaseMap: PhaseMap<State, Action, Phase>,
  expectedTriggersByPhase: [Phase: [PhaseMapExpectedTrigger<Action>]],
  location: TestStoreSourceLocation
) -> PhaseMapValidationReport<Phase> {
  let report = phaseMap.validationReport(expectedTriggersByPhase: expectedTriggersByPhase)

  guard report.isEmpty else {
    testStoreAssertionFailure(
      """
      PhaseMap coverage validation failed.

      Missing triggers:
      \(report.missingTriggers)
      """,
      location: location
    )
    return report
  }

  return report
}

extension TestStore {
  @discardableResult
  public func send<Phase: Hashable & Sendable>(
    _ action: R.Action,
    through phaseMap: PhaseMap<R.State, R.Action, Phase>,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) async -> TestStoreDispatch {
    await send(
      action, through: phaseMap, assert: updateExpectedState,
      location: .init(fileID: fileID, filePath: filePath, line: line, column: column))
  }

  /// Compatibility overload for an explicitly supplied legacy source file.
  @discardableResult
  public func send<Phase: Hashable & Sendable>(
    _ action: R.Action,
    through phaseMap: PhaseMap<R.State, R.Action, Phase>,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    file: StaticString,
    line: UInt = #line
  ) async -> TestStoreDispatch {
    await send(
      action, through: phaseMap, assert: updateExpectedState,
      location: .init(fileID: file, filePath: file, line: line, column: 1))
  }

  @discardableResult
  package func send<Phase: Hashable & Sendable>(
    _ action: R.Action,
    through phaseMap: PhaseMap<R.State, R.Action, Phase>,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    location: TestStoreSourceLocation
  ) async -> TestStoreDispatch {
    await send(
      action,
      tracking: phaseMap.phaseKeyPath,
      through: phaseMap.derivedGraph,
      assert: updateExpectedState,
      location: location
    )
  }

  public func receive<Phase: Hashable & Sendable>(
    _ expectedAction: R.Action,
    through phaseMap: PhaseMap<R.State, R.Action, Phase>,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) async where R.Action: Equatable {
    await receive(
      expectedAction, through: phaseMap, assert: updateExpectedState,
      location: .init(fileID: fileID, filePath: filePath, line: line, column: column))
  }

  /// Compatibility overload for an explicitly supplied legacy source file.
  public func receive<Phase: Hashable & Sendable>(
    _ expectedAction: R.Action,
    through phaseMap: PhaseMap<R.State, R.Action, Phase>,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    file: StaticString,
    line: UInt = #line
  ) async where R.Action: Equatable {
    await receive(
      expectedAction, through: phaseMap, assert: updateExpectedState,
      location: .init(fileID: file, filePath: file, line: line, column: 1))
  }

  package func receive<Phase: Hashable & Sendable>(
    _ expectedAction: R.Action,
    through phaseMap: PhaseMap<R.State, R.Action, Phase>,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    location: TestStoreSourceLocation
  ) async where R.Action: Equatable {
    await receive(
      expectedAction,
      tracking: phaseMap.phaseKeyPath,
      through: phaseMap.derivedGraph,
      assert: updateExpectedState,
      location: location
    )
  }

  /// Receives an action through a phase map using a timeout for this assertion
  /// only.
  public func receive<Phase: Hashable & Sendable>(
    _ expectedAction: R.Action,
    through phaseMap: PhaseMap<R.State, R.Action, Phase>,
    timeout: Duration,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) async where R.Action: Equatable {
    await receive(
      expectedAction, through: phaseMap, timeout: timeout, assert: updateExpectedState,
      location: .init(fileID: fileID, filePath: filePath, line: line, column: column))
  }

  /// Compatibility overload for an explicitly supplied legacy source file.
  public func receive<Phase: Hashable & Sendable>(
    _ expectedAction: R.Action,
    through phaseMap: PhaseMap<R.State, R.Action, Phase>,
    timeout: Duration,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    file: StaticString,
    line: UInt = #line
  ) async where R.Action: Equatable {
    await receive(
      expectedAction, through: phaseMap, timeout: timeout, assert: updateExpectedState,
      location: .init(fileID: file, filePath: file, line: line, column: 1))
  }

  package func receive<Phase: Hashable & Sendable>(
    _ expectedAction: R.Action,
    through phaseMap: PhaseMap<R.State, R.Action, Phase>,
    timeout: Duration,
    assert updateExpectedState: ((inout R.State) -> Void)? = nil,
    location: TestStoreSourceLocation
  ) async where R.Action: Equatable {
    await receive(
      expectedAction,
      tracking: phaseMap.phaseKeyPath,
      through: phaseMap.derivedGraph,
      timeout: timeout,
      assert: updateExpectedState,
      location: location
    )
  }
}
