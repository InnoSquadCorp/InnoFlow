import Foundation
import InnoFlowCore
import Testing

@Suite("Diagnostics ring consistency")
struct DiagnosticsRingConsistencyTests {
  @Test(arguments: [0, 1, 3, 32])
  func ringPreservesChronologyAndExactDiscardCount(capacity: Int) {
    let diagnostics = StoreDiagnostics(capacity: capacity)
    for _ in 0..<1_000 {
      let id = DispatchID()
      diagnostics.recordSubmitted(id)
      diagnostics.recordTerminated(id)
    }
    let snapshot = diagnostics.snapshot()
    #expect(snapshot.records.count == capacity)
    #expect(snapshot.activeDispatches.isEmpty)
    #expect(snapshot.droppedRecordCount == UInt64(2_000 - capacity))
    let expected: [UInt64] = capacity == 0 ? [] : Array(UInt64(2_001 - capacity)...2_000)
    #expect(snapshot.records.map(\.index) == expected)
  }

  @Test(arguments: [0, 1, 24])
  func activeLimitPreservesLexicalIdentifierOrderAndValues(count: Int) throws {
    let diagnostics = StoreDiagnostics(capacity: 7)
    let instrumentation: StoreInstrumentation<Int> = diagnostics.instrumentation()
    let ids = (0..<count).map { _ in DispatchID() }
    // Submission order differs from both identifier and lexical order.
    for offset in ids.indices.reversed() {
      let id = ids[offset]
      diagnostics.recordSubmitted(id)
      // Retain one submitted-only dispatch with a nil sequence.
      guard offset > 0 else { continue }
      for _ in 0..<(offset % 3) {
        instrumentation.didStartRun(
          .init(
            token: UUID(), cancellationID: Optional<AnyEffectID>.none,
            sequence: nil, dispatchID: id
          ))
      }
      if offset.isMultiple(of: 2) == false {
        diagnostics.recordAdmission(
          .queued(position: 1), dispatchID: id, sequence: nil, scheduledToken: UUID()
        )
      }
      if offset.isMultiple(of: 4) {
        diagnostics.recordCancellationRequested(id)
      }
      diagnostics.recordAdmission(.started, dispatchID: id, sequence: UInt64(1_000 + offset))
    }
    let retained = diagnostics.snapshot()
    let expected = ids.sorted { $0.description < $1.description }
    for limit: Int? in [nil, -7, 0, 1, 9, 24, 512, Int.max] {
      let snapshot = diagnostics.snapshot(activeLimit: limit)
      let expectedCount = min(ids.count, max(0, limit ?? ids.count))
      #expect(snapshot.activeDispatches.map(\.dispatchID) == Array(expected.prefix(expectedCount)))
      #expect(snapshot.records == retained.records)
      #expect(snapshot.droppedRecordCount == retained.droppedRecordCount)
      for value in snapshot.activeDispatches {
        let offset = try #require(ids.firstIndex(of: value.dispatchID))
        #expect(value.activeRunCount == offset % 3)
        #expect(value.queuedRunCount == offset % 2)
        #expect(value.isCancellationRequested == (offset > 0 && offset.isMultiple(of: 4)))
        #expect(value.lastSequence == (offset == 0 ? nil : UInt64(1_000 + offset)))
      }
    }
    #expect(diagnostics.snapshot() == retained)
  }

  @Test func singleActiveDispatchPreservesEveryValueAndLimit() throws {
    let diagnostics = StoreDiagnostics(capacity: 3)
    let instrumentation: StoreInstrumentation<Int> = diagnostics.instrumentation()
    let id = DispatchID()
    diagnostics.recordSubmitted(id)
    for _ in 0..<2 {
      instrumentation.didStartRun(
        .init(
          token: UUID(), cancellationID: Optional<AnyEffectID>.none, sequence: nil, dispatchID: id))
    }
    diagnostics.recordAdmission(
      .queued(position: 1), dispatchID: id, sequence: 76, scheduledToken: UUID())
    diagnostics.recordCancellationRequested(id, sequence: 77)
    let retained = diagnostics.snapshot()
    for limit: Int? in [nil, -1, 0, 1, 2, Int.max] {
      let snapshot = diagnostics.snapshot(activeLimit: limit)
      #expect(snapshot.records == retained.records)
      #expect(snapshot.droppedRecordCount == retained.droppedRecordCount)
      guard (limit ?? 1) > 0 else {
        #expect(snapshot.activeDispatches.isEmpty)
        continue
      }
      #expect(snapshot.activeDispatches.count == 1)
      let value = try #require(snapshot.activeDispatches.first)
      #expect(value.dispatchID == id)
      #expect(value.activeRunCount == 2)
      #expect(value.queuedRunCount == 1)
      #expect(value.isCancellationRequested)
      #expect(value.lastSequence == 77)
    }
    #expect(diagnostics.snapshot() == retained)
  }

