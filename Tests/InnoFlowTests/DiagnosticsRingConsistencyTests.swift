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
