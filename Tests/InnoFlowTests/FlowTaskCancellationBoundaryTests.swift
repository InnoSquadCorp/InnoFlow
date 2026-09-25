import InnoFlowCore
import InnoFlowTesting
import Observation
import Testing
import os

@Suite("FlowTask reduction cancellation boundary")
@MainActor
struct FlowTaskCancellationBoundaryTests {
  @Test("cancellation between emission and reduction drops queued descendants", arguments: [0, 1])
  func cancellationBeforeReductionDropsDescendants(cancelOnStep: Int) async throws {
    let clock = ManualTestClock()
    let handle = OSAllocatedUnfairLock<OutputFlowTask<Int>?>(initialState: nil)
    let drops = OSAllocatedUnfairLock<[ActionDropReason]>(initialState: [])
    let dropDispatchIDs = OSAllocatedUnfairLock<[DispatchID?]>(initialState: [])
    let diagnostics = StoreDiagnostics(capacity: 32)
    let store = Store(
      reducer: QueuedCancellationFeature(),
      clock: .manual(clock),
      instrumentation: .init(
        didEmitAction: { event in
          if case .step(cancelOnStep) = event.action {
            // The synchronous hook makes the otherwise concurrent cancellation
            // race deterministic, for both .run sends and immediate .send chains.
            handle.withLock { $0 }?.cancel()
          }
        },
        didDropAction: { event in
          drops.withLock { $0.append(event.reason) }
          dropDispatchIDs.withLock { $0.append(event.dispatchID) }
        }
      ),
      diagnostics: diagnostics
    )
    let flow = store.send(.start(0), capturingOutputs: .unbounded)
    handle.withLock { $0 = flow }
    try await clock.waitForSleepers(atLeast: 1)

    await clock.advance(by: .seconds(1))
    await flow.finish()

    #expect(flow.isCancelled)
    #expect(store.state.steps == (cancelOnStep == 0 ? [] : [0]))
    #expect(drops.withLock { $0 } == [.cancellationBoundary])
    let droppedIDs = dropDispatchIDs.withLock { $0 }
    #expect(droppedIDs.count == 1)
    #expect(droppedIDs[0] != nil)
    let snapshot = diagnostics.snapshot()
    let submittedIDs = snapshot.records.compactMap { record -> DispatchID? in
      record.kind == .submitted ? record.dispatchID : nil
    }
    let diagnosticDrops = snapshot.records.filter {
      $0.kind == .actionDropped(.cancellationBoundary)
    }
    #expect(submittedIDs.count == 1)
    #expect(diagnosticDrops.count == 1)
    #expect(diagnosticDrops.first?.dispatchID == submittedIDs.first)
    #expect(diagnosticDrops.first?.dispatchID == droppedIDs.first!)
    #expect(snapshot.activeDispatches.isEmpty)
    var outputs = flow.outputs.makeAsyncIterator()
    #expect(await outputs.next() == nil)

    let independent = store.send(.step(9), capturingOutputs: .unbounded)
    await independent.finish()
    var independentOutputs = independent.outputs.makeAsyncIterator()
    #expect(await independentOutputs.next() == 9)
    #expect(!independent.isCancelled)
  }

  @Test("cancellation during state observation suppresses output without rolling back state")
  func cancellationDuringObservationSuppressesOutput() async throws {
    let clock = ManualTestClock()
    let store = Store(reducer: QueuedCancellationFeature(), clock: .manual(clock))
    let flow = store.send(.start(9), capturingOutputs: .unbounded)
    try await clock.waitForSleepers(atLeast: 1)
    withObservationTracking {
      _ = store.state.steps
    } onChange: {
      flow.cancel()
    }

    await clock.advance(by: .seconds(1))
    await flow.finish()

    #expect(flow.isCancelled)
    #expect(store.state.steps == [9])
    var outputs = flow.outputs.makeAsyncIterator()
    #expect(await outputs.next() == nil)
  }
}

private struct QueuedCancellationFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable { var steps: [Int] = [] }
  enum Action: Sendable {
    case start(Int)
    case step(Int)
  }
  typealias Output = Int

  func reduce(into state: inout State, action: Action) -> ReducerEffect<Action, Output> {
    switch action {
    case .start(let value):
      return .run { send, context in
        do {
          try await context.sleep(for: .seconds(1))
          await send(.step(value))
        } catch {
          return
        }
      }
    case .step(let value):
      state.steps.append(value)
      return value < 2 ? .send(.step(value + 1)) : Self.output(value)
    }
  }
}