  @Test func retainedActiveSnapshotSurvivesTerminationAndLaterSubmissions() throws {
    let diagnostics = StoreDiagnostics(capacity: 3)
    let firstID = DispatchID()
    diagnostics.recordSubmitted(firstID)
    diagnostics.recordAdmission(
      .queued(position: 1), dispatchID: firstID, sequence: 17, scheduledToken: UUID())
    let retained = diagnostics.snapshot(activeLimit: 1)
    diagnostics.recordCancellationRequested(firstID, sequence: 18)
    diagnostics.recordTerminated(firstID)
    // A late event is history only; it must not return the dispatch to active.
    diagnostics.recordAdmission(.started, dispatchID: firstID, sequence: 19)
    let nextID = DispatchID()
    diagnostics.recordSubmitted(nextID)
    let current = diagnostics.snapshot(activeLimit: 1)
    #expect(current.activeDispatches.map(\.dispatchID) == [nextID])
    let original = try #require(retained.activeDispatches.first)
    #expect(original.dispatchID == firstID)
    #expect(original.queuedRunCount == 1)
    #expect(original.activeRunCount == 0)
    #expect(original.isCancellationRequested == false)
    #expect(original.lastSequence == 17)
    #expect(retained.records.map(\.index) == [1, 2])
    #expect(retained.droppedRecordCount == 0)
    #expect(current.records.map(\.index) == [4, 5, 6])
    #expect(current.droppedRecordCount == 3)
  }

  @Test func emptyActiveSetAcceptsEveryLimit() {
    let diagnostics = StoreDiagnostics(capacity: 0)
    for limit: Int? in [nil, -1, 0, 1, Int.max] {
      let snapshot = diagnostics.snapshot(activeLimit: limit)
      #expect(snapshot.activeDispatches.isEmpty)
      #expect(snapshot.records.isEmpty)
      #expect(snapshot.droppedRecordCount == 0)
    }
  }

  @Test func retainedSnapshotDoesNotChangeWhenRingWrapsAgain() {
    let diagnostics = StoreDiagnostics(capacity: 3)
    let id = DispatchID()
    diagnostics.recordSubmitted(id)
    diagnostics.recordAdmission(.started, dispatchID: id, sequence: 1)
    let first = diagnostics.snapshot()
    for sequence in 2...20 {
      diagnostics.recordAdmission(.started, dispatchID: id, sequence: UInt64(sequence))
    }
    diagnostics.recordTerminated(id)
    let last = diagnostics.snapshot()
    #expect(first.records.map(\.index) == [1, 2])
    #expect(first.records.last?.sequence == 1)
    #expect(last.records.map(\.index) == [20, 21, 22])
    #expect(last.records.last?.kind == .terminated)
    #expect(last.activeDispatches.isEmpty)
  }

  @Test func concurrentRecordingKeepsBoundedOrderedSnapshots() async {
    let diagnostics = StoreDiagnostics(capacity: 31)
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<128 {
        group.addTask {
          let id = DispatchID()
          diagnostics.recordSubmitted(id)
          diagnostics.recordTerminated(id)
        }
      }
    }
    let snapshot = diagnostics.snapshot()
    #expect(snapshot.records.count == 31)
    #expect(snapshot.records.map(\.index) == Array(UInt64(226)...256))
    #expect(snapshot.droppedRecordCount == 225)
    #expect(snapshot.activeDispatches.isEmpty)
  }
}
