import Foundation
public import InnoFlowCore

/// A testing handle for the dispatch started by one `TestStore.send`.
///
/// `finish` verifies only this dispatch and never consumes actions or outputs,
/// including in non-exhaustive tests. Use `receive`, non-exhaustive
/// `receiveOutput`, or the store's global `finish` to advance queued actions.
/// The handle does not retain its test store.
public struct TestStoreDispatch: Sendable {
  private let flowTask: FlowTask
  private let ledger: TestEffectLedgerStorage
  private let timeout: Duration
  private let activity: TestStoreFinishActivity
  private let snapshot: @MainActor @Sendable () -> TestStoreUnverifiedSnapshot?
  private let reportFailure: @MainActor @Sendable (String, TestStoreSourceLocation) -> Void

  package init(
    tracker: FlowTaskTracker,
    ledger: TestEffectLedgerStorage,
    timeout: Duration,
    activity: TestStoreFinishActivity,
    snapshot: @escaping @MainActor @Sendable () -> TestStoreUnverifiedSnapshot?,
    reportFailure: @escaping @MainActor @Sendable (String, TestStoreSourceLocation) -> Void
  ) {
    flowTask = FlowTask(tracker: tracker)
    self.ledger = ledger
    self.timeout = timeout
    self.activity = activity
    self.snapshot = snapshot
    self.reportFailure = reportFailure
  }

  /// A bounded, non-consuming snapshot of this dispatch's typed effect events.
  public var effectLedger: TestEffectLedger { ledger.snapshot }

  package var flowTaskReference: FlowTask { flowTask }

  /// Whether this dispatch has accepted cancellation.
  public var isCancelled: Bool { flowTask.isCancelled }

  /// Runtime completion, independent of still-unverified delivered outputs.
  /// A queued action or a physically running operation prevents completion.
  public var isFinished: Bool { flowTask.isFinished }

  /// Cancels only this dispatch. Already-reduced state is not rolled back.
  public func cancel() { flowTask.cancel() }

  /// Verifies dispatch completion under one finite wall-clock deadline.
  /// Unreceived values are diagnosed without consuming them; timeout or caller
  /// cancellation requests cancellation of only this dispatch.
  @MainActor
  public func finish(
    timeout: Duration? = nil,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) async {
    await finish(
      timeout: timeout,
      location: .init(fileID: fileID, filePath: filePath, line: line, column: column))
  }

  /// Compatibility overload for an explicitly supplied legacy source file.
  @MainActor
  public func finish(
    timeout: Duration? = nil,
    file: StaticString,
    line: UInt = #line
  ) async {
    await finish(
      timeout: timeout, location: .init(fileID: file, filePath: file, line: line, column: 1))
  }

  @MainActor
  package func finish(
    timeout: Duration? = nil,
    location: TestStoreSourceLocation
  ) async {
    let timeout = timeout ?? self.timeout
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    await withTaskCancellationHandler {
      while true {
        guard !Task.isCancelled else {
          cancel()
          return
        }
        let revision = activity.snapshot.revision
        guard let unverified = snapshot() else { return }
        if !unverified.isEmpty {
          reportFailure(
            "TestStoreDispatch finished with unverified work in its dispatch.\n\n"
              + unverified.description
              + "\n\nReceive these values before finishing this task. No values were consumed.",
            location
          )
          return
        }
        if isFinished { return }
        guard clock.now < deadline else {
          cancel()
          reportFailure(
            "Timed out waiting for TestStoreDispatch after \(timeout). Cancellation was requested only for this dispatch; physically running work may remain.",
            location
          )
          return
        }
        _ = await activity.waitForChange(after: revision, until: deadline)
      }
    } onCancel: {
      cancel()
    }
  }
}

/// One non-consuming MainActor snapshot with bounded value previews.
package struct TestStoreUnverifiedSnapshot: Equatable, Sendable {
  package var actionCount = 0
  package var outputCount = 0
  package var actions: [String] = []
  package var outputs: [String] = []
  package var isEmpty: Bool { actionCount == 0 && outputCount == 0 }

  package var description: String {
    var sections: [String] = []
    func section(_ name: String, _ count: Int, _ values: [String]) -> String {
      var lines = values.map { "- \($0)" }
      if count > values.count { lines.append("- ... \(count - values.count) more") }
      return "\(count) unhandled \(name):\n" + lines.joined(separator: "\n")
    }
    if actionCount > 0 { sections.append(section("effect action(s)", actionCount, actions)) }
    if outputCount > 0 { sections.append(section("output(s)", outputCount, outputs)) }
    return sections.joined(separator: "\n\n")
  }
}

extension TestStore {
  package func makeDispatch() -> (
    tracker: FlowTaskTracker, activity: FlowTaskActivityID, task: TestStoreDispatch
  ) {
    let activity = finishActivity
    let ledger = TestEffectLedgerStorage()
    let ledgers = effectLedgers
    let tracker = FlowTaskTracker(
      onFinish: { [weak ledgers, weak activity] dispatchID in
        ledger.record(.finished)
        ledgers?.remove(dispatchID)
        Task { @MainActor in activity?.noteProgress() }
      },
      onCancel: { [weak self] _ in
        ledger.record(.cancelled(.dispatch))
        Task { @MainActor in self?.discardInvalidatedActions() }
      }
    )
    effectLedgers.insert(ledger, for: tracker.dispatchID)
    let token = tracker.beginActivity()
    let task = TestStoreDispatch(
      tracker: tracker,
      ledger: ledger,
      timeout: effectTimeout,
      activity: activity,
      snapshot: { [weak self] in self?.unverifiedSnapshot(dispatchID: tracker.dispatchID) },
      reportFailure: { [weak self] message, location in
        self?.issueReporter(message, location)
      }
    )
    return (tracker, token, task)
  }

  package func unverifiedSnapshot(dispatchID: DispatchID? = nil) -> TestStoreUnverifiedSnapshot {
    var snapshot = TestStoreUnverifiedSnapshot()
    queue.forEachBuffered { entry in
      guard shouldProceed(context: entry.context) else { return }
      guard dispatchID == nil || entry.context?.dispatchID == dispatchID else { return }
      snapshot.actionCount += 1
      if snapshot.actions.count < 20 { snapshot.actions.append(String(describing: entry.action)) }
    }
    outputQueue.forEachBuffered { entry in
      guard shouldProceed(context: entry.context) else { return }
      guard dispatchID == nil || entry.context?.dispatchID == dispatchID else { return }
      snapshot.outputCount += 1
      if snapshot.outputs.count < 20 { snapshot.outputs.append(String(describing: entry.action)) }
    }
    return snapshot
  }
}

@MainActor
extension FlowScope {
  /// Tracks this testing dispatch using Core ownership. Scope closure cancels
  /// and joins runtime work; explicit testing assertions still own validation.
  @discardableResult
  public func track(_ task: TestStoreDispatch) async -> TestStoreDispatch {
    await track(task.flowTaskReference)
    return task
  }
}

/// Compatibility spelling for ``TestStoreDispatch``. Both names refer to the
/// same dispatch handle and have identical ownership and assertion behavior.
public typealias TestFlowTask = TestStoreDispatch
