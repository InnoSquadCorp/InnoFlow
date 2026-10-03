import Foundation
public import InnoFlowCore
import os

/// Why a testing dispatch or one of its effect runs accepted cancellation.
public enum TestEffectCancellationCause: Sendable, Equatable {
  case dispatch
  case effect
  case superseded
  case storeReleased
}

/// Testing-only typed lifecycle events, in the order they were recorded.
/// Multiple runs in one dispatch may each produce admission/start events.
public enum TestEffectEvent: Sendable, Equatable {
  case admitted(EffectAdmission)
  case started
  case superseded
  case rejected(EffectAdmissionRejection)
  case cancelled(TestEffectCancellationCause)
  case finished
  case failed(String)
}

/// A bounded snapshot of one dispatch's testing effect lifecycle.
/// Runtime Store diagnostics remain separate and payload-free.
public struct TestEffectLedger: Sendable, Equatable {
  public let events: [TestEffectEvent]
  public let droppedEventCount: Int
}

package final class TestEffectLedgerStorage: Sendable {
  private struct State {
    var events: [TestEffectEvent] = []
    var head = 0
    var droppedEventCount = 0
    var isFinished = false
  }
  private let capacity: Int
  private let state = OSAllocatedUnfairLock(initialState: State())

  package init(capacity: Int = 256) {
    self.capacity = max(1, capacity)
  }

  package func record(_ event: TestEffectEvent) {
    state.withLock { state in
      guard !state.isFinished else { return }
      if event == .finished { state.isFinished = true }
      if state.events.count < capacity {
        state.events.append(event)
      } else {
        state.events[state.head] = event
        state.head = (state.head + 1) % capacity
        state.droppedEventCount += 1
      }
    }
  }

  package var snapshot: TestEffectLedger {
    state.withLock { state in
      let ordered =
        Array(state.events.dropFirst(state.head)) + Array(state.events.prefix(state.head))
      return TestEffectLedger(events: ordered, droppedEventCount: state.droppedEventCount)
    }
  }
}

/// Active dispatch lookup without retaining the TestStore across completion.
/// Completion removes a ledger synchronously, including off-MainActor exits.
package final class TestEffectLedgerRegistry: Sendable {
  private let storage = OSAllocatedUnfairLock(initialState: [DispatchID: TestEffectLedgerStorage]())
  package func insert(_ ledger: TestEffectLedgerStorage, for id: DispatchID) {
    storage.withLock { $0[id] = ledger }
  }
  package func remove(_ id: DispatchID) { _ = storage.withLock { $0.removeValue(forKey: id) } }
  package subscript(_ id: DispatchID) -> TestEffectLedgerStorage? { storage.withLock { $0[id] } }
  package var values: [TestEffectLedgerStorage] { storage.withLock { Array($0.values) } }
  package var count: Int { storage.withLock { $0.count } }
}

extension TestStore {
  package func recordEffectEvent(_ event: TestEffectEvent, context: EffectExecutionContext?) {
    guard let dispatchID = context?.dispatchID else { return }
    effectLedgers[dispatchID]?.record(event)
  }
}
