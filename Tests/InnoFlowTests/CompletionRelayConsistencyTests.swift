import Foundation
import InnoFlowCore
import Testing

@Suite("Runtime-owned completion subscriptions")
struct CompletionRelayConsistencyTests {
  @Test("completion owns a discarded tracker and releases it exactly once")
  func retainedUntilCompletion() {
    let completion = FlowTaskCompletion()
    let diagnostics = StoreDiagnostics()
    var tracker: FlowTaskTracker? = FlowTaskTracker(onFinish: { diagnostics.recordTerminated($0) })
    weak var weakTracker = tracker
    let root = tracker!.beginActivity()
    tracker!.trackCompletion(of: completion)
    tracker!.endActivity(root)
    tracker = nil
    #expect(weakTracker != nil)
    #expect(completion.observerCount == 1)
    completion.complete()
    completion.complete()
    #expect(weakTracker == nil)
    #expect(completion.observerCount == 0)
    #expect(diagnostics.snapshot().records.filter { $0.kind == .terminated }.count == 1)
  }

  @Test("cancellation removes only one observer without retaining a suspended task")
  func cancellationDetachesOnlyItsSubscription() {
    let completion = FlowTaskCompletion()
    var first: FlowTaskTracker? = FlowTaskTracker()
    weak var weakFirst = first
    let second = FlowTaskTracker()
    first!.trackCompletion(of: completion)
    second.trackCompletion(of: completion)
    #expect(completion.observerCount == 2)
    first!.cancel()
    #expect(first!.isFinished)
    #expect(!second.isFinished)
    #expect(completion.observerCount == 1)
    first = nil
    #expect(weakFirst == nil)
    completion.complete()
    #expect(second.isFinished)
    #expect(!second.isCancelled)
    #expect(completion.observerCount == 0)
  }

  @Test("registering after completion or cancellation leaves no observers")
  func completedAndCancelledRegistration() {
    let completed = FlowTaskCompletion()
    completed.complete()
    let alreadyComplete = FlowTaskTracker()
    alreadyComplete.trackCompletion(of: completed)
    #expect(alreadyComplete.isFinished)
    #expect(completed.observerCount == 0)

    let pending = FlowTaskCompletion()
    let cancelled = FlowTaskTracker()
    let physical = cancelled.beginActivity()
    cancelled.cancel()
    cancelled.trackCompletion(of: pending)
    #expect(!cancelled.isFinished)
    #expect(pending.observerCount == 0)
    cancelled.endActivity(physical)
    #expect(cancelled.isFinished)
  }

  @Test("completion racing cancellation releases every subscription")
  func completionCancellationRace() async {
    for _ in 0..<1_000 {
      let completion = FlowTaskCompletion()
      let diagnostics = StoreDiagnostics()
      let tracker = FlowTaskTracker(onFinish: { diagnostics.recordTerminated($0) })
      tracker.trackCompletion(of: completion)
      await withTaskGroup(of: Void.self) { group in
        group.addTask { completion.complete() }
        group.addTask { tracker.cancel() }
      }
      #expect(tracker.isFinished)
      #expect(completion.observerCount == 0)
      #expect(diagnostics.snapshot().records.filter { $0.kind == .terminated }.count == 1)
    }
  }
}
